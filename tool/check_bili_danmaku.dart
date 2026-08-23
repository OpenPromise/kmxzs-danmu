import 'dart:async';

import 'package:kmxzs/services/danmaku/bilibili_danmaku_client.dart';
import 'package:kmxzs/services/danmaku/danmaku_message.dart';

/// 真实网络冒烟：连 B 站直播间收 20 秒弹幕。
/// 用法：dart run tool/check_bili_danmaku.dart [房间号]
Future<void> main(List<String> args) async {
  final room = args.isNotEmpty ? args[0] : '3';
  final client = BilibiliDanmakuClient(roomId: room);
  final sub = client.messages.listen((m) {
    if (m.kind != DanmakuKind.system) {
      print('[${m.platformLabel}] ${m.displayText}');
    } else {
      print('[system] ${m.content}');
    }
  });
  try {
    await client.connect();
    print('connected to B站 room $room, listening 20s...');
    await Future.delayed(const Duration(seconds: 20));
    print('done');
  } catch (e) {
    print('FAIL: $e');
  } finally {
    await sub.cancel();
    await client.dispose();
  }
}
