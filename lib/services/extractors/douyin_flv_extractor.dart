part of '../flv_extractor.dart';

class DouyinFlvExtractor extends PlatformExtractor {
  DouyinFlvExtractor(super.dio);

  @override
  LivePlatform get platform => LivePlatform.douyin;

  /// 解析抖音直播间标识。优先 web_rid；其次 modal_id / room_id。
  /// [kind]: `web_rid` | `room_id` | `aweme_id` | `unknown`
  ({String id, String kind}) _dyParseId(String input) {
    final text = input.trim();
    final live = RegExp(r'live\.douyin\.com/(\d+)').firstMatch(text);
    if (live != null) {
      return (id: live.group(1)!, kind: 'web_rid');
    }
    final uri = Uri.tryParse(text);
    if (uri != null && uri.hasQuery) {
      final webRid = uri.queryParameters['web_rid'];
      if (webRid != null && RegExp(r'^\d+$').hasMatch(webRid)) {
        return (id: webRid, kind: 'web_rid');
      }
      final roomId =
          uri.queryParameters['room_id'] ?? uri.queryParameters['roomId'];
      if (roomId != null && RegExp(r'^\d+$').hasMatch(roomId)) {
        return (id: roomId, kind: 'room_id');
      }
      final modalId = uri.queryParameters['modal_id'];
      if (modalId != null && RegExp(r'^\d+$').hasMatch(modalId)) {
        // www.douyin.com 的 modal_id 常见是短视频 aweme_id，也可能是房间号
        return (id: modalId, kind: 'modal_id');
      }
    }
    final modal = RegExp(r'[?&]modal_id=(\d+)').firstMatch(text);
    if (modal != null) return (id: modal.group(1)!, kind: 'modal_id');
    final room = RegExp(r'[?&]room_id=(\d+)').firstMatch(text);
    if (room != null) return (id: room.group(1)!, kind: 'room_id');
    if (RegExp(r'^\d+$').hasMatch(text)) {
      // 短号更像 web_rid，超长雪花更像 room_id / aweme_id
      return (
        id: text,
        kind: text.length >= 16 ? 'room_id' : 'web_rid',
      );
    }
    final last = text.split(RegExp(r'[/?#]')).lastWhere(
          (e) => e.isNotEmpty,
          orElse: () => text,
        );
    final onlyDigits = RegExp(r'^(\d+)').firstMatch(last);
    if (onlyDigits != null) {
      final id = onlyDigits.group(1)!;
      return (id: id, kind: id.length >= 16 ? 'room_id' : 'web_rid');
    }
    return (id: last, kind: 'unknown');
  }

  @override
  Future<FlvExtractResult> extract(String input) async {
    final parsed = _dyParseId(input);
    var rid = parsed.id;
    var kind = parsed.kind;
    final notes = <String>[];
    final flv = <String>[];
    final hls = <String>[];
    notes.add('识别: $kind=$rid');

    // 1) 拿 ttwid（enter 接口必需）
    String cookie = '';
    try {
      cookie = await _fetchDouyinCookie();
      notes.add('已获取 ttwid');
    } catch (e) {
      notes.add('获取 cookie 失败: $e');
    }

    // modal_id：先判定是不是短视频（常见误贴）
    if (kind == 'modal_id' || kind == 'room_id') {
      final aweme = await _probeDouyinAweme(rid, cookie, notes);
      if (aweme != null && aweme.isVideo) {
        // 作者若在播，尝试切到其直播间
        if (aweme.liveWebRid != null && aweme.liveWebRid!.isNotEmpty) {
          notes.add('modal_id 为视频，作者在播 → web_rid=${aweme.liveWebRid}');
          rid = aweme.liveWebRid!;
          kind = 'web_rid';
        } else {
          return FlvExtractResult.fail(
            '这是抖音短视频链接（modal_id=$rid），不是直播间。\n'
            '请粘贴直播地址，例如：https://live.douyin.com/房间号\n'
            '${aweme.author != null ? "作者: ${aweme.author}（当前未开播）\n" : ""}'
            '${notes.join('\n')}',
            platform: LivePlatform.douyin,
            roomId: rid,
          );
        }
      }
    }

    // 2) webcast/room/web/enter（带 a_bogus，否则常见 status_code=10011）
    if (kind == 'web_rid' || kind == 'modal_id' || kind == 'unknown') {
      await _douyinWebEnter(rid, cookie, flv, hls, notes);
    }

    // 3) room_id 走 reflow（长号房间 ID）
    if (flv.isEmpty &&
        hls.isEmpty &&
        (kind == 'room_id' || kind == 'modal_id')) {
      await _douyinReflow(rid, cookie, flv, hls, notes);
    }

    // 4) 页面兜底
    if (flv.isEmpty && hls.isEmpty) {
      try {
        final res = await _dio.get(
          'https://live.douyin.com/$rid',
          options: Options(headers: {
            'User-Agent': _ua,
            'Referer': 'https://live.douyin.com/',
            if (cookie.isNotEmpty) 'Cookie': cookie,
          }),
        );
        final body = res.data?.toString() ?? '';
        _parseDouyinHtml(body, flv, hls);
        if (flv.isNotEmpty || hls.isNotEmpty) notes.add('来源: 直播页 HTML');
      } catch (e) {
        notes.add('页面兜底失败: $e');
      }
    }

    final flvU = _rankFlv(_uniq(flv));
    final hlsU = _uniq(hls);
    if (flvU.isEmpty && hlsU.isEmpty) {
      return FlvExtractResult.fail(
        '抖音房间 $rid 未解析到可播地址（未开播 / 风控 / 需更新解析）\n'
        '提示: 请使用 https://live.douyin.com/房间号\n'
        '${notes.join('\n')}',
        platform: LivePlatform.douyin,
        roomId: rid,
      );
    }
    return FlvExtractResult.ok(
      platform: LivePlatform.douyin,
      roomId: rid,
      flvUrls: flvU,
      hlsUrls: hlsU,
      allUrls: [...flvU, ...hlsU],
      note: notes.join('；'),
    );
  }

  Future<void> _douyinWebEnter(
    String rid,
    String cookie,
    List<String> flv,
    List<String> hls,
    List<String> notes,
  ) async {
    try {
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
        'web_rid': rid,
        'msToken': '',
      };
      final qs = Uri(queryParameters: params).query;
      final ab = DouyinABogus().sign(qs, userAgent: _ua);
      // a_bogus 不要再做 URI 二次编码（与 DouyinLiveRecorder 一致）
      final res = await _dio.get<dynamic>(
        'https://live.douyin.com/webcast/room/web/enter/?$qs&a_bogus=$ab',
        options: Options(headers: {
          'User-Agent': _ua,
          'Referer': 'https://live.douyin.com/$rid',
          if (cookie.isNotEmpty) 'Cookie': cookie,
        }),
      );
      final root = _asMap(res.data);
      if (root != null) {
        _parseDouyinEnter(root, flv, hls, notes);
      }
    } catch (e) {
      notes.add('enter 接口失败: $e');
    }
  }

  Future<void> _douyinReflow(
    String roomId,
    String cookie,
    List<String> flv,
    List<String> hls,
    List<String> notes,
  ) async {
    try {
      final params = <String, String>{
        'verifyFp': 'verify_hwj52020_7szNlAB7_pxNY_48Vh_ALKF_GA1Uf3yteoOY',
        'type_id': '0',
        'live_id': '1',
        'room_id': roomId,
        'sec_user_id': '',
        'version_code': '99.99.99',
        'app_id': '1128',
      };
      final qs = Uri(queryParameters: params).query;
      final ab = DouyinABogus().sign(qs, userAgent: _ua);
      final res = await _dio.get<dynamic>(
        'https://webcast.amemv.com/webcast/room/reflow/info/?$qs&a_bogus=$ab',
        options: Options(headers: {
          'User-Agent': _ua,
          'Referer': 'https://live.douyin.com/',
          if (cookie.isNotEmpty) 'Cookie': cookie,
        }),
      );
      final root = _asMap(res.data);
      if (root == null) return;
      final code = root['status_code'];
      if (code != null && code != 0) {
        notes.add('reflow status_code=$code');
        return;
      }
      final data = root['data'];
      if (data is! Map) return;
      final room = data['room'];
      if (room is! Map) {
        notes.add('reflow 无 room');
        return;
      }
      notes.add('reflow room_status=${room['status']}');
      final streamUrl = room['stream_url'];
      if (streamUrl is Map) {
        final flvMap = streamUrl['flv_pull_url'];
        if (flvMap is Map) {
          for (final e in flvMap.entries) {
            final v = e.value?.toString() ?? '';
            if (_looksPlayableFlv(v)) flv.add(_cleanUrl(v));
          }
        }
        final hlsMap = streamUrl['hls_pull_url_map'];
        if (hlsMap is Map) {
          for (final e in hlsMap.entries) {
            final v = e.value?.toString() ?? '';
            if (v.contains('m3u8')) hls.add(_cleanUrl(v));
          }
        }
        try {
          final sdk = streamUrl['live_core_sdk_data'];
          final pull = sdk is Map ? sdk['pull_data'] : null;
          final streamData = pull is Map ? pull['stream_data'] : null;
          if (streamData is String && streamData.isNotEmpty) {
            _collectStreamDataUrls(jsonDecode(streamData), flv, hls);
          }
        } catch (_) {
          // 单个回包里的 stream_data 解析失败跳过该包，继续其它候选
        }
      }
    } catch (e) {
      notes.add('reflow 失败: $e');
    }
  }

  Future<_DyAwemeProbe?> _probeDouyinAweme(
    String awemeId,
    String cookie,
    List<String> notes,
  ) async {
    try {
      final params = <String, String>{
        'device_platform': 'webapp',
        'aid': '6383',
        'channel': 'channel_pc_web',
        'aweme_id': awemeId,
        'pc_client_type': '1',
        'version_code': '190500',
        'version_name': '19.5.0',
        'cookie_enabled': 'true',
        'screen_width': '1920',
        'screen_height': '1080',
        'browser_language': 'zh-CN',
        'browser_platform': 'Win32',
        'browser_name': 'Chrome',
        'browser_version': '116.0.0.0',
        'browser_online': 'true',
        'engine_name': 'Blink',
        'engine_version': '116.0.0.0',
        'os_name': 'Windows',
        'os_version': '10',
        'cpu_core_num': '8',
        'device_memory': '8',
        'platform': 'PC',
        'downlink': '10',
        'effective_type': '4g',
        'round_trip_time': '50',
      };
      final qs = Uri(queryParameters: params).query;
      final ab = DouyinABogus().sign(qs, userAgent: _ua);
      final res = await _dio.get<dynamic>(
        'https://www.douyin.com/aweme/v1/web/aweme/detail/?$qs&a_bogus=$ab',
        options: Options(headers: {
          'User-Agent': _ua,
          'Referer': 'https://www.douyin.com/',
          if (cookie.isNotEmpty) 'Cookie': cookie,
        }),
      );
      final root = _asMap(res.data);
      final detail = root?['aweme_detail'];
      if (detail is! Map) return null;
      final author = detail['author'];
      String? authorName;
      String? liveWebRid;
      if (author is Map) {
        authorName = author['nickname']?.toString();
        final liveStatus = author['live_status'];
        final roomId =
            author['room_id']?.toString() ?? author['room_id_str']?.toString();
        if (liveStatus == 1 && roomId != null && roomId != '0') {
          // 有些字段是 web_rid，有些是 room_id；短号优先当 web_rid
          if (roomId.length < 16) liveWebRid = roomId;
        }
      }
      final awemeType = detail['aweme_type'];
      final hasVideo = detail['video'] is Map;
      final isVideo =
          hasVideo && (awemeType == 0 || awemeType == 4 || awemeType == null);
      if (isVideo) {
        notes.add('modal_id 对应短视频${authorName == null ? "" : " @$authorName"}');
      }
      return _DyAwemeProbe(
        isVideo: isVideo,
        author: authorName,
        liveWebRid: liveWebRid,
      );
    } catch (e) {
      notes.add('aweme 探测失败: $e');
      return null;
    }
  }

  void _parseDouyinEnter(
    Map<String, dynamic> root,
    List<String> flv,
    List<String> hls,
    List<String> notes,
  ) {
    final code = root['status_code'];
    if (code != null && code != 0) {
      notes.add('status_code=$code');
      if (code == 10011) {
        notes.add('参数/签名错误（a_bogus）');
      } else if (code == 4001038) {
        notes.add('房间不可见或 ID 不是 web_rid（请用 live.douyin.com/房间号）');
      }
      final data = root['data'];
      if (data is Map && data['prompts'] != null) {
        notes.add('prompts=${data['prompts']}');
      }
      return;
    }
    final data = root['data'];
    if (data is! Map) return;
    final rooms = data['data'];
    if (rooms is! List || rooms.isEmpty) {
      notes.add('房间数据为空（可能未开播）');
      return;
    }
    final room = rooms.first;
    if (room is! Map) return;
    final status = room['status'];
    notes.add('room_status=$status');
    final streamUrl = room['stream_url'];
    if (streamUrl is! Map) {
      notes.add('无 stream_url');
      return;
    }

    final flvMap = streamUrl['flv_pull_url'];
    if (flvMap is Map) {
      for (final e in flvMap.entries) {
        final v = e.value?.toString() ?? '';
        if (_looksPlayableFlv(v)) flv.add(_cleanUrl(v));
      }
      notes.add('flv_pull_url x${flvMap.length}');
    }
    final hlsMap = streamUrl['hls_pull_url_map'];
    if (hlsMap is Map) {
      for (final e in hlsMap.entries) {
        final v = e.value?.toString() ?? '';
        if (v.contains('m3u8')) hls.add(_cleanUrl(v));
      }
    }

    // 原画在 live_core_sdk_data.pull_data.stream_data
    try {
      final sdk = streamUrl['live_core_sdk_data'];
      final pull = sdk is Map ? sdk['pull_data'] : null;
      var streamData = pull is Map ? pull['stream_data'] : null;
      final pullDatas = streamUrl['pull_datas'];
      if (pullDatas is Map && pullDatas.isNotEmpty) {
        final first = pullDatas.values.first;
        if (first is Map && first['stream_data'] != null) {
          streamData = first['stream_data'];
        }
      }
      if (streamData is String && streamData.isNotEmpty) {
        final sd = jsonDecode(streamData);
        _collectStreamDataUrls(sd, flv, hls);
        notes.add('已解析 stream_data 原画');
      }
    } catch (e) {
      notes.add('stream_data 解析失败: $e');
    }
  }

  void _collectStreamDataUrls(
      dynamic node, List<String> flv, List<String> hls) {
    if (node is Map) {
      for (final e in node.entries) {
        final k = e.key.toString().toLowerCase();
        final v = e.value;
        if (v is String) {
          final u = _cleanUrl(v);
          if (k.contains('flv') && _looksPlayableFlv(u)) flv.add(u);
          if ((k.contains('hls') || k.contains('m3u8')) && u.contains('m3u8')) {
            hls.add(u);
          }
        } else {
          _collectStreamDataUrls(v, flv, hls);
        }
      }
    } else if (node is List) {
      for (final x in node) {
        _collectStreamDataUrls(x, flv, hls);
      }
    }
  }

  void _parseDouyinHtml(String body, List<String> flv, List<String> hls) {
    // 反斜杠转义的 JSON URL
    for (final m in RegExp(
      r'https:\\u002F\\u002F[^"\\]+?\.flv[^"\\]*',
    ).allMatches(body)) {
      flv.add(_cleanUrl(m.group(0)!));
    }
    for (final m
        in RegExp(r'https:\\/\\/[^"\\]+?\.flv[^"\\]*').allMatches(body)) {
      flv.add(_cleanUrl(m.group(0)!));
    }
    for (final m
        in RegExp(r'https?://[^"\s<>]+?\.flv[^"\s<>]*').allMatches(body)) {
      final u = _cleanUrl(m.group(0)!);
      if (_looksPlayableFlv(u)) flv.add(u);
    }
    for (final m
        in RegExp(r'https?://[^"\s<>]+?\.m3u8[^"\s<>]*').allMatches(body)) {
      hls.add(_cleanUrl(m.group(0)!));
    }

    // flv_pull_url JSON 块
    final block = RegExp(
      r'"flv_pull_url"\s*:\s*(\{[^}]+\})',
    ).firstMatch(body);
    if (block != null) {
      try {
        final map = jsonDecode(block.group(1)!.replaceAll(r'\/', '/'));
        if (map is Map) {
          for (final v in map.values) {
            final u = _cleanUrl('$v');
            if (_looksPlayableFlv(u)) flv.add(u);
          }
        }
      } catch (_) {
        // 个别字段结构异常跳过，不影响已收集到的地址
      }
    }
  }

  Future<String> _fetchDouyinCookie() async {
    final res = await _dio.get(
      'https://live.douyin.com/',
      options: Options(
        headers: {'User-Agent': _ua},
        followRedirects: true,
        validateStatus: (_) => true,
      ),
    );
    final setCookies = <String>[];
    res.headers.forEach((name, values) {
      if (name.toLowerCase() == 'set-cookie') {
        setCookies.addAll(values);
      }
    });
    final parts = <String>[];
    for (final c in setCookies) {
      final first = c.split(';').first.trim();
      if (first.startsWith('ttwid=') ||
          first.startsWith('__ac_nonce=') ||
          first.startsWith('__ac_signature=')) {
        parts.add(first);
      }
    }
    // 至少要有 ttwid；没有则用常见兜底（部分环境仍可用）
    if (!parts.any((e) => e.startsWith('ttwid='))) {
      parts.add(
        'ttwid=1%7Ckmxzs%7C${DateTime.now().millisecondsSinceEpoch ~/ 1000}%7Cplaceholder',
      );
    }
    return parts.join('; ');
  }
}
