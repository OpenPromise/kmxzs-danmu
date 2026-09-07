import 'package:flutter_test/flutter_test.dart';
import 'package:kmxzs/services/flv_extractor.dart';

void main() {
  test('断流测试工具的回环 FLV 地址可直接进入 OBS', () async {
    const url =
        'http://127.0.0.1:19090/auto-stop-test-live-stream.flv';

    expect(FlvExtractor.isAutoStopTestUrl(url), isTrue);
    expect(
      FlvExtractor.isAutoStopTestUrl(
        'http://example.com/auto-stop-test-live-stream.flv',
      ),
      isFalse,
    );

    final result = await FlvExtractor().extract(url);
    expect(result.ok, isTrue);
    expect(result.bestUrl(), url);
    expect(result.platform, LivePlatform.unknown);
  });
}
