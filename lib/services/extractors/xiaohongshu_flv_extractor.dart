part of '../flv_extractor.dart';

class XiaohongshuFlvExtractor extends PlatformExtractor {
  XiaohongshuFlvExtractor(super.dio);

  @override
  LivePlatform get platform => LivePlatform.xiaohongshu;

  @override
  Future<FlvExtractResult> extract(String input) async {
    final notes = <String>[];
    var url = input.trim();
    if (!url.startsWith('http')) {
      url = 'https://$url';
    }

    if (url.toLowerCase().contains('xhslink.com')) {
      try {
        final res = await _dio.get(
          url,
          options: Options(
            followRedirects: true,
            validateStatus: (_) => true,
            headers: _xhsHeaders(),
          ),
        );
        url = res.realUri.toString();
        notes.add('短链 → $url');
      } catch (e) {
        notes.add('短链解析失败: $e');
      }
    }

    final roomId = _xhsRoomId(url);
    if (roomId == null) {
      return FlvExtractResult.fail(
        '无法识别小红书直播间，请粘贴 https://www.xiaohongshu.com/livestream/房间号\n${notes.join('\n')}',
        platform: LivePlatform.xiaohongshu,
      );
    }

    final pageUrl = url.contains('xiaohongshu.com')
        ? url
        : 'https://www.xiaohongshu.com/livestream/$roomId';

    try {
      final res = await _dio.get(
        pageUrl,
        options: Options(
          headers: _xhsHeaders(),
          responseType: ResponseType.plain,
        ),
      );
      final html = res.data?.toString() ?? '';
      notes.add('page ${html.length}B');
      if (html.contains('直播已结束')) {
        return FlvExtractResult.fail(
          '小红书房间 $roomId 直播已结束\n${notes.join('\n')}',
          platform: LivePlatform.xiaohongshu,
          roomId: roomId,
        );
      }

      final state = _xhsInitialState(html);
      final live = state == null ? null : _asMap(state['liveStream']);
      if (live != null) {
        notes.add('liveStatus=${live['liveStatus']}');
        final status = '${live['liveStatus']}'.toLowerCase();
        if (status.isNotEmpty && status != 'success' && status != 'null') {
          return FlvExtractResult.fail(
            '小红书房间 $roomId 未开播（$status）\n${notes.join('\n')}',
            platform: LivePlatform.xiaohongshu,
            roomId: roomId,
          );
        }
        final roomData = _asMap(live['roomData']);
        final roomInfo = _asMap(roomData?['roomInfo']);
        final title = roomInfo?['roomTitle']?.toString();
        if (title != null && title.contains('回放')) {
          return FlvExtractResult.fail(
            '小红书房间 $roomId 是回放，不是直播\n${notes.join('\n')}',
            platform: LivePlatform.xiaohongshu,
            roomId: roomId,
          );
        }
        final flv = <String>[];
        final hls = <String>[];
        _xhsCollectPull(roomInfo?['pullConfig'], flv, hls, notes);
        final deep = roomInfo?['deeplink']?.toString();
        if (deep != null && deep.contains('flvUrl=')) {
          final decoded = Uri.decodeComponent(deep);
          final m = RegExp(r'flvUrl=([^&]+)').firstMatch(decoded);
          if (m != null) {
            final u = _cleanUrl(Uri.decodeComponent(m.group(1)!));
            if (u.contains('.flv')) flv.add(u);
          }
        }
        _xhsAddFallbacks(roomId, flv, hls);
        final flvU = _rankFlv(_uniq(flv));
        final hlsU = _uniq(hls);
        if (flvU.isNotEmpty || hlsU.isNotEmpty) {
          notes.add('flv x${flvU.length}, hls x${hlsU.length}');
          return FlvExtractResult.ok(
            platform: LivePlatform.xiaohongshu,
            roomId: roomId,
            flvUrls: flvU,
            hlsUrls: hlsU,
            allUrls: [...flvU, ...hlsU],
            note: notes.join('；'),
          );
        }
      } else {
        notes.add('无 INITIAL_STATE.liveStream');
      }
    } catch (e) {
      notes.add('页面解析失败: $e');
    }

    final flv = <String>[];
    final hls = <String>[];
    _xhsAddFallbacks(roomId, flv, hls);
    final flvU = _rankFlv(_uniq(flv));
    final hlsU = _uniq(hls);
    if (flvU.isEmpty && hlsU.isEmpty) {
      return FlvExtractResult.fail(
        '小红书房间 $roomId 未解析到地址\n${notes.join('\n')}',
        platform: LivePlatform.xiaohongshu,
        roomId: roomId,
      );
    }
    notes.add('使用 CDN 直链兜底');
    return FlvExtractResult.ok(
      platform: LivePlatform.xiaohongshu,
      roomId: roomId,
      flvUrls: flvU,
      hlsUrls: hlsU,
      allUrls: [...flvU, ...hlsU],
      note: notes.join('；'),
    );
  }

  Map<String, String> _xhsHeaders() => {
        'User-Agent':
            'ios/7.830 (ios 17.0; ; iPhone 15 (A2846/A3089/A3090/A3092))',
        'xy-common-params': 'platform=iOS&sid=session.1722166379345546829388',
        'Referer': 'https://app.xhs.cn/',
        'Accept': 'text/html,application/json,*/*',
        'Accept-Language': 'zh-CN,zh;q=0.9',
      };

  String? _xhsRoomId(String input) {
    final text = input.trim();
    final live = RegExp(
      r'(?:hina/)?livestream/(\d+)',
      caseSensitive: false,
    ).firstMatch(text);
    if (live != null) return live.group(1);
    final uri = Uri.tryParse(text);
    if (uri != null) {
      for (final seg in uri.pathSegments.reversed) {
        if (RegExp(r'^\d{10,}$').hasMatch(seg)) return seg;
      }
    }
    if (RegExp(r'^\d{10,}$').hasMatch(text)) return text;
    return null;
  }

  Map<String, dynamic>? _xhsInitialState(String html) {
    final m = RegExp(
      r'window\.__INITIAL_STATE__\s*=\s*(\{.*\})\s*</script>',
      dotAll: true,
    ).firstMatch(html);
    if (m == null) return null;
    var raw = m.group(1)!.replaceAll('undefined', 'null');
    try {
      final j = jsonDecode(raw);
      if (j is Map) return Map<String, dynamic>.from(j);
    } catch (_) {
      // 提取的 JSON 片段不完整时返回 null，走其它解析路径
    }
    return null;
  }

  void _xhsCollectPull(
    dynamic pullConfig,
    List<String> flv,
    List<String> hls,
    List<String> notes,
  ) {
    dynamic cfg = pullConfig;
    if (cfg is String && cfg.trim().isNotEmpty) {
      try {
        cfg = jsonDecode(cfg);
      } catch (_) {
        // 配置串非 JSON 时直接放弃该候选（无地址可用），安全返回
        return;
      }
    }
    if (cfg is! Map) return;
    void take(dynamic list, {required bool hevc}) {
      if (list is! List) return;
      for (final item in list) {
        if (item is! Map) continue;
        final u = _cleanUrl('${item['master_url'] ?? item['url'] ?? ''}');
        if (u.isEmpty) continue;
        if (hevc) notes.add('跳过 HEVC $u');
        if (hevc) continue;
        if (u.contains('.m3u8')) {
          hls.add(u);
        } else {
          flv.add(u);
        }
      }
    }

    take(cfg['h264'], hevc: false);
    take(cfg['h265'], hevc: true);
  }

  void _xhsAddFallbacks(String roomId, List<String> flv, List<String> hls) {
    const hosts = [
      'https://live-source-play-hw.xhscdn.com/live',
      'http://live-source-play.xhscdn.com/live',
      'https://live-source-play-bak-hw.xhscdn.com/live',
      'http://live.xhscdn.com/live',
    ];
    for (final h in hosts) {
      flv.add('$h/$roomId.flv');
      hls.add('$h/$roomId.m3u8');
    }
  }
}
