import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kmxzs/pages/ks_web_pull_page.dart';
import 'package:kmxzs/services/flv_extractor.dart';

/// 快手解析相关纯本地单测：只做字符串/JSON 解析，不打任何外网。
void main() {
  group('FlvExtractor.hasKuaishouLoginCookie', () {
    test('userId+passToken 只算弱信号，不算已登录', () {
      expect(
        FlvExtractor.hasKuaishouLoginCookie('userId=1; passToken=x'),
        isFalse,
      );
      expect(
        FlvExtractor.hasKuaishouLoginCookie('userId=1; passToken=x; web_st=y'),
        isFalse,
      );
    });

    test('live/server 域 web_st 才算是直播站登录态', () {
      expect(
        FlvExtractor.hasKuaishouLoginCookie('kuaishou.live.web_st=abc; did=web_1'),
        isTrue,
      );
      expect(
        FlvExtractor.hasKuaishouLoginCookie('kuaishou.server.web_st=abc; did=web_1'),
        isTrue,
      );
      expect(FlvExtractor.hasKuaishouLoginCookie(null), isFalse);
      expect(FlvExtractor.hasKuaishouLoginCookie(''), isFalse);
    });
  });

  group('FlvExtractor.looksLikeKuaishou', () {
    test('房间号与域名都识别为快手', () {
      expect(FlvExtractor.looksLikeKuaishou('WOT-360-CN'), isTrue);
      expect(
        FlvExtractor.looksLikeKuaishou('https://live.kuaishou.com/u/WOT-360-CN'),
        isTrue,
      );
      expect(FlvExtractor.looksLikeKuaishou('123456'), isFalse);
    });
  });

  group('FlvExtractor.ksJsObjectToJson', () {
    test('删除尾逗号，而不是替换成字面量 \$1', () {
      expect(FlvExtractor.ksJsObjectToJson('{a:1,}'), '{a:1}');
      expect(
        FlvExtractor.ksJsObjectToJson('{a:1, b:2, c:[3,4,],}'),
        '{a:1, b:2, c:[3,4]}',
      );
    });

    test('undefined / NaN 洗成 null', () {
      expect(
        FlvExtractor.ksJsObjectToJson('{a:undefined, b:2,}'),
        '{a:null, b:2}',
      );
      expect(
        FlvExtractor.ksJsObjectToJson('{a:NaN}'),
        '{a:null}',
      );
    });
  });

  group('FlvExtractor.ksLiveStreamChunk', () {
    test('抠出 {"liveStream"...},"gameInfo 并补全括号为合法 JSON', () {
      // gameInfo 是 liveStream 的兄弟键；liveStream 值对象先闭合，外层 `{` 由补的 `}` 闭合
      const state =
          '{"liveStream":{"playUrls":{"h264":{"adaptationSet":'
          '{"representation":[{"url":"x"}]}}},"hevc":{}},"gameInfo":{}}';
      final chunk = FlvExtractor.ksLiveStreamChunk(state);
      expect(chunk, isNotNull);
      final decoded = jsonDecode(chunk!);
      expect(decoded, isA<Map<String, dynamic>>());
      expect(decoded['liveStream'], isA<Map<String, dynamic>>());
    });
  });

  group('FlvExtractor.ksParseInitialStateHtml', () {
    const flvUrl =
        'https://pull-flv-xxx.kuaishou.com/live/stream_1234567890.flv'
        '?k=1&token=abcdefghijklmnopqrstuvwxyz0123456789';

    test('从 INITIAL_STATE HTML 抽出 h264 的 FLV（忽略 hevc）', () {
      // 注意：liveStream 值对象在 "hevc" 之后即闭合（一个 }），随后才是 ,"gameInfo"；
      // 正则捕获组不含外层结尾 `}`，由 ksLiveStreamChunk 补上。
      const html = '''
<!DOCTYPE html>
<html>
<head><script>
window.__INITIAL_STATE__={"liveStream":{"playUrls":{"h264":{"adaptationSet":{"representation":[{"url":"$flvUrl"}]}}},"hevc":{}},"gameInfo":{}};(function(){var s;
</script></head>
</html>
''';
      final r = FlvExtractor.ksParseInitialStateHtml(html);
      expect(r.flvUrls, contains(flvUrl));
      expect(r.flvUrls, isNotEmpty);
    });

    test('无 INITIAL_STATE 时返回空，不抛错', () {
      final r = FlvExtractor.ksParseInitialStateHtml('<html>no state</html>');
      expect(r.flvUrls, isEmpty);
      expect(r.hlsUrls, isEmpty);
    });

    test('风控 errorType type=2 会被标记 rateLimited', () {
      const html = '''
window.__INITIAL_STATE__={"liveStream":{"errorType":{"title":"操作频繁","content":"请稍后再试","type":2},"living":true},"gameInfo":{}};(function(){var s;
''';
      final r = FlvExtractor.ksParseInitialStateHtml(html);
      expect(r.rateLimited, isTrue);
      expect(r.livingTrue, isTrue);
    });
  });

  group('KsWebPullPage.hrefIsTargetRoom', () {
    test('必须是 /u/房间号，不能拿其它直播间的残留页', () {
      expect(
        KsWebPullPage.hrefIsTargetRoom(
          'https://live.kuaishou.com/u/majiangsaishi',
          'majiangsaishi',
        ),
        isTrue,
      );
      expect(
        KsWebPullPage.hrefIsTargetRoom(
          'https://live.kuaishou.com/u/majiangsaishi?param=1',
          'majiangsaishi',
        ),
        isTrue,
      );
      expect(
        KsWebPullPage.hrefIsTargetRoom(
          'https://live.kuaishou.com/u/otherroom',
          'majiangsaishi',
        ),
        isFalse,
      );
      expect(
        KsWebPullPage.hrefIsTargetRoom(
          'https://live.kuaishou.com/',
          'majiangsaishi',
        ),
        isFalse,
      );
    });

    test('数字用户 ID 与房间短号并存时不算进错房', () {
      expect(
        KsWebPullPage.principalMatchesRoom('123456789', 'majiangsaishi'),
        isTrue,
      );
      expect(
        KsWebPullPage.principalMatchesRoom('majiangsaishi', 'majiangsaishi'),
        isTrue,
      );
      expect(
        KsWebPullPage.principalMatchesRoom('otherroom', 'majiangsaishi'),
        isFalse,
      );
    });
  });

  group('KsWebPullPage.pickCurrentRoomUrls', () {
    const href = 'https://live.kuaishou.com/u/3xv3remku8txrpa';
    const mine =
        'https://tx-origin.pull.yximgs.com/gifshow/CURRENT_GameAvcHdL0.flv?x=1';
    const other =
        'https://tx-origin.pull.yximgs.com/gifshow/OTHER_GameAvcHdL0.flv?x=1';

    test('只取 author.id 等于房间号的那一项，丢掉推荐位', () {
      final urls = KsWebPullPage.pickCurrentRoomUrls(
        rid: '3xv3remku8txrpa',
        href: href,
        items: [
          (principalId: '3xv3remku8txrpa', urls: [mine]),
          (principalId: 'cncs2020', urls: [other]),
        ],
      );
      expect(urls, [mine]);
    });

    test('当前房间还没有地址时，不得用推荐位的流顶上', () {
      final urls = KsWebPullPage.pickCurrentRoomUrls(
        rid: '3xv3remku8txrpa',
        href: href,
        items: [
          (principalId: '', urls: []),
          (principalId: 'cncs2020', urls: [other]),
        ],
      );
      expect(urls, isEmpty);
    });

    test('地址栏已是该房间且当前项有地址、作者暂时为空时，仍取当前项', () {
      final urls = KsWebPullPage.pickCurrentRoomUrls(
        rid: '3xv3remku8txrpa',
        href: href,
        activeIndex: 0,
        items: [
          (principalId: '', urls: [mine]),
          (principalId: 'cncs2020', urls: [other]),
        ],
      );
      expect(urls, [mine]);
    });

    test('地址栏已是该房间且播放器已请求 flv 时，可用这条', () {
      final urls = KsWebPullPage.pickCurrentRoomUrls(
        rid: '3xv3remku8txrpa',
        href: href,
        items: const [],
        extraUrls: [mine],
      );
      expect(urls, [mine]);
    });
  });
}
