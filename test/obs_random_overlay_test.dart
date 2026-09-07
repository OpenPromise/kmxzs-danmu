import 'package:flutter_test/flutter_test.dart';
import 'package:kmxzs/services/obs_ws.dart';

void main() {
  test('随机抖音叠加层使用顶层索引', () {
    expect(ObsWs.topSceneItemIndex(0), 0);
    expect(ObsWs.topSceneItemIndex(1), 0);
    expect(ObsWs.topSceneItemIndex(4), 3);
  });

  test('颜色校正 v2 的 1% 透明度写成 0.0100', () {
    expect(
      ObsWs.opacitySettingForFilterKind(
        'color_filter_v2',
        ObsWs.randomOverlayOpacity,
      ),
      0.0100,
    );
    expect(
      ObsWs.opacitySettingForFilterKind(
        'color_filter',
        ObsWs.randomOverlayOpacity,
      ),
      1.0,
    );
  });

  test('弹幕浏览器源覆盖 OBS 画布且保持透明背景', () {
    final settings = ObsWs.danmakuBrowserInputSettings(
      'http://127.0.0.1:1956/danmaku',
      width: 1920,
      height: 1080,
    );
    expect(settings['url'], 'http://127.0.0.1:1956/danmaku');
    expect(settings['width'], 1920);
    expect(settings['height'], 1080);
    expect(settings['is_local_file'], isFalse);
    expect(settings['shutdown'], isFalse);
    expect(settings['reroute_audio'], isFalse);
  });
}
