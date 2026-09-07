import 'package:flutter_test/flutter_test.dart';
import 'package:kmxzs/config/app_config.dart';
import 'package:kmxzs/services/douyin_random_live.dart';

void main() {
  test('抖音随机轮播已向用户开放', () {
    expect(AppConfig.randomDouyinFeatureEnabled, isTrue);
  });

  test('从抖音推荐回包筛出有播放流的直播房间', () {
    final candidates = DouyinRandomLiveFinder.parseCandidates({
      'status_code': 0,
      'data': [
        {
          'web_rid': '123456789',
          'data': {
            'id_str': '7000000000000000001',
            'title': '测试直播',
            'is_replay': false,
            'owner': {'nickname': '测试主播'},
            'stream_url': {
              'flv_pull_url': {
                'HD1': 'https://pull.example/live.flv?sign=ok',
              },
            },
          },
        },
        {
          'web_rid': '987654321',
          'data': {
            'id_str': '7000000000000000002',
            'title': '已结束房间',
            'owner': {'nickname': '无流主播'},
            'stream_url': {'flv_pull_url': {}},
          },
        },
      ],
    });

    expect(candidates, hasLength(1));
    expect(candidates.single.webRid, '123456789');
    expect(candidates.single.roomId, '7000000000000000001');
    expect(candidates.single.title, '测试直播');
    expect(candidates.single.anchor, '测试主播');
    expect(candidates.single.roomUrl, 'https://live.douyin.com/123456789');
  });

  test('回放、重复 web_rid 和异常回包不会进入候选', () {
    final replayRoom = {
      'web_rid': '123',
      'data': {
        'is_replay': true,
        'stream_url': {
          'hls_pull_url_map': {'HD1': 'https://pull.example/live.m3u8'},
        },
      },
    };
    expect(
      DouyinRandomLiveFinder.parseCandidates({
        'status_code': 0,
        'data': [replayRoom],
      }),
      isEmpty,
    );
    expect(
      DouyinRandomLiveFinder.parseCandidates({
        'status_code': 10011,
        'data': const [],
      }),
      isEmpty,
    );
  });
}
