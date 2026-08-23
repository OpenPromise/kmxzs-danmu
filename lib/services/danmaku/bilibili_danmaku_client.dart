import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'danmaku_client.dart';
import 'danmaku_message.dart';

/// B 站直播弹幕客户端。
///
/// 协议（公开资料，多年稳定）：
/// 1. `room_init` 换真实房间号并确认开播；
/// 2. `getDanmuInfo` 拿弹幕服务器地址与 token；
/// 3. 连 `wss://{host}/sub`，5 秒内发认证包（protover=2 让服务端用 zlib 压缩，
///    避免 brotli），之后每 30 秒心跳；
/// 4. 收到 op=5 通知帧：协议版本 2 先 zlib 解压再拆包，JSON 解析弹幕。
class BilibiliDanmakuClient implements DanmakuClient {
  BilibiliDanmakuClient({
    required this.roomId,
    Dio? dio,
    this.heartbeatInterval = const Duration(seconds: 30),
  }) : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 10),
                receiveTimeout: const Duration(seconds: 15),
                headers: {
                  'User-Agent': _ua,
                  'Referer': 'https://live.bilibili.com/',
                  'Origin': 'https://live.bilibili.com',
                },
              ),
            );

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  /// 头部长度（16 字节：总长/头长/协议版本/操作码/序号）。
  static const headerLen = 16;

  // 操作码
  static const opHeartbeat = 2;
  static const opHeartbeatReply = 3;
  static const opNotify = 5;
  static const opAuth = 7;
  static const opAuthReply = 8;

  // 协议版本
  static const protoPlain = 0;
  static const protoInt = 1;
  static const protoZlib = 2;
  static const protoBrotli = 3;

  static const maxReconnectAttempts = 5;

  @override
  final String roomId;

  final Duration heartbeatInterval;
  final Dio _dio;

  final _messages = StreamController<DanmakuMessage>.broadcast();
  WebSocket? _ws;
  Timer? _heartbeat;
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  bool _closed = false;

  @override
  String get platform => 'bilibili';

  @override
  String get platformLabel => 'B站';

  @override
  Stream<DanmakuMessage> get messages => _messages.stream;

  /// 构造一个 B 站二进制数据包。
  static List<int> buildPacket({
    required int op,
    int version = protoInt,
    List<int> body = const [],
  }) {
    final total = headerLen + body.length;
    final bd = ByteData(total);
    bd.setUint32(0, total);
    bd.setUint16(4, headerLen);
    bd.setUint16(6, version);
    bd.setUint32(8, op);
    bd.setUint32(12, 1);
    final bytes = bd.buffer.asUint8List();
    bytes.setRange(headerLen, total, body);
    return bytes;
  }

  static ({int total, int headerLen, int version, int op, int seq}) parseHeader(
    List<int> data,
  ) {
    final bd = ByteData.sublistView(Uint8List.fromList(data));
    return (
      total: bd.getUint32(0),
      headerLen: bd.getUint16(4),
      version: bd.getUint16(6),
      op: bd.getUint32(8),
      seq: bd.getUint32(12),
    );
  }

  /// 把一段字节流按 4 字节总长拆成多个完整数据包（zlib 解压后是多个包连排）。
  static List<List<int>> splitPackets(List<int> data) {
    final result = <List<int>>[];
    var offset = 0;
    while (offset + headerLen <= data.length) {
      final bd = ByteData.sublistView(Uint8List.fromList(data), offset);
      final total = bd.getUint32(0);
      if (total < headerLen || offset + total > data.length) break;
      result.add(data.sublist(offset, offset + total));
      offset += total;
    }
    return result;
  }

  /// 认证数据包：protover=2 让服务端用 zlib 压缩（避免 brotli 无法解压）。
  static List<int> buildAuthPacket(int realRoomId, String token) =>
      buildPacket(
        op: opAuth,
        version: protoInt,
        body: utf8.encode(
          jsonEncode({
            'uid': 0,
            'roomid': realRoomId,
            'protover': protoZlib,
            'platform': 'web',
            'type': 2,
            'key': token,
          }),
        ),
      );

  static List<int> buildHeartbeatPacket() =>
      buildPacket(op: opHeartbeat, version: protoInt);

  /// 根据协议版本解压/拆包，返回可直接解析的 op=5 通知包列表。
  ///
  /// brotli（版本 3）暂不支持，返回空列表（认证时已要求 zlib，正常不会出现）。
  static List<List<int>> inflatePayload({
    required int version,
    required List<int> body,
  }) {
    if (version == protoZlib) {
      try {
        final inflated = ZLibDecoder().convert(body);
        return splitPackets(inflated);
      } catch (_) {
        return const [];
      }
    }
    if (version == protoBrotli) return const [];
    return [buildPacket(op: opNotify, version: protoPlain, body: body)];
  }

  /// 解析一条 op=5 通知 JSON（对象或 JSON 字符串），非弹幕类返回 null。
  static DanmakuMessage? parseMessage(Object? json) {
    Object? decoded = json;
    if (json is String) {
      try {
        decoded = jsonDecode(json);
      } catch (_) {
        return null;
      }
    }
    if (decoded is! Map) return null;
    final map = Map<String, dynamic>.from(decoded);
    final cmd = '${map['cmd'] ?? ''}';
    final now = DateTime.now();
    try {
      if (cmd == 'DANMU_MSG') {
        final info = map['info'];
        if (info is List && info.length >= 3) {
          final userInfo = info[2];
          final user = userInfo is List && userInfo.length > 1
              ? '${userInfo[1]}'
              : '匿名';
          return DanmakuMessage(
            platform: 'bilibili',
            user: user,
            content: '${info[1]}',
            timestamp: now,
            kind: DanmakuKind.chat,
          );
        }
      }
      if (cmd == 'SEND_GIFT') {
        final d = map['data'];
        if (d is Map) {
          return DanmakuMessage(
            platform: 'bilibili',
            user: '${d['uname'] ?? '匿名'}',
            content: '',
            timestamp: now,
            kind: DanmakuKind.gift,
            giftName: '${d['giftName'] ?? ''}',
            giftCount: (d['num'] as num?)?.toInt() ?? 1,
          );
        }
      }
      if (cmd == 'SUPER_CHAT_MESSAGE') {
        final d = map['data'];
        if (d is Map) {
          final u = d['user_info'];
          return DanmakuMessage(
            platform: 'bilibili',
            user: u is Map ? '${u['uname'] ?? '匿名'}' : '匿名',
            content: '${d['message'] ?? ''}',
            timestamp: now,
            kind: DanmakuKind.superChat,
          );
        }
      }
      if (cmd == 'INTERACT_WORD') {
        final d = map['data'];
        if (d is Map) {
          return DanmakuMessage(
            platform: 'bilibili',
            user: '${d['uname'] ?? '匿名'}',
            content: '',
            timestamp: now,
            kind: DanmakuKind.enter,
          );
        }
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  @override
  Future<void> connect() async {
    if (_closed) return;
    final realRoomId = await _resolveRealRoomId();
    final info = await _fetchDanmuInfo(realRoomId);
    final ws = await WebSocket.connect(
      info.url,
      headers: {
        'User-Agent': _ua,
        'Origin': 'https://live.bilibili.com',
      },
    );
    if (_closed) {
      await ws.close();
      return;
    }
    _ws = ws;
    ws.add(buildAuthPacket(realRoomId, info.token));
    ws.listen(
      _onData,
      onDone: _onClosed,
      onError: (Object _) => _onClosed(),
      cancelOnError: true,
    );
    _startHeartbeat();
  }

  Future<int> _resolveRealRoomId() async {
    final res = await _dio.get(
      'https://api.live.bilibili.com/room/v1/Room/room_init',
      queryParameters: {'id': roomId},
    );
    final data = res.data is Map ? Map<String, dynamic>.from(res.data) : null;
    if (data == null || data['code'] != 0) {
      throw StateError('B站房间信息获取失败: ${data?['message'] ?? res.statusCode}');
    }
    final room = data['data'] is Map
        ? Map<String, dynamic>.from(data['data'] as Map)
        : null;
    if (room == null) throw StateError('B站房间信息为空');
    final liveStatus = (room['live_status'] as num?)?.toInt() ?? 0;
    if (liveStatus != 1) {
      throw StateError('B站直播间未开播（live_status=$liveStatus）');
    }
    return (room['room_id'] as num?)?.toInt() ?? int.parse(roomId);
  }

  Future<({String url, String token})> _fetchDanmuInfo(int realRoomId) async {
    try {
      final res = await _dio.get(
        'https://api.live.bilibili.com/xlive/web-room/v1/index/getDanmuInfo',
        queryParameters: {'id': realRoomId},
      );
      final data = res.data is Map ? Map<String, dynamic>.from(res.data) : null;
      if (data != null && data['code'] == 0 && data['data'] is Map) {
        final d = Map<String, dynamic>.from(data['data'] as Map);
        final token = '${d['token'] ?? ''}';
        final hosts = d['host_list'] is List ? d['host_list'] as List : const [];
        for (final h in hosts) {
          if (h is! Map) continue;
          final host = '${h['host'] ?? ''}';
          final wssPort = (h['wss_port'] as num?)?.toInt();
          if (host.isEmpty) continue;
          return (
            url: 'wss://$host:${wssPort ?? 443}/sub',
            token: token,
          );
        }
      }
    } catch (_) {
      // 新接口失败走旧接口兜底
    }
    final res = await _dio.get(
      'https://api.live.bilibili.com/room/v1/Danmu/getConf',
      queryParameters: {'room_id': realRoomId, 'platform': 'pc', 'player': 'web'},
    );
    final data = res.data is Map ? Map<String, dynamic>.from(res.data) : null;
    if (data == null || data['code'] != 0 || data['data'] is! Map) {
      throw StateError('B站弹幕配置获取失败: ${data?['message'] ?? res.statusCode}');
    }
    final d = Map<String, dynamic>.from(data['data'] as Map);
    final token = '${d['token'] ?? ''}';
    var host = 'broadcastlv.chat.bilibili.com';
    final rawHosts = d['host'];
    if (rawHosts is String) {
      try {
        final list = jsonDecode(rawHosts);
        if (list is List && list.isNotEmpty && list.first is Map) {
          final h = Map<String, dynamic>.from(list.first as Map);
          final name = '${h['host'] ?? ''}';
          if (name.isNotEmpty) host = name;
        }
      } catch (_) {}
    }
    return (url: 'wss://$host/sub', token: token);
  }

  void _onData(Object? data) {
    if (data is! List<int> || data.length < headerLen) return;
    final header = parseHeader(data);
    final end = header.total > data.length ? data.length : header.total;
    final body = data.sublist(header.headerLen, end);
    switch (header.op) {
      case opAuthReply:
        _handleAuthReply(body);
        break;
      case opHeartbeatReply:
        // 心跳回包：人气值 JSON，弹幕链路不需要
        break;
      case opNotify:
        for (final frame in inflatePayload(
          version: header.version,
          body: body,
        )) {
          final h = parseHeader(frame);
          if (h.op != opNotify) continue;
          final bEnd = h.total > frame.length ? frame.length : h.total;
          _handleNotifyBody(frame.sublist(h.headerLen, bEnd));
        }
        break;
    }
  }

  void _handleAuthReply(List<int> body) {
    try {
      final map = jsonDecode(utf8.decode(body)) as Map;
      if (map['code'] == 0) {
        _reconnectAttempts = 0;
        _messages.add(
          DanmakuMessage(
            platform: 'bilibili',
            user: '',
            content: '弹幕连接成功',
            timestamp: DateTime.now(),
            kind: DanmakuKind.system,
          ),
        );
      } else {
        _messages.add(
          DanmakuMessage(
            platform: 'bilibili',
            user: '',
            content: '弹幕认证失败（${map['code']}）',
            timestamp: DateTime.now(),
            kind: DanmakuKind.system,
          ),
        );
        _ws?.close();
      }
    } catch (_) {
      // 认证回包异常按失败处理，等待连接关闭后重连
    }
  }

  void _handleNotifyBody(List<int> body) {
    final text = utf8.decode(body, allowMalformed: true).trim();
    if (text.isEmpty) return;
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      return;
    }
    if (decoded is List) {
      for (final item in decoded) {
        final msg = parseMessage(item);
        if (msg != null) _messages.add(msg);
      }
      return;
    }
    final msg = parseMessage(decoded);
    if (msg != null) _messages.add(msg);
  }

  void _startHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(heartbeatInterval, (_) {
      final ws = _ws;
      if (ws == null || _closed) return;
      try {
        ws.add(buildHeartbeatPacket());
      } catch (_) {}
    });
  }

  void _stopHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = null;
  }

  void _onClosed() {
    _stopHeartbeat();
    _ws = null;
    if (_closed) return;
    if (_reconnectAttempts >= maxReconnectAttempts) {
      _messages.add(
        DanmakuMessage(
          platform: 'bilibili',
          user: '',
          content: '弹幕连接已断开（重试次数过多）',
          timestamp: DateTime.now(),
          kind: DanmakuKind.system,
        ),
      );
      return;
    }
    _reconnectAttempts++;
    final delay = Duration(seconds: 2 * _reconnectAttempts);
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () {
      if (_closed) return;
      connect().catchError((Object e) {
        _messages.add(
          DanmakuMessage(
            platform: 'bilibili',
            user: '',
            content: '弹幕重连失败: $e',
            timestamp: DateTime.now(),
            kind: DanmakuKind.system,
          ),
        );
      });
    });
  }

  @override
  Future<void> dispose() async {
    _closed = true;
    _reconnectTimer?.cancel();
    _stopHeartbeat();
    final ws = _ws;
    _ws = null;
    if (ws != null) {
      try {
        await ws.close();
      } catch (_) {}
    }
    await _messages.close();
  }
}
