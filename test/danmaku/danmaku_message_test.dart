import 'package:flutter_test/flutter_test.dart';
import 'package:kmxzs/services/danmaku/danmaku_message.dart';

void main() {
  DanmakuMessage message(String platform, DanmakuKind kind) => DanmakuMessage(
        platform: platform,
        user: '用户',
        content: '内容',
        timestamp: DateTime(2026),
        kind: kind,
      );

  test('隐藏抖音和快手礼物消息', () {
    expect(message('douyin', DanmakuKind.gift).hiddenFromDisplay, isTrue);
    expect(message('kuaishou', DanmakuKind.gift).hiddenFromDisplay, isTrue);
  });

  test('保留抖音快手文字弹幕及其他平台礼物消息', () {
    expect(message('douyin', DanmakuKind.chat).hiddenFromDisplay, isFalse);
    expect(message('kuaishou', DanmakuKind.chat).hiddenFromDisplay, isFalse);
    expect(message('bilibili', DanmakuKind.gift).hiddenFromDisplay, isFalse);
  });
}
