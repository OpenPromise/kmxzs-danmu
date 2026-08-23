import 'dart:async';

import 'package:kmxzs/services/danmaku/danmaku_message.dart';
import 'package:kmxzs/services/danmaku/douyin_danmaku_client.dart';

/// 真实网络冒烟：连抖音直播间收 25 秒弹幕。
/// 用法：dart run tool/check_douyin_danmaku.dart <房间号>
Future<void> main(List<String> args) async {
  final room = args.isNotEmpty ? args[0] : '1415534312';
  final client = DouyinDanmakuClient(roomId: room);
  final sub = client.messages.listen((m) {
    if (m.kind != DanmakuKind.system) {
      print('[${m.platformLabel}] ${m.displayText}');
    } else {
      print('[system] ${m.content}');
    }
  });
  try {
    await client.connect();
    print('connected to douyin room $room, listening 25s...');
    await Future.delayed(const Duration(seconds: 25));
    print('done');
  } catch (e) {
    print('FAIL: $e');
  } finally {
    await sub.cancel();
    await client.dispose();
  }
}
