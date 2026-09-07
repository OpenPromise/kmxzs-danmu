import 'dart:async';
import 'dart:io';

import 'package:kmxzs/services/danmaku/danmaku_message.dart';
import 'package:kmxzs/services/danmaku/douyin_danmaku_client.dart';
import 'package:kmxzs/services/danmaku/douyin_ws_sign.dart';
import 'package:kmxzs/services/danmaku/proto_reader.dart';

/// 调试工具：打印抖音弹幕 WS 每一帧的解析摘要。
/// 用法：dart run tool/debug_douyin_ws.dart [房间号]
Future<void> main(List<String> args) async {
  var room = '1415534312';
  String? cookieOverride;
  var printAllFrames = false;
  var listenSeconds = 180;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--cookie' && i + 1 < args.length) {
      cookieOverride = args[i + 1];
      i++;
    } else if (args[i] == '--all') {
      printAllFrames = true;
    } else if (args[i] == '--seconds' && i + 1 < args.length) {
      listenSeconds = int.tryParse(args[++i]) ?? listenSeconds;
    } else {
      room = args[i];
    }
  }
  final prepared = await DouyinDanmakuClient.prepareConnection(
    roomId: room,
    cookie: cookieOverride,
  );
  final stub =
      DouyinDanmakuClient.xmsStub(prepared.roomId, prepared.userUniqueId);
  final signature = DouyinWsSigner().sign(stub);
  final host = DouyinDanmakuClient.pushHost(prepared.pushServer);
  final url = 'wss://$host/webcast/im/push/v2/?'
      '${DouyinDanmakuClient.buildWsQuery(
    room: prepared.roomId,
    userUniqueId: prepared.userUniqueId,
    cursor: prepared.cursor,
    internalExt: prepared.internalExt,
    signature: signature,
  )}';
  print(
      'room=${prepared.roomId} userUniqueId=${prepared.userUniqueId} host=$host');
  print('cursor=${prepared.cursor}');
  print('heartbeatDuration=${prepared.heartbeatDuration}');
  print('internalExt=${prepared.internalExt}');
  print('urlLen=${url.length}');
  print('URL=$url');

  final ws = await WebSocket.connect(
    url,
    headers: {
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36',
      'Origin': 'https://live.douyin.com',
      'Referer': 'https://live.douyin.com/',
      'Cookie': cookieOverride ?? prepared.cookie,
    },
  );
  print('ws connected, listening ${listenSeconds}s...');
  // 与浏览器一致：连上立刻发一次心跳
  ws.add(DouyinDanmakuClient.buildHeartbeatFrame());
  final heartbeat = Timer.periodic(const Duration(seconds: 20), (_) {
    try {
      ws.add(DouyinDanmakuClient.buildHeartbeatFrame());
    } catch (_) {}
  });
  var frameCount = 0;
  final methodCounts = <String, int>{};
  ws.listen((data) {
    if (data is! List<int>) return;
    frameCount++;
    final r = DouyinDanmakuClient.inspectFrame(data);
    if (r.summary.contains('WebcastChatMessage')) {
      dumpChatFrame(data);
    }
    if (printAllFrames || r.messages.isNotEmpty || frameCount % 30 == 0) {
      print('[frame $frameCount] ${r.summary}');
    }
    for (final m in r.messages) {
      if (m.kind != DanmakuKind.system) print('  -> ${m.displayText}');
    }
    final m = RegExp(r'methods=\[([^\]]*)\]').firstMatch(r.summary);
    if (m != null) {
      for (final name in m.group(1)!.split(',')) {
        final n = name.trim();
        if (n.isNotEmpty && n != '?') {
          methodCounts[n] = (methodCounts[n] ?? 0) + 1;
        }
      }
    }
  }, onDone: () {
    print('ws closed');
  }, onError: (Object e) {
    print('ws error: $e');
  });
  await Future.delayed(Duration(seconds: listenSeconds));
  heartbeat.cancel();
  print('total frames=$frameCount methods=$methodCounts');
  await ws.close();
  print('done');
}

void dumpChatFrame(List<int> data) {
  final frame = PbMessage(data);
  final payload = frame.bytes(8) ?? frame.bytes(7);
  if (payload == null) return;
  List<int> decoded;
  try {
    decoded = gzip.decode(payload);
  } catch (_) {
    decoded = payload;
  }
  final resp = PbMessage(decoded);
  for (final raw in resp.bytesList(1)) {
    final msg = PbMessage(raw);
    final method = msg.string(1) ?? '';
    if (method != 'WebcastChatMessage') continue;
    final chat = PbMessage(msg.bytes(2)!);
    print('CHAT FRAME fields:');
    for (final field in chat.rawFields()) {
      print('  field ${field.$1} wire ${field.$2} => ${field.$3}');
    }
  }
}
