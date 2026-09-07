import 'dart:math';

import 'package:dio/dio.dart';
import 'package:kmxzs/services/douyin_abogus.dart';

/// 抖音直播推荐流中的一个可公开访问房间。
class DouyinLiveCandidate {
  const DouyinLiveCandidate({
    required this.webRid,
    required this.roomId,
    required this.title,
    required this.anchor,
  });

  final String webRid;
  final String roomId;
  final String title;
  final String anchor;

  String get roomUrl => 'https://live.douyin.com/$webRid';
}

/// 从抖音网页版直播推荐流中随机发现一个当前可播放的房间。
class DouyinRandomLiveFinder {
  DouyinRandomLiveFinder({Dio? dio, Random? random})
      : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 15),
                receiveTimeout: const Duration(seconds: 20),
                followRedirects: true,
                maxRedirects: 5,
                validateStatus: (status) => status != null && status < 500,
              ),
            ),
        _random = random ?? Random();

  static const _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/116.0.0.0 Safari/537.36';

  final Dio _dio;
  final Random _random;

  Future<DouyinLiveCandidate> discover({
    Set<String> excludedWebRids = const {},
  }) async {
    final candidates = await discoverCandidates(
      excludedWebRids: excludedWebRids,
    );
    return candidates.first;
  }

  Future<List<DouyinLiveCandidate>> discoverCandidates({
    Set<String> excludedWebRids = const {},
  }) async {
    final cookie = await _fetchCookie();
    final params = <String, String>{
      'aid': '6383',
      'app_name': 'douyin_web',
      'live_id': '1',
      'device_platform': 'web',
      'language': 'zh-CN',
      'browser_language': 'zh-CN',
      'browser_platform': 'Win32',
      'browser_name': 'Chrome',
      'browser_version': '116.0.0.0',
      'request_tag_from': 'web',
      'need_map': '1',
      'is_draw': '1',
      'inner_from_drawer': '0',
      'custom_count': '50',
      'action': 'load_more',
      'action_type': 'loadmore',
      'enter_source': 'web_homepage_hot_web_live_cell',
      'source_key': 'web_homepage_hot_web_live_cell',
      'max_time': DateTime.now().millisecondsSinceEpoch.toString(),
      'msToken': '',
    };
    final query = Uri(queryParameters: params).query;
    final signature = DouyinABogus().sign(query, userAgent: _ua);
    final response = await _dio.get<dynamic>(
      'https://live.douyin.com/webcast/feed/?$query&a_bogus=$signature',
      options: Options(
        headers: {
          'User-Agent': _ua,
          'Referer': 'https://live.douyin.com/',
          if (cookie.isNotEmpty) 'Cookie': cookie,
        },
      ),
    );
    if (response.statusCode != 200) {
      throw StateError('抖音直播推荐请求失败（HTTP ${response.statusCode}）');
    }

    final candidates = parseCandidates(response.data);
    if (candidates.isEmpty) {
      throw StateError('抖音直播推荐暂时没有返回可播放房间');
    }
    final fresh = candidates
        .where((candidate) => !excludedWebRids.contains(candidate.webRid))
        .toList();
    final pool = fresh.isEmpty ? candidates : fresh;
    pool.shuffle(_random);
    return pool;
  }

  static List<DouyinLiveCandidate> parseCandidates(dynamic root) {
    if (root is! Map || root['status_code'] != 0) return const [];
    final items = root['data'];
    if (items is! List) return const [];

    final result = <DouyinLiveCandidate>[];
    final seen = <String>{};
    for (final raw in items) {
      if (raw is! Map) continue;
      final room = raw['data'];
      if (room is! Map || room['is_replay'] == true) continue;
      final stream = room['stream_url'];
      if (stream is! Map || !_hasPlayableStream(stream)) continue;

      final owner = room['owner'];
      final ownerMap = owner is Map ? owner : const <String, dynamic>{};
      final webRid = _firstNonEmpty([
        raw['web_rid'],
        ownerMap['web_rid'],
      ]);
      if (webRid.isEmpty ||
          !RegExp(r'^\d+$').hasMatch(webRid) ||
          !seen.add(webRid)) {
        continue;
      }
      result.add(
        DouyinLiveCandidate(
          webRid: webRid,
          roomId: _firstNonEmpty([room['id_str'], room['id']]),
          title: _firstNonEmpty([room['title']]),
          anchor: _firstNonEmpty([ownerMap['nickname']]),
        ),
      );
    }
    return result;
  }

  static bool _hasPlayableStream(Map stream) {
    final flv = stream['flv_pull_url'];
    if (flv is Map && flv.values.any((value) => '$value'.contains('.flv'))) {
      return true;
    }
    final hls = stream['hls_pull_url_map'];
    return hls is Map && hls.values.any((value) => '$value'.contains('.m3u8'));
  }

  static String _firstNonEmpty(Iterable<dynamic> values) {
    for (final value in values) {
      final text = value?.toString().trim() ?? '';
      if (text.isNotEmpty && text != '0') return text;
    }
    return '';
  }

  Future<String> _fetchCookie() async {
    final response = await _dio.get<dynamic>(
      'https://live.douyin.com/',
      options: Options(headers: const {'User-Agent': _ua}),
    );
    final cookies = response.headers['set-cookie'] ?? const [];
    return cookies
        .map((value) => value.split(';').first.trim())
        .where(
          (value) =>
              value.startsWith('ttwid=') ||
              value.startsWith('__ac_nonce=') ||
              value.startsWith('__ac_signature='),
        )
        .join('; ');
  }
}
