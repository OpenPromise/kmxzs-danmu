import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import '../douyin_abogus.dart';
import 'danmaku_client.dart';
import 'danmaku_message.dart';
import 'douyin_ws_sign.dart';
import 'proto_reader.dart';

/// 抖音直播弹幕客户端（网页端 WebSocket 协议）。
///
/// 流程：拿 ttwid → 解析真实房间号 → `webcast/im/fetch` 预取游标 →
/// 计算 X-MS-STUB + 紧凑签名 → 连 `wss://.../webcast/im/push/v2/` →
/// PushFrame(payload 字段 8, gzip) → Response → Message(method=WebcastChatMessage)。
/// 心跳为 PushFrame{payloadType:"hb"}，服务端要求时回 ACK。
class DouyinDanmakuClient implements DanmakuClient {
  DouyinDanmakuClient({
    required this.roomId,
    String? cookie,
    Dio? dio,
    DouyinWsSigner? signer,
    this.parseErrorNoticeInterval = const Duration(seconds: 30),
  })  : _cookie = cookie,
        _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 10),
                receiveTimeout: const Duration(seconds: 15),
                headers: {
                  'User-Agent': _ua,
                  'Referer': 'https://live.douyin.com/',
                  'Origin': 'https://live.douyin.com',
                },
              ),
            ),
        _signer = signer ?? DouyinWsSigner();

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36';

  static const _aid = '6383';
  static const _versionCode = '180800';
  static const _sdkVersion = '1.0.15';
  static const _liveId = '1';
  static const _didRule = '3';
  static const _identity = 'audience';
  static const _endpoint = 'live_pc';
  static const _imPath = '/webcast/im/fetch/';
  static const _defaultPushHost = 'webcast100-ws-web-lf.douyin.com';

  static const maxReconnectAttempts = 5;

  /// 同类坏帧通知的最短间隔，避免协议变化时系统消息和 UI 刷新刷屏。
  final Duration parseErrorNoticeInterval;

  @override
  final String roomId;

  final String? _cookie;
  final Dio _dio;
  final DouyinWsSigner _signer;

  final _messages = StreamController<DanmakuMessage>.broadcast();
  WebSocket? _ws;
  Timer? _heartbeat;
  Timer? _reconnectTimer;
  Completer<void>? _firstFrameCompleter;
  int _reconnectAttempts = 0;
  bool _closed = false;
  DateTime? _lastParseErrorNoticeAt;

  @override
  String get platform => 'douyin';

  @override
  String get platformLabel => '抖音';

  @override
  Stream<DanmakuMessage> get messages => _messages.stream;

  /// 构造心跳帧：PushFrame{payloadType:"hb"}（即 3A 02 68 62）。
  static List<int> buildHeartbeatFrame() {
    final w = PbWriter();
    w.stringField(7, 'hb');
    return w.takeBytes();
  }

  /// 构造 ACK 帧：PushFrame{logId, payloadType:"ack", payload: internalExt}。
  static List<int> buildAckFrame(int logId, String internalExt) {
    final w = PbWriter();
    w.varintField(2, logId);
    w.stringField(7, 'ack');
    if (internalExt.isNotEmpty) w.stringField(8, internalExt);
    return w.takeBytes();
  }

  /// 计算 X-MS-STUB（固定参数字段按序拼接后的 MD5 hex）。
  static String xmsStub(String roomId, String userUniqueId) {
    final parts = [
      'live_id=$_liveId',
      'aid=$_aid',
      'version_code=$_versionCode',
      'webcast_sdk_version=$_sdkVersion',
      'room_id=$roomId',
      'sub_room_id=',
      'sub_channel_id=',
      'did_rule=$_didRule',
      'user_unique_id=$userUniqueId',
      'device_platform=web',
      'device_type=',
      'ac=',
      'identity=$_identity',
    ];
    return md5.convert(utf8.encode(parts.join(','))).toString();
  }

  @override
  Future<void> connect() async {
    if (_closed) return;
    final prepared = await prepareConnection(
      roomId: roomId,
      cookie: _cookie,
      dio: _dio,
    );
    final stub = xmsStub(prepared.roomId, prepared.userUniqueId);
    final signature = _signer.sign(stub);
    final host = pushHost(prepared.pushServer);
    final url = 'wss://$host/webcast/im/push/v2/?'
        '${buildWsQuery(room: prepared.roomId, userUniqueId: prepared.userUniqueId, cursor: prepared.cursor, internalExt: prepared.internalExt, signature: signature)}';

    final ws = await WebSocket.connect(
      url,
      headers: {
        'User-Agent': _ua,
        'Origin': 'https://live.douyin.com',
        'Referer': 'https://live.douyin.com/',
        if (prepared.cookie.isNotEmpty) 'Cookie': prepared.cookie,
      },
    );
    if (_closed) {
      await ws.close();
      return;
    }
    _ws = ws;
    final firstFrame = Completer<void>();
    _firstFrameCompleter = firstFrame;
    ws.listen(
      _onData,
      onDone: _onClosed,
      onError: (Object _) => _onClosed(),
      cancelOnError: true,
    );
    _startHeartbeat(prepared.heartbeatDuration);
    try {
      await firstFrame.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw StateError(
          '抖音弹幕连接仅收到心跳，15 秒内没有收到业务推送（房间参数可能失效）',
        ),
      );
    } finally {
      if (identical(_firstFrameCompleter, firstFrame)) {
        _firstFrameCompleter = null;
      }
    }
  }

  /// 连接前的完整准备：ttwid → 房间解析 → im/fetch。
  /// 返回建连所需全部参数，供 [connect] 与调试工具共用。
  static Future<
      ({
        String cookie,
        String roomId,
        String userUniqueId,
        String cursor,
        String internalExt,
        int heartbeatDuration,
        String pushServer,
      })> prepareConnection({
    required String roomId,
    String? cookie,
    Dio? dio,
  }) async {
    final d = dio ??
        Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 10),
            receiveTimeout: const Duration(seconds: 15),
            headers: {
              'User-Agent': _ua,
              'Referer': 'https://live.douyin.com/',
              'Origin': 'https://live.douyin.com',
            },
          ),
        );
    final suppliedCookie = cookie?.trim() ?? '';
    final c =
        suppliedCookie.isEmpty ? await _fetchTtwidCookie(d) : suppliedCookie;
    final room = await _resolveRoom(d, roomId, c);
    final fetch = await _imFetch(d, room.roomId, room.userUniqueId, c);
    final pushDid = userUniqueIdFromInternalExt(fetch.internalExt);
    final effectiveUserUniqueId =
        room.userUniqueId.isNotEmpty ? room.userUniqueId : pushDid;
    if (effectiveUserUniqueId.isEmpty) {
      throw const FormatException('抖音弹幕预取响应缺少 user_unique_id');
    }
    return (
      cookie: c,
      roomId: room.roomId,
      userUniqueId: effectiveUserUniqueId,
      cursor: fetch.cursor,
      internalExt: fetch.internalExt,
      heartbeatDuration: fetch.heartbeatDuration,
      pushServer: fetch.pushServer,
    );
  }

  /// 获取访问 live.douyin.com 下发的全部 Cookie（ttwid / UIFID_TEMP /
  /// __ac_nonce / __ac_signature 等）。只留 ttwid 会被推送网关拒绝。
  static Future<String> _fetchTtwidCookie(Dio dio) async {
    final res = await dio.get(
      'https://live.douyin.com/',
      options: Options(
        followRedirects: true,
        validateStatus: (_) => true,
      ),
    );
    final parts = <String>[];
    res.headers.forEach((name, values) {
      if (name.toLowerCase() != 'set-cookie') return;
      for (final c in values) {
        final first = c.split(';').first.trim();
        if (first.isNotEmpty &&
            first.contains('=') &&
            !first.startsWith('path=') &&
            !first.startsWith('domain=')) {
          parts.add(first);
        }
      }
    });
    if (!parts.any((e) => e.startsWith('ttwid='))) {
      parts.add(
        'ttwid=1%7Ckmxzs%7C${DateTime.now().millisecondsSinceEpoch ~/ 1000}%7Cplaceholder',
      );
    }
    return parts.join('; ');
  }

  /// 解析真实房间号与 user_unique_id。
  /// 16 位以上数字直接当 room_id；短号（web_rid）抓直播页 SSR 状态里的
  /// roomId 与 user_unique_id（主播用户 ID，WS 签名与 URL 都要用）。
  static Future<({String roomId, String userUniqueId})> _resolveRoom(
    Dio dio,
    String roomId,
    String cookie,
  ) async {
    final t = roomId.trim();
    if (RegExp(r'^\d{16,}$').hasMatch(t)) {
      return (roomId: t, userUniqueId: '');
    }
    if (t.isEmpty) throw ArgumentError.value(roomId, 'roomId', '房间号不能为空');
    final res = await dio.get(
      'https://live.douyin.com/$t',
      options: Options(
        headers: {
          'Accept':
              'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8',
          'Accept-Encoding': 'identity',
          'Referer': 'https://live.douyin.com/',
          if (cookie.isNotEmpty) 'Cookie': cookie,
        },
        followRedirects: true,
        validateStatus: (_) => true,
      ),
    );
    final html = res.data is String ? res.data as String : '';
    for (final candidate in _livePageCandidates(html)) {
      final realRoomId = _firstDigitsAfterMarkers(
          candidate,
          const [
            '"room":{"id_str":"',
            '\\"room\\":{\\"id_str\\":\\"',
            '"room":{"id":',
            '\\"room\\":{\\"id\\":',
            'room_id=',
            'room_id%3D',
            '"room_id":"',
            '\\"room_id\\":\\"',
            '"room_id":',
            '"room_id_str":"',
            '\\"room_id_str\\":\\"',
            '"roomId":"',
            '\\"roomId\\":\\"',
            '"roomId":',
            'gift_effect_bg_',
          ],
          minLength: 16);
      if (realRoomId.isEmpty) continue;
      final userUniqueId = _firstDigitsAfterMarkers(
          candidate,
          const [
            'user_unique_id=',
            'user_unique_id%3D',
            '"user_unique_id":"',
            '\\"user_unique_id\\":\\"',
            '"user_unique_id":',
          ],
          minLength: 10);
      return (
        roomId: realRoomId,
        userUniqueId: userUniqueId,
      );
    }
    throw StateError('抖音房间 $t 解析不到真实房间号（页面可能被风控）');
  }

  static List<String> _livePageCandidates(String html) {
    final out = <String>[html];
    var decoded = html;
    for (var i = 0; i < 6; i++) {
      final next = decoded
          .replaceAll(r'\\u0026', '&')
          .replaceAll(r'\u0026', '&')
          .replaceAll(r'\\\"', '"')
          .replaceAll(r'\"', '"');
      if (next == decoded) break;
      decoded = next;
      out.add(decoded);
    }
    return out;
  }

  static String _firstDigitsAfterMarkers(
    String source,
    List<String> markers, {
    required int minLength,
  }) {
    for (final marker in markers) {
      var from = 0;
      while (from < source.length) {
        final index = source.indexOf(marker, from);
        if (index < 0) break;
        var start = index + marker.length;
        while (start < source.length && ('"\' :'.contains(source[start]))) {
          start++;
        }
        var end = start;
        while (end < source.length) {
          final unit = source.codeUnitAt(end);
          if (unit < 0x30 || unit > 0x39) break;
          end++;
        }
        if (end - start >= minLength) return source.substring(start, end);
        from = index + marker.length;
      }
    }
    return '';
  }

  /// 预取 im/fetch：拿游标、internalExt、心跳间隔和推送服务器。
  static Future<
      ({
        String cursor,
        String internalExt,
        int heartbeatDuration,
        String pushServer,
      })> _imFetch(
    Dio dio,
    String realRoomId,
    String userUniqueId,
    String cookie,
  ) async {
    final query = imFetchQuery(realRoomId, userUniqueId);
    // 与网页一致：GET + a_bogus 签名 + msToken，拿到推送网关认可的 internal_ext。
    // 风控页、截断响应或本地签名失效时，改用 POST 再取一次。
    try {
      final ab = DouyinABogus().sign(query, userAgent: _ua);
      final abEncoded = Uri.encodeQueryComponent(ab);
      final bytes = await _fetchProto(
        dio,
        'https://live.douyin.com/webcast/im/fetch/?$query&a_bogus=$abEncoded',
        cookie: cookie,
      );
      return _decodeImFetch(bytes);
    } on StateError {
      // 请求失败转备用 POST。
    } on FormatException {
      // 非 protobuf 或被截断的响应转备用 POST。
    }

    final bytes = await _fetchProto(
      dio,
      'https://live.douyin.com/webcast/im/fetch/?$query',
      cookie: cookie,
      method: 'POST',
    );
    return _decodeImFetch(bytes);
  }

  static ({
    String cursor,
    String internalExt,
    int heartbeatDuration,
    String pushServer,
  }) _decodeImFetch(List<int> bytes) {
    final resp = PbMessage(bytes);
    final cursor = resp.string(2) ?? '';
    final internalExt = resp.string(5) ?? '';
    final pushServer = resp.string(10) ?? '';
    if (cursor.isEmpty && internalExt.isEmpty && pushServer.isEmpty) {
      throw const FormatException('抖音 im/fetch 响应缺少弹幕连接字段');
    }
    return (
      cursor: cursor,
      internalExt: internalExt,
      heartbeatDuration: (resp.intValue(8) ?? 0),
      pushServer: pushServer,
    );
  }

  static Future<List<int>> _fetchProto(
    Dio dio,
    String url, {
    required String cookie,
    String method = 'GET',
  }) async {
    Response<Object?> res;
    try {
      final options = Options(
        responseType: ResponseType.bytes,
        headers: {
          'Accept': '*/*',
          'Accept-Encoding': 'identity',
          'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
          if (cookie.isNotEmpty) 'Cookie': cookie,
        },
        validateStatus: (_) => true,
      );
      res = method == 'POST'
          ? await dio.post<Object?>(
              url,
              data: jsonEncode({
                'room_id': Uri.parse(url).queryParameters['room_id'] ?? '',
              }),
              options: options,
            )
          : await dio.get<Object?>(url, options: options);
    } on DioException catch (e) {
      throw StateError('抖音 im/fetch 请求失败: ${e.message}');
    }
    final status = res.statusCode;
    if (status == null || status < 200 || status >= 300) {
      throw StateError('抖音 im/fetch HTTP 异常: $status');
    }
    final contentType = (res.headers.value('content-type') ?? '').toLowerCase();
    if (contentType.contains('text/html') ||
        contentType.contains('application/json')) {
      throw StateError('抖音 im/fetch 返回非 protobuf 数据: $contentType');
    }
    final raw = res.data;
    if (raw is! List<int> || raw.isEmpty) {
      throw StateError(
        '抖音 im/fetch 无响应（HTTP ${res.statusCode}, type=${raw.runtimeType}, '
        'len=${raw is List ? raw.length : raw is String ? raw.length : '?'}）',
      );
    }
    return raw.length >= 2 && raw[0] == 0x1F && raw[1] == 0x8B
        ? gzip.decode(raw)
        : raw;
  }

  static String imFetchQuery(String realRoomId, String userUniqueId) {
    final ua = Uri.encodeQueryComponent(_ua);
    return [
      'resp_content_type=protobuf',
      'did_rule=$_didRule',
      'device_id=',
      'app_name=douyin_web',
      'endpoint=$_endpoint',
      'support_wrds=1',
      'user_unique_id=${Uri.encodeQueryComponent(userUniqueId)}',
      'identity=$_identity',
      'need_persist_msg_count=15',
      'insert_task_id=',
      'live_reason=',
      'room_id=${Uri.encodeQueryComponent(realRoomId)}',
      'version_code=$_versionCode',
      'last_rtt=0',
      'live_id=$_liveId',
      'aid=$_aid',
      'fetch_rule=1',
      'cursor=',
      'internal_ext=',
      'device_platform=web',
      'cookie_enabled=true',
      'screen_width=1920',
      'screen_height=1080',
      'browser_language=zh-CN',
      'browser_platform=Win32',
      'browser_name=Mozilla',
      'browser_version=$ua',
      'browser_online=true',
      'tz_name=Asia/Shanghai',
      'msToken=${_generateMsToken()}',
    ].join('&');
  }

  static final _rand = Random();

  /// 生成网页同款 msToken（172 位随机字符，仅 im/fetch 参数用）。
  static String _generateMsToken() {
    const chars =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_';
    final buf = StringBuffer();
    for (var i = 0; i < 172; i++) {
      buf.write(chars[_rand.nextInt(chars.length)]);
    }
    return buf.toString();
  }

  static String buildWsQuery({
    required String room,
    required String userUniqueId,
    required String cursor,
    required String internalExt,
    required String signature,
  }) {
    // 与网页端一致：只把空格转成 %20，`|`、`:`、`+`、`=` 等保持原样，
    // 否则 internal_ext 的字段分隔与 signature 都会被服务端误解码。
    String qv(String v) => v.replaceAll(' ', '%20');
    // 与网页一致：browser_version 去掉 "Mozilla/" 前缀，空格转 %20
    final ua = qv(
      _ua.startsWith('Mozilla/') ? _ua.substring('Mozilla/'.length) : _ua,
    );
    final q = <String, String>{
      'app_name': 'douyin_web',
      'version_code': _versionCode,
      'webcast_sdk_version': _sdkVersion,
      'update_version_code': _sdkVersion,
      'compress': 'gzip',
      'device_platform': 'web',
      'cookie_enabled': 'true',
      'screen_width': '1920',
      'screen_height': '1080',
      'browser_language': 'zh-CN',
      'browser_platform': 'Win32',
      'browser_name': 'Mozilla',
      'browser_version': ua,
      'browser_online': 'true',
      'tz_name': 'Asia/Shanghai',
      'cursor': cursor,
      'internal_ext': internalExt,
      'host': 'https://live.douyin.com',
      'aid': _aid,
      'live_id': _liveId,
      'did_rule': _didRule,
      'endpoint': _endpoint,
      'support_wrds': '1',
      'user_unique_id': userUniqueId,
      'im_path': _imPath,
      'identity': _identity,
      'need_persist_msg_count': '15',
      'insert_task_id': '',
      'live_reason': '',
      'room_id': room,
      'heartbeatDuration': '0',
      'signature': signature,
    };
    return q.entries.map((e) => '${e.key}=${qv(e.value)}').join('&');
  }

  /// 从 im/fetch 的 pushServer（可能是完整 wss URL）里取主机名。
  static String pushHost(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return _defaultPushHost;
    if (t.contains('://')) {
      try {
        final uri = Uri.parse(t);
        if (uri.host.isNotEmpty) return uri.host;
      } catch (_) {}
    }
    return t.replaceAll(RegExp(r'[/\\].*$'), '');
  }

  /// im/fetch 的 internal_ext 会下发本次访客 ID，必须与 WS 参数及签名一致。
  static String userUniqueIdFromInternalExt(String internalExt) {
    final match =
        RegExp(r'(?:^|\|)wss_push_did:([^|]+)').firstMatch(internalExt);
    return match?.group(1)?.trim() ?? '';
  }

  void _onData(Object? data) {
    if (data is! List<int> || data.isEmpty) return;
    try {
      final inspected = inspectFrame(data);
      if (inspected.logId != null && inspected.needAck) {
        _sendAck(inspected.logId!, inspected.internalExt);
      }
      final firstFrame = _firstFrameCompleter;
      if (inspected.methods.isNotEmpty &&
          firstFrame != null &&
          !firstFrame.isCompleted) {
        _reconnectAttempts = 0;
        firstFrame.complete();
        _messages.add(
          DanmakuMessage(
            platform: 'douyin',
            user: '',
            content: '弹幕通道已收到业务推送（首批 ${inspected.methods.length} 条）',
            timestamp: DateTime.now(),
            kind: DanmakuKind.system,
          ),
        );
      }
      for (final msg in inspected.messages) {
        _messages.add(msg);
      }
    } catch (e) {
      // 单个 schema 变化/损坏帧不能终止整条弹幕连接；跳过该帧并继续收包。
      final now = DateTime.now();
      final lastNotice = _lastParseErrorNoticeAt;
      if (lastNotice != null &&
          now.difference(lastNotice) < parseErrorNoticeInterval) {
        return;
      }
      _lastParseErrorNoticeAt = now;
      _messages.add(
        DanmakuMessage(
          platform: 'douyin',
          user: '',
          content: '弹幕帧解析失败，已跳过当前帧: $e',
          timestamp: now,
          kind: DanmakuKind.system,
        ),
      );
    }
  }

  /// 解析一帧 WS 数据：返回弹幕消息 + 帧摘要（诊断用）。
  static ({
    List<DanmakuMessage> messages,
    int? logId,
    bool needAck,
    String internalExt,
    List<String> methods,
    String summary,
  }) inspectFrame(List<int> data) {
    final frame = PbMessage(data);
    final logId = frame.intValue(2);
    final payloadType = frame.string(7) ?? '';
    // 新版 schema payload 在字段 8；旧版在字段 7（字段 7 是 "hb"/"ack" 时忽略）
    final payload = frame.bytes(8) ?? frame.bytes(7);
    if (payload == null || payload.isEmpty) {
      return (
        messages: const [],
        logId: logId,
        needAck: false,
        internalExt: '',
        methods: const [],
        summary: 'frame(payloadType=$payloadType, no payload)',
      );
    }
    List<int> decoded;
    var wasGzip = false;
    try {
      decoded = gzip.decode(payload);
      wasGzip = true;
    } catch (_) {
      decoded = payload;
    }
    final resp = PbMessage(decoded);
    final needAck = resp.intValue(9) == 1;
    final internalExt = resp.string(5) ?? '';
    final methods =
        resp.bytesList(1).map((b) => PbMessage(b).string(1) ?? '?').toList();
    final messages = decodeResponse(resp);
    return (
      messages: messages,
      logId: logId,
      needAck: needAck,
      internalExt: internalExt,
      methods: methods,
      summary:
          'frame(payloadType=$payloadType, ${wasGzip ? 'gzip ' : ''}payload=${payload.length}B, '
          'methods=$methods, chat=${messages.where((m) => m.kind == DanmakuKind.chat).length})',
    );
  }

  /// 解析 Response（gzip 已解压）里的业务消息，返回归一化弹幕。
  static List<DanmakuMessage> decodeResponse(PbMessage resp) {
    final out = <DanmakuMessage>[];
    for (final raw in resp.bytesList(1)) {
      out.addAll(decodeMessage(PbMessage(raw)));
    }
    return out;
  }

  /// 解析单条 Message（method + payload），非弹幕/礼物/进场返回空列表。
  static List<DanmakuMessage> decodeMessage(PbMessage msg) {
    final method = msg.string(1) ?? '';
    final payload = msg.bytes(2);
    if (payload == null || payload.isEmpty) return const [];
    final now = DateTime.now();
    switch (method) {
      case 'WebcastChatMessage':
        final chat = PbMessage(payload);
        // 当前标准布局：common=1 / user=2 / content=3（真实抓包验证）。
        final userBytes = chat.bytes(2);
        final content = chat.string(3) ?? '';
        var nickname = '匿名';
        if (userBytes != null) {
          final user = PbMessage(userBytes);
          nickname = user.string(1) ?? user.string(3) ?? '匿名';
        }
        if (content.isNotEmpty) {
          return [
            DanmakuMessage(
              platform: 'douyin',
              user: nickname,
              content: content,
              timestamp: now,
            ),
          ];
        }
        return const [];
      case 'WebcastGiftMessage':
        final gift = PbMessage(payload);
        final userBytes = gift.bytes(7);
        var name = '匿名';
        if (userBytes != null) {
          final user = PbMessage(userBytes);
          name = user.string(1) ?? user.string(3) ?? '匿名';
        }
        var giftName = '礼物';
        final giftStruct = gift.nested(15);
        if (giftStruct != null) {
          giftName = giftStruct.string(16) ?? giftStruct.string(2) ?? '礼物';
        }
        return [
          DanmakuMessage(
            platform: 'douyin',
            user: name,
            content: '',
            timestamp: now,
            kind: DanmakuKind.gift,
            giftName: giftName,
            giftCount: gift.intValue(5) ?? gift.intValue(6) ?? 1,
          ),
        ];
      case 'WebcastMemberMessage':
        final member = PbMessage(payload);
        final userBytes = member.bytes(2);
        var name = '匿名';
        if (userBytes != null) {
          final user = PbMessage(userBytes);
          name = user.string(1) ?? user.string(3) ?? '匿名';
        }
        return [
          DanmakuMessage(
            platform: 'douyin',
            user: name,
            content: '',
            timestamp: now,
            kind: DanmakuKind.enter,
          ),
        ];
    }
    return const [];
  }

  void _sendAck(int logId, String internalExt) {
    final ws = _ws;
    if (ws == null || _closed) return;
    try {
      ws.add(buildAckFrame(logId, internalExt));
    } catch (_) {}
  }

  void _startHeartbeat(int serverIntervalSec) {
    _heartbeat?.cancel();
    final ws = _ws;
    if (ws != null && !_closed) {
      try {
        ws.add(buildHeartbeatFrame());
      } catch (_) {}
    }
    final interval =
        Duration(seconds: serverIntervalSec > 0 ? serverIntervalSec : 30);
    _heartbeat = Timer.periodic(interval, (_) {
      final ws = _ws;
      if (ws == null || _closed) return;
      try {
        ws.add(buildHeartbeatFrame());
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
    final firstFrame = _firstFrameCompleter;
    if (firstFrame != null && !firstFrame.isCompleted) {
      firstFrame.completeError(
        StateError('抖音弹幕 WebSocket 在收到首帧前断开'),
      );
      return;
    }
    if (_reconnectAttempts >= maxReconnectAttempts) {
      _messages.add(
        DanmakuMessage(
          platform: 'douyin',
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
            platform: 'douyin',
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
