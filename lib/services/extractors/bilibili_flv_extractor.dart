part of '../flv_extractor.dart';

class BilibiliFlvExtractor extends PlatformExtractor {
  BilibiliFlvExtractor(super.dio);

  @override
  LivePlatform get platform => LivePlatform.bilibili;

  String _biliRoomId(String input) {
    final text = input.trim();
    final live = RegExp(r'live\.bilibili\.com/(\d+)').firstMatch(text);
    if (live != null) return live.group(1)!;
    if (RegExp(r'^\d+$').hasMatch(text)) return text;
    final uri = Uri.tryParse(text);
    if (uri != null) {
      for (final seg in uri.pathSegments.reversed) {
        if (RegExp(r'^\d+$').hasMatch(seg)) return seg;
      }
    }
    return text.split(RegExp(r'[/?#]')).lastWhere(
          (e) => e.isNotEmpty,
          orElse: () => text,
        );
  }

  @override
  Future<FlvExtractResult> extract(String input) async {
    var roomId = _biliRoomId(input);
    final notes = <String>[];
    final flv = <String>[];
    final hls = <String>[];

    // 短链跳转
    if (input.contains('b23.tv') || input.contains('bili.tv')) {
      try {
        final res = await _dio.get(
          input.startsWith('http') ? input : 'https://$input',
          options: Options(
            followRedirects: true,
            validateStatus: (_) => true,
            headers: {'User-Agent': _ua},
          ),
        );
        final real = res.realUri.toString();
        final m = RegExp(r'live\.bilibili\.com/(\d+)').firstMatch(real);
        if (m != null) {
          roomId = m.group(1)!;
          notes.add('短链解析 → $roomId');
        }
      } catch (e) {
        notes.add('短链解析失败: $e');
      }
    }

    // 短号 → 真实 room_id
    try {
      final init = await _dio.get(
        'https://api.live.bilibili.com/room/v1/Room/room_init',
        queryParameters: {'id': roomId},
        options: Options(headers: {
          'User-Agent': _ua,
          'Referer': 'https://live.bilibili.com/',
        }),
      );
      final root = _asMap(init.data);
      final data = root?['data'];
      if (data is Map) {
        final real = data['room_id']?.toString();
        if (real != null && real.isNotEmpty) {
          if (real != roomId) notes.add('短号 $roomId → 真实 $real');
          roomId = real;
        }
        final liveStatus = data['live_status'];
        notes.add('live_status=$liveStatus');
        if (liveStatus == 0) {
          return FlvExtractResult.fail(
            'B站房间 $roomId 未开播\n${notes.join('\n')}',
            platform: LivePlatform.bilibili,
            roomId: roomId,
          );
        }
      }
    } catch (e) {
      notes.add('room_init 失败: $e');
    }

    try {
      final res = await _dio.get(
        'https://api.live.bilibili.com/xlive/web-room/v2/index/getRoomPlayInfo',
        queryParameters: {
          'room_id': roomId,
          'protocol': '0,1',
          'format': '0,1,2',
          'codec': '0,1',
          'qn': '10000',
          'platform': 'web',
          'ptype': '8',
        },
        options: Options(headers: {
          'User-Agent': _ua,
          'Referer': 'https://live.bilibili.com/$roomId',
          'Origin': 'https://live.bilibili.com',
        }),
      );
      final root = _asMap(res.data);
      if (root == null) {
        return FlvExtractResult.fail(
          'B站返回无法解析\n${notes.join('\n')}',
          platform: LivePlatform.bilibili,
          roomId: roomId,
        );
      }
      if (root['code'] != 0) {
        return FlvExtractResult.fail(
          'B站接口错误: ${root['message'] ?? root['code']}\n${notes.join('\n')}',
          platform: LivePlatform.bilibili,
          roomId: roomId,
        );
      }
      final data = root['data'];
      if (data is! Map) {
        return FlvExtractResult.fail('B站无 data',
            platform: LivePlatform.bilibili, roomId: roomId);
      }
      final liveStatus = data['live_status'];
      notes.add('playinfo live_status=$liveStatus');
      final playurlInfo = data['playurl_info'];
      final playurl = playurlInfo is Map ? playurlInfo['playurl'] : null;
      final streams = playurl is Map ? playurl['stream'] : null;
      if (streams is! List || streams.isEmpty) {
        return FlvExtractResult.fail(
          'B站房间 $roomId 无播放地址（未开播或加密场）\n${notes.join('\n')}',
          platform: LivePlatform.bilibili,
          roomId: roomId,
        );
      }
      for (final s in streams) {
        if (s is! Map) continue;
        final formats = s['format'];
        if (formats is! List) continue;
        for (final f in formats) {
          if (f is! Map) continue;
          final formatName = '${f['format_name']}'.toLowerCase();
          final codecs = f['codec'];
          if (codecs is! List) continue;
          for (final c in codecs) {
            if (c is! Map) continue;
            final base = c['base_url']?.toString() ?? '';
            final infos = c['url_info'];
            if (infos is! List || infos.isEmpty || base.isEmpty) continue;
            for (final info in infos) {
              if (info is! Map) continue;
              final host = info['host']?.toString() ?? '';
              final extra = info['extra']?.toString() ?? '';
              final url = _cleanUrl('$host$base$extra');
              if (url.isEmpty) continue;
              if (formatName == 'flv' || url.contains('.flv')) {
                flv.add(url);
              } else if (formatName.contains('ts') ||
                  formatName.contains('fmp4') ||
                  url.contains('m3u8')) {
                hls.add(url);
              } else {
                if (url.contains('.flv')) {
                  flv.add(url);
                } else {
                  hls.add(url);
                }
              }
            }
          }
        }
      }
      notes.add('flv x${flv.length}, hls x${hls.length}');
    } catch (e) {
      return FlvExtractResult.fail(
        'B站拉流失败: $e\n${notes.join('\n')}',
        platform: LivePlatform.bilibili,
        roomId: roomId,
      );
    }

    final flvU = _rankFlv(_uniq(flv));
    final hlsU = _uniq(hls);
    if (flvU.isEmpty && hlsU.isEmpty) {
      return FlvExtractResult.fail(
        'B站房间 $roomId 未解析到地址\n${notes.join('\n')}',
        platform: LivePlatform.bilibili,
        roomId: roomId,
      );
    }
    return FlvExtractResult.ok(
      platform: LivePlatform.bilibili,
      roomId: roomId,
      flvUrls: flvU,
      hlsUrls: hlsU,
      allUrls: [...flvU, ...hlsU],
      note: notes.join('；'),
    );
  }
}
