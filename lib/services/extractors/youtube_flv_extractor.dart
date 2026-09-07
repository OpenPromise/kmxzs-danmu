part of '../flv_extractor.dart';

class YoutubeFlvExtractor extends PlatformExtractor {
  YoutubeFlvExtractor(super.dio);

  @override
  LivePlatform get platform => LivePlatform.youtube;

  String? _youtubeVideoId(String input) {
    final text = input.trim();
    final patterns = [
      RegExp(r'youtu\.be/([A-Za-z0-9_-]{11})'),
      RegExp(r'[?&]v=([A-Za-z0-9_-]{11})'),
      RegExp(r'youtube\.com/live/([A-Za-z0-9_-]{11})'),
      RegExp(r'youtube\.com/embed/([A-Za-z0-9_-]{11})'),
      RegExp(r'youtube\.com/shorts/([A-Za-z0-9_-]{11})'),
      RegExp(r'^([A-Za-z0-9_-]{11})$'),
    ];
    for (final p in patterns) {
      final m = p.firstMatch(text);
      if (m != null) return m.group(1);
    }
    return null;
  }

  @override
  Future<FlvExtractResult> extract(String input) async {
    final notes = <String>[];
    final hls = <String>[];
    final flv = <String>[];
    final vid = _youtubeVideoId(input);
    final watchUrl = vid != null
        ? 'https://www.youtube.com/watch?v=$vid'
        : (input.startsWith('http')
            ? input
            : 'https://www.youtube.com/watch?v=$input');
    notes.add('video=${vid ?? watchUrl}');

    // 1) 页面 ytInitialPlayerResponse（部分直播有 hlsManifestUrl）
    try {
      final res = await _dio.get(
        watchUrl,
        options: Options(headers: {
          'User-Agent': _ua,
          'Accept-Language': 'en-US,en;q=0.9',
        }),
      );
      final body = res.data?.toString() ?? '';
      final hlsInPage = RegExp(r'"hlsManifestUrl"\s*:\s*"([^"]+)"')
          .allMatches(body)
          .map((m) => _cleanUrl(m.group(1)!.replaceAll(r'\u0026', '&')))
          .where((u) => u.contains('m3u8'));
      hls.addAll(hlsInPage);
      if (hls.isNotEmpty) notes.add('来源: 页面 hlsManifestUrl');

      final player = _extractYtPlayerResponse(body);
      if (player != null) {
        final vd = player['videoDetails'];
        if (vd is Map) {
          notes.add('isLive=${vd['isLive']} title=${vd['title']}');
        }
        final sd = player['streamingData'];
        if (sd is Map) {
          final hm = sd['hlsManifestUrl']?.toString();
          if (hm != null && hm.contains('m3u8')) hls.add(_cleanUrl(hm));
          // progressive formats（带音视频）
          final formats = sd['formats'];
          if (formats is List) {
            for (final f in formats) {
              if (f is! Map) continue;
              final u = f['url']?.toString();
              if (u != null && u.startsWith('http')) {
                // YouTube 很少 flv；当作通用可播地址放 hls 列表前亦可
                hls.add(_cleanUrl(u));
              }
            }
          }
        }
      }
    } catch (e) {
      notes.add('页面解析失败: $e');
    }

    // 2) yt-dlp（最稳，能拿到直播 HLS）
    if (hls.isEmpty && flv.isEmpty) {
      final fromDl = await _ytDlpGetUrls(watchUrl);
      if (fromDl.isNotEmpty) {
        notes.add('来源: yt-dlp');
        for (final u in fromDl) {
          if (u.contains('.flv')) {
            flv.add(u);
          } else {
            hls.add(u);
          }
        }
      } else {
        notes.add(
          '未找到 yt-dlp。YouTube 直播建议安装: pip install yt-dlp',
        );
      }
    }

    final flvU = _rankFlv(_uniq(flv));
    final hlsU = _uniq(hls);
    if (flvU.isEmpty && hlsU.isEmpty) {
      return FlvExtractResult.fail(
        'YouTube 未解析到可播地址（需开播中，且建议安装 yt-dlp）\n${notes.join('\n')}',
        platform: LivePlatform.youtube,
        roomId: vid,
      );
    }
    return FlvExtractResult.ok(
      platform: LivePlatform.youtube,
      roomId: vid,
      flvUrls: flvU,
      hlsUrls: hlsU,
      allUrls: [...flvU, ...hlsU],
      note: notes.join('；'),
    );
  }

  Map<String, dynamic>? _extractYtPlayerResponse(String body) {
    const marker = 'ytInitialPlayerResponse';
    final idx = body.indexOf(marker);
    if (idx < 0) return null;
    final start = body.indexOf('{', idx);
    if (start < 0) return null;
    var depth = 0;
    for (var i = start; i < body.length; i++) {
      final ch = body[i];
      if (ch == '{') {
        depth++;
      } else if (ch == '}') {
        depth--;
        if (depth == 0) {
          try {
            final j = jsonDecode(body.substring(start, i + 1));
            if (j is Map) return Map<String, dynamic>.from(j);
          } catch (_) {
            // 片段不是合法 JSON 时放弃该片段，返回 null 交给上层
          }
          return null;
        }
      }
    }
    return null;
  }
}
