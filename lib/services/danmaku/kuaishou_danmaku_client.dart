import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'danmaku_client.dart';
import 'danmaku_message.dart';
import 'proto_reader.dart';

/// 快手直播弹幕客户端。
///
/// 连接信息（ws url + token + liveStreamId）来自网页 `__INITIAL_STATE__`
/// 的 `liveroom.websocketInfo`，由快手取流 WebView 会话捕获后传入。
/// 协议：外层 `SocketMessage{payloadType, compressionType, payload}`，
/// 进房发 CS_ENTER_ROOM(200)，推送 SC_FEED_PUSH(310)，payload 为 protobuf
/// （GZIP 时先解压），弹幕在 SCWebFeedPush.commentFeeds。
class KuaishouDanmakuClient implements DanmakuClient {
  KuaishouDanmakuClient({
    required this.roomId,
    required this.wsUrl,
    required this.token,
    required this.liveStreamId,
    this.enterPacket,
  });

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  // SocketMessage.payloadType
  static const csHeartbeat = 1;
  static const scPingAck = 104;
  static const scHeartbeatAck = 101;
  static const csEnterRoom = 200;
  static const scEnterRoomAck = 300;
  static const scFeedPush = 310;

  // SocketMessage.compressionType
  static const compressionNone = 1;
  static const compressionGzip = 2;

  static const maxReconnectAttempts = 5;

  @override
  final String roomId;

  final String wsUrl;
  final String token;
  final String liveStreamId;
  final List<int>? enterPacket;

  final _messages = StreamController<DanmakuMessage>.broadcast();
  WebSocket? _ws;
  Timer? _heartbeat;
  Timer? _reconnectTimer;
  Completer<void>? _readyCompleter;
  int _reconnectAttempts = 0;
  bool _closed = false;
  final Duration _heartbeatInterval = const Duration(seconds: 15);

  @override
  String get platform => 'kuaishou';

  @override
  String get platformLabel => '快手';

  @override
  Stream<DanmakuMessage> get messages => _messages.stream;

  /// 构造进房包：SocketMessage{payloadType=200, compressionType=1,
  /// payload 直接是 CSWebEnterRoom；不能再嵌套一层 SocketMessage。
  static List<int> buildEnterRoomPacket(
    String token,
    String liveStreamId, {
    String? pageId,
  }) {
    final payload = PbWriter();
    payload.stringField(1, token);
    payload.stringField(2, liveStreamId);
    payload.stringField(7, pageId ?? _newPageId());
    final outer = PbWriter();
    outer.varintField(1, csEnterRoom);
    outer.varintField(2, compressionNone);
    outer.bytesField(3, payload.takeBytes());
    return outer.takeBytes();
  }

  static String _newPageId() {
    const chars =
        'bjectSymhasOwnProp-0123456789ABCDEFGHIJKLMNQRTUVWXYZ_dfgiklquvxz';
    final random = Random.secure();
    final id = List.generate(16, (_) => chars[random.nextInt(chars.length)]);
    return '${id.join()}_${DateTime.now().millisecondsSinceEpoch}';
  }

  /// 网页心跳：SocketMessage{CS_HEARTBEAT, CSWebHeartbeat{timestamp}}。
  static List<int> buildHeartbeatPacket({int? timestamp}) {
    final heartbeat = PbWriter();
    heartbeat.varintField(
      1,
      timestamp ?? DateTime.now().millisecondsSinceEpoch,
    );
    final outer = PbWriter();
    outer.varintField(1, csHeartbeat);
    outer.varintField(2, compressionNone);
    outer.bytesField(3, heartbeat.takeBytes());
    return outer.takeBytes();
  }

  /// 解析 SC_FEED_PUSH(310) 载荷，返回弹幕/礼物消息。
  static List<DanmakuMessage> parseFeedPayload(
    List<int> raw, {
    bool compressed = false,
  }) {
    List<int> data;
    if (compressed) {
      try {
        data = gzip.decode(raw);
      } catch (_) {
        data = raw;
      }
    } else {
      data = raw;
    }
    final feed = PbMessage(data);
    final out = <DanmakuMessage>[];
    final now = DateTime.now();
    for (final c in feed.bytesList(5)) {
      final comment = PbMessage(c);
      final user = comment.nested(2);
      final name = user?.string(2) ?? '匿名';
      final content = comment.string(3) ?? '';
      if (content.isNotEmpty) {
        out.add(
          DanmakuMessage(
            platform: 'kuaishou',
            user: name,
            content: content,
            timestamp: now,
          ),
        );
      }
    }
    for (final g in feed.bytesList(9)) {
      final gift = PbMessage(g);
      final user = gift.nested(2);
      final name = user?.string(2) ?? '匿名';
      final giftId = gift.intValue(4) ?? 0;
      final batch = gift.intValue(7) ?? 1;
      if (gift.intValue(17) == 0) continue; // danmakuDisplay=0 不显示
      out.add(
        DanmakuMessage(
          platform: 'kuaishou',
          user: name,
          content: '',
          timestamp: now,
          kind: DanmakuKind.gift,
          giftName: giftId > 0 ? '礼物#$giftId' : '礼物',
          giftCount: batch,
        ),
      );
    }
    return out;
  }

  @override
  Future<void> connect() async {
    if (_closed) return;
    if (wsUrl.isEmpty) {
      throw StateError('快手弹幕缺少 WebSocket 地址（需要先取流拿到会话）');
    }
    final packet = enterPacket;
    if ((packet == null || packet.isEmpty) &&
        (token.isEmpty || liveStreamId.isEmpty)) {
      throw StateError('快手弹幕缺少 token 或 liveStreamId（请重新取流）');
    }
    final ws = await WebSocket.connect(
      wsUrl,
      headers: {
        'User-Agent': _ua,
        'Origin': 'https://live.kuaishou.com',
        'Referer': 'https://live.kuaishou.com/u/$roomId',
      },
    );
    if (_closed) {
      await ws.close();
      return;
    }
    _ws = ws;
    final ready = Completer<void>();
    _readyCompleter = ready;
    ws.listen(
      _onData,
      onDone: _onClosed,
      onError: (Object _) => _onClosed(),
      cancelOnError: true,
    );
    ws.add(
      packet != null && packet.isNotEmpty
          ? packet
          : buildEnterRoomPacket(token, liveStreamId),
    );
    _startHeartbeat();
    try {
      await ready.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw StateError(
          '快手弹幕连接后 15 秒内未收到进房确认（会话参数可能已失效）',
        ),
      );
    } finally {
      if (identical(_readyCompleter, ready)) _readyCompleter = null;
    }
  }

  void _onData(Object? data) {
    if (data is! List<int> || data.isEmpty) return;
    try {
      final outer = PbMessage(data);
      final type = outer.intValue(1) ?? 0;
      final compression = outer.intValue(2) ?? compressionNone;
      final payload = outer.bytes(3);
      if (type == scEnterRoomAck || type == scFeedPush) {
        final ready = _readyCompleter;
        if (ready != null && !ready.isCompleted) {
          _reconnectAttempts = 0;
          ready.complete();
          _messages.add(
            DanmakuMessage(
              platform: 'kuaishou',
              user: '',
              content: '快手弹幕进房成功，已收到业务推送',
              timestamp: DateTime.now(),
              kind: DanmakuKind.system,
            ),
          );
        }
      }
      if (payload == null) return;
      switch (type) {
        case scFeedPush:
          for (final msg in parseFeedPayload(
            payload,
            compressed: compression == compressionGzip,
          )) {
            _messages.add(msg);
          }
          break;
        case scEnterRoomAck:
          break;
        case scPingAck:
        case scHeartbeatAck:
          break;
        case 103: // SC_ERROR
          final ready = _readyCompleter;
          if (ready != null && !ready.isCompleted) {
            ready.completeError(StateError('快手弹幕服务拒绝进房'));
          }
          break;
      }
    } catch (e) {
      _messages.add(
        DanmakuMessage(
          platform: 'kuaishou',
          user: '',
          content: '快手弹幕帧解析失败，已跳过: $e',
          timestamp: DateTime.now(),
          kind: DanmakuKind.system,
        ),
      );
    }
  }

  void _startHeartbeat() {
    _heartbeat?.cancel();
    final ws = _ws;
    if (ws != null && !_closed) {
      try {
        ws.add(buildHeartbeatPacket());
      } catch (_) {}
    }
    _heartbeat = Timer.periodic(_heartbeatInterval, (_) {
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
    final ready = _readyCompleter;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(StateError('快手弹幕 WebSocket 在进房确认前断开'));
      return;
    }
    if (_reconnectAttempts >= maxReconnectAttempts) {
      _messages.add(
        DanmakuMessage(
          platform: 'kuaishou',
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
            platform: 'kuaishou',
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
