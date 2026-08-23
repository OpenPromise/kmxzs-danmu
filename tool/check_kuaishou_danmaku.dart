import 'dart:async';

import 'package:kmxzs/services/danmaku/danmaku_message.dart';
import 'package:kmxzs/services/danmaku/kuaishou_danmaku_client.dart';

/// 快手弹幕冒烟：需要从登录后的快手直播间页 __INITIAL_STATE__ 拿到的会话参数。
/// 用法：
///   dart run tool/check_kuaishou_danmaku.dart <房间号> <wsUrl> <token> <principalId>
Future<void> main(List<String> args) async {
  if (args.length < 4) {
    print('用法: dart run tool/check_kuaishou_danmaku.dart <房间号> <wsUrl> <token> <principalId>');
    return;
  }
  final client = KuaishouDanmakuClient(
    roomId: args[0],
    wsUrl: args[1],
    token: args[2],
    principalId: args[3],
  );
  final sub = client.messages.listen((m) {
    if (m.kind != DanmakuKind.system) {
      print('[${m.platformLabel}] ${m.displayText}');
    } else {
      print('[system] ${m.content}');
    }
  });
  try {
    await client.connect();
    print('connected, listening 25s...');
    await Future.delayed(const Duration(seconds: 25));
    print('done');
  } catch (e) {
    print('FAIL: $e');
  } finally {
    await sub.cancel();
    await client.dispose();
  }
}
