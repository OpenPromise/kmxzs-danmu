part of '../flv_extractor.dart';

class DouyuFlvExtractor extends PlatformExtractor {
  DouyuFlvExtractor(super.dio);

  @override
  LivePlatform get platform => LivePlatform.douyu;

  @override
  Future<FlvExtractResult> extract(String input) async {
    var url = input;
    if (!url.startsWith('http')) url = 'https://www.douyu.com/$input';
    final res = await _dio.get(url);
    final body = res.data?.toString() ?? '';
    final urls = <String>[];
    for (final mm
        in RegExp(r'https?://[^\s"<>]+\.flv[^\s"<>]*').allMatches(body)) {
      urls.add(_cleanUrl(mm.group(0)!));
    }
    final uniq = _rankFlv(_uniq(urls.where(_looksPlayableFlv)));
    if (uniq.isEmpty) {
      return FlvExtractResult.fail('斗鱼未提取到地址', platform: LivePlatform.douyu);
    }
    return FlvExtractResult.ok(
      platform: LivePlatform.douyu,
      flvUrls: uniq,
      hlsUrls: const [],
      allUrls: uniq,
    );
  }
}
