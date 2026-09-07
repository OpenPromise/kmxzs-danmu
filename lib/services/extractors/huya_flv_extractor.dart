part of '../flv_extractor.dart';

class HuyaFlvExtractor extends PlatformExtractor {
  HuyaFlvExtractor(super.dio);

  @override
  LivePlatform get platform => LivePlatform.huya;

  @override
  Future<FlvExtractResult> extract(String input) async {
    var url = input;
    if (!url.startsWith('http')) url = 'https://www.huya.com/$input';
    final res = await _dio.get(url);
    final body = res.data?.toString() ?? '';
    final urls = <String>[];
    for (final mm
        in RegExp(r'https?://[^\s"<>]+flv[^\s"<>]*').allMatches(body)) {
      urls.add(_cleanUrl(mm.group(0)!));
    }
    final uniq = _rankFlv(_uniq(urls.where(_looksPlayableFlv)));
    if (uniq.isEmpty) {
      return FlvExtractResult.fail('虎牙未提取到地址', platform: LivePlatform.huya);
    }
    return FlvExtractResult.ok(
      platform: LivePlatform.huya,
      flvUrls: uniq,
      hlsUrls: const [],
      allUrls: uniq,
    );
  }
}
