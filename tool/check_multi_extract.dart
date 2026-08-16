import 'package:kmxzs/services/flv_extractor.dart';

Future<void> main() async {
  final ex = FlvExtractor();
  final cases = <String>[
    'https://live.bilibili.com/6',
    'https://www.youtube.com/watch?v=VpbELTMtAXo',
    'https://live.douyin.com/123456', // may fail offline
  ];
  for (final u in cases) {
    print('===== $u');
    final r = await ex.extract(u);
    print('ok=${r.ok} platform=${r.platform} room=${r.roomId}');
    print(r.ok ? 'best=${r.bestUrl().substring(0, r.bestUrl().length.clamp(0, 120))}...' : r.message.split('\n').take(4).join(' | '));
  }
}
