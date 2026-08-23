import 'dart:async';
import 'dart:io';

import 'danmaku_client.dart';
import 'danmaku_message.dart';
import 'proto_reader.dart';

/// 快手直播弹幕客户端。
///
/// 连接信息（ws url + token + principalId）来自网页 `__INITIAL_STATE__`
/// 的 `liveroom.websocketInfo`，由快手取流 WebView 会话捕获后传入。
/// 协议：外层 `SocketMessage{payloadType, compressionType, payload}`，
/// 进房发 CS_ENTER_ROOM(200)，推送 SC_FEED_PUSH(310)，payload 为 protobuf
/// （GZIP 时先解压），弹幕在 SCWebFeedPush.commentFeeds。
class KuaishouDanmakuClient implements DanmakuClient {
  KuaishouDanmakuClient({
    required this.roomId,
    required this.wsUrl,
    required this.token,
    required this.principalId,
  });

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  // SocketMessage.payloadType
  static const csPing = 4;
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
  final String principalId;

  final _messages = StreamController<DanmakuMessage>.broadcast();
  WebSocket? _ws;
  Timer? _heartbeat;
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  bool _closed = false;
  Duration _heartbeatInterval = const Duration(seconds: 15);

  @override
  String get platform => 'kuaishou';

  @override
  String get platformLabel => '快手';

  @override
  Stream<DanmakuMessage> get messages => _messages.stream;

  /// 构造进房包：SocketMessage{payloadType=200, compressionType=1,
  /// payload=CSWebEnterRoom{payloadType=200, payload{token, liveStreamId}}}。
  static List<int> buildEnterRoomPacket(String token, String principalId) {
    final payload = PbWriter();
    payload.stringField(1, token);
    payload.stringField(2, principalId);
    final enter = PbWriter();
    enter.varintField(1, csEnterRoom);
    enter.bytesField(3, payload.takeBytes());
    final outer = PbWriter();
    outer.varintField(1, csEnterRoom);
    outer.varintField(2, compressionNone);
    outer.bytesField(3, enter.takeBytes());
    return outer.takeBytes();
  }

  /// 心跳：SocketMessage{payloadType=CS_PING(4), compressionType=1}。
  static List<int> buildHeartbeatPacket() {
    final outer = PbWriter();
    outer.varintField(1, csPing);
    outer.varintField(2, compressionNone);
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
    ws.add(buildEnterRoomPacket(token, principalId));
    ws.listen(
      _onData,
      onDone: _onClosed,
      onError: (Object _) => _onClosed(),
      cancelOnError: true,
    );
    _startHeartbeat();
  }

  void _onData(Object? data) {
    if (data is! List<int> || data.isEmpty) return;
    final outer = PbMessage(data);
    final type = outer.intValue(1) ?? 0;
    final compression = outer.intValue(2) ?? compressionNone;
    final payload = outer.bytes(3);
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
        final ack = PbMessage(payload);
        final ms = ack.intValue(3) ?? 0;
        if (ms > 0) _heartbeatInterval = Duration(milliseconds: ms);
        break;
      case scPingAck:
      case scHeartbeatAck:
        break;
    }
  }

  void _startHeartbeat() {
    _heartbeat?.cancel();
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
