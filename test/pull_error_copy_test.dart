import 'package:flutter_test/flutter_test.dart';
import 'package:kmxzs/services/flv_extractor.dart';
import 'package:kmxzs/services/pull_error_copy.dart';

void main() {
  group('PullErrorCopy.userFacing', () {
    test('抖音失败保留房间号和提示，不误判成快手频繁操作', () {
      const raw = '抖音房间 1415534312 未解析到可播地址（未开播 / 风控 / 需更新解析）\n'
          '提示: 请使用 https://live.douyin.com/房间号\n'
          '已获取 ttwid\n'
          '来源: 直播页 HTML';
      expect(
        PullErrorCopy.userFacing(raw, platform: LivePlatform.douyin),
        '抖音房间 1415534312 未解析到可播地址（未开播 / 风控 / 需更新解析）\n'
        '提示: 请使用 https://live.douyin.com/房间号',
      );
    });

    test('快手风控仍提示操作过于频繁', () {
      const raw = '快手房间 abc 拉流失败：已触发快手风控/频率限制。请关闭 TUN / 系统代理，等 5–10 分钟再试（无需重新登录）。\n'
          '提示：请确认主播正在直播；未登录时先点「登录快手账号」。';
      expect(
        PullErrorCopy.userFacing(raw, platform: LivePlatform.kuaishou),
        '操作过于频繁，请关闭代理后等几分钟再试',
      );
    });

    test('B站未开播显示 B 站原文而不是通用未开播', () {
      const raw = 'B站房间 123 未开播\nlive_status=0';
      expect(
        PullErrorCopy.userFacing(raw, platform: LivePlatform.bilibili),
        'B站房间 123 未开播',
      );
    });

    test('TikTok 失败保留原提示', () {
      const raw = 'TikTok 未解析到可播地址。请确认主播正在直播并关闭代理后重试。';
      expect(
        PullErrorCopy.userFacing(raw, platform: LivePlatform.tiktok),
        raw,
      );
    });
  });
}
