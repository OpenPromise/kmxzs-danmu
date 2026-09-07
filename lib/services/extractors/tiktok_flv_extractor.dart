part of '../flv_extractor.dart';

class TiktokFlvExtractor extends PlatformExtractor {
  TiktokFlvExtractor(super.dio, {String? cookie}) : super(tiktokCookie: cookie);

  @override
  LivePlatform get platform => LivePlatform.tiktok;

  /// TikTok 直播：@user/live → room_id → webcast/room/info 提流。
  ({String? uniqueId, String? roomId}) _ttParseId(String input) {
    final text = input.trim();
    final share = RegExp(r'm\.tiktok\.com/share/live/(\d+)').firstMatch(text);
    if (share != null) {
      return (uniqueId: null, roomId: share.group(1));
    }
    final live = RegExp(
      r'tiktok\.com/@([\w.\-]+)/live',
      caseSensitive: false,
    ).firstMatch(text);
    if (live != null) {
      return (uniqueId: live.group(1), roomId: null);
    }
    final user = RegExp(
      r'tiktok\.com/@([\w.\-]+)',
      caseSensitive: false,
    ).firstMatch(text);
    if (user != null) {
      return (uniqueId: user.group(1), roomId: null);
    }
    if (text.startsWith('@')) {
      final id = text.substring(1).split(RegExp(r'[/?#\s]')).first;
      if (id.isNotEmpty) return (uniqueId: id, roomId: null);
    }
    if (RegExp(r'^\d{15,}$').hasMatch(text)) {
      return (uniqueId: null, roomId: text);
    }
    if (RegExp(r'^[\w.\-]{2,64}$').hasMatch(text) && !text.contains('.')) {
      return (uniqueId: text, roomId: null);
    }
    return (uniqueId: null, roomId: null);
  }

  Map<String, String> _ttHeaders({String? referer}) {
    final h = <String, String>{
      'User-Agent': _ua,
      'Accept': 'text/html,application/json,*/*',
      'Accept-Language': 'en-US,en;q=0.9,zh-CN;q=0.8',
      'Referer': referer ?? 'https://www.tiktok.com/',
    };
    final c = tiktokCookie?.trim();
    if (c != null && c.isNotEmpty) h['Cookie'] = c;
    return h;
  }

  Future<String?> _ttFollowShortLink(String input, List<String> notes) async {
    if (!RegExp(r'(vt|vm)\.tiktok\.com', caseSensitive: false)
        .hasMatch(input)) {
      return null;
    }
    try {
      final res = await _dio.get(
        input.startsWith('http') ? input : 'https://$input',
        options: Options(
          headers: _ttHeaders(),
          followRedirects: true,
          maxRedirects: 8,
          validateStatus: (s) => s != null && s < 400,
        ),
      );
      final finalUrl = res.realUri.toString();
      notes.add('短链跳转 → $finalUrl');
      return finalUrl;
    } catch (e) {
      notes.add('短链解析失败: $e');
      return null;
    }
  }

  Future<String?> _ttResolveRoomId(
    String uniqueId,
    List<String> notes,
  ) async {
    final urls = [
      'https://www.tiktok.com/@$uniqueId/live',
      'https://www.tiktok.com/@$uniqueId',
    ];
    for (final url in urls) {
      try {
        final res = await _dio.get(
          url,
          options: Options(headers: _ttHeaders(referer: url)),
        );
        final body = res.data?.toString() ?? '';
        final roomId = _ttRoomIdFromHtml(body);
        if (roomId != null) {
          notes.add('页面解析 room_id=$roomId（$url）');
          return roomId;
        }
        notes.add('页面无 roomId: $url');
      } catch (e) {
        notes.add('打开 $url 失败: $e');
      }
    }
    return null;
  }

  String? _ttRoomIdFromHtml(String body) {
    for (final marker in [
      '__UNIVERSAL_DATA_FOR_REHYDRATION__',
      'SIGI_STATE',
      'sigi-persisted-data',
    ]) {
      final idx = body.indexOf(marker);
      if (idx < 0) continue;
      final start = body.indexOf('{', idx);
      if (start < 0) continue;
      final jsonStr = _ttSliceJsonObject(body, start);
      if (jsonStr == null) continue;
      try {
        final j = jsonDecode(jsonStr);
        final id = _ttFindRoomId(j);
        if (id != null) return id;
      } catch (_) {
        // 该候选 JSON 解析失败继续试下一个，属正常探测
      }
    }
    for (final p in [
      RegExp(r'"roomId"\s*:\s*"(\d{10,})"'),
      RegExp(r'"room_id"\s*:\s*"(\d{10,})"'),
      RegExp(r'"roomId"\s*:\s*(\d{10,})'),
    ]) {
      final m = p.firstMatch(body);
      if (m != null) return m.group(1);
    }
    return null;
  }

  String? _ttFindRoomId(dynamic node, [int depth = 0]) {
    if (depth > 12 || node == null) return null;
    if (node is Map) {
      for (final key in ['roomId', 'room_id', 'roomID']) {
        final v = node[key];
        if (v != null) {
          final s = '$v'.trim();
          if (RegExp(r'^\d{10,}$').hasMatch(s) && s != '0') return s;
        }
      }
      // 优先走常见路径
      for (final path in [
        [
          '__DEFAULT_SCOPE__',
          'webapp.user-detail',
          'userInfo',
          'user',
          'roomId'
        ],
        ['LiveRoom', 'liveRoomUserInfo', 'user', 'roomId'],
      ]) {
        dynamic cur = node;
        var ok = true;
        for (final k in path) {
          if (cur is Map && cur.containsKey(k)) {
            cur = cur[k];
          } else {
            ok = false;
            break;
          }
        }
        if (ok && cur != null) {
          final s = '$cur'.trim();
          if (RegExp(r'^\d{10,}$').hasMatch(s) && s != '0') return s;
        }
      }
      for (final v in node.values) {
        final found = _ttFindRoomId(v, depth + 1);
        if (found != null) return found;
      }
    } else if (node is List) {
      for (final v in node) {
        final found = _ttFindRoomId(v, depth + 1);
        if (found != null) return found;
      }
    }
    return null;
  }

  @override
  Future<FlvExtractResult> extract(String input) async {
    final notes = <String>[];
    final flv = <String>[];
    final hls = <String>[];

    var working = input.trim();
    final redirected = await _ttFollowShortLink(working, notes);
    if (redirected != null) working = redirected;

    var parsed = _ttParseId(working);
    var uniqueId = parsed.uniqueId;
    var roomId = parsed.roomId;
    notes.add('识别: uniqueId=${uniqueId ?? "-"} roomId=${roomId ?? "-"}');

    if (roomId == null && uniqueId != null) {
      roomId = await _ttResolveRoomId(uniqueId, notes);
    }

    if (roomId == null || roomId.isEmpty) {
      // yt-dlp 兜底（可处理部分短链 / 签名页）
      final pageUrl = uniqueId != null
          ? 'https://www.tiktok.com/@$uniqueId/live'
          : (working.startsWith('http') ? working : null);
      if (pageUrl != null) {
        final fromDl = await _ytDlpGetUrls(pageUrl);
        if (fromDl.isNotEmpty) {
          notes.add('来源: yt-dlp（无 room_id 时）');
          for (final u in fromDl) {
            if (u.contains('.flv') ||
                u.contains('pull-flv') ||
                u.contains('flv')) {
              flv.add(u);
            } else {
              hls.add(u);
            }
          }
          final flvU = _rankFlv(_uniq(flv));
          final hlsU = _uniq(hls);
          return FlvExtractResult.ok(
            platform: LivePlatform.tiktok,
            roomId: uniqueId,
            flvUrls: flvU,
            hlsUrls: hlsU,
            allUrls: [...flvU, ...hlsU],
            note: notes.join('；'),
          );
        }
      }
      return FlvExtractResult.fail(
        'TikTok 未能解析房间号。请粘贴开播中的链接，例如：\n'
        'https://www.tiktok.com/@用户名/live',
        platform: LivePlatform.tiktok,
        roomId: uniqueId,
      );
    }

    // 1) webcast room/info（主路径，对齐 yt-dlp）
    try {
      await _ttWebcastRoomInfo(roomId, uniqueId, flv, hls, notes);
    } catch (e) {
      notes.add('webcast/room/info 失败: $e');
    }

    // 2) www.tiktok.com/api/live/detail 兜底 HLS
    if (flv.isEmpty && hls.isEmpty) {
      try {
        await _ttLiveDetail(roomId, flv, hls, notes);
      } catch (e) {
        notes.add('api/live/detail 失败: $e');
      }
    }

    // 3) yt-dlp
    if (flv.isEmpty && hls.isEmpty) {
      final pageUrl = uniqueId != null
          ? 'https://www.tiktok.com/@$uniqueId/live'
          : 'https://www.tiktok.com/@/live';
      final fromDl = await _ytDlpGetUrls(
        uniqueId != null ? pageUrl : working,
      );
      if (fromDl.isNotEmpty) {
        notes.add('来源: yt-dlp');
        for (final u in fromDl) {
          if (u.contains('.flv') ||
              u.contains('pull-flv') ||
              u.contains('/flv')) {
            flv.add(u);
          } else {
            hls.add(u);
          }
        }
      } else {
        notes.add('未找到 yt-dlp 或提取失败；可安装: pip install -U yt-dlp');
      }
    }

    final flvU = _rankFlv(_uniq(flv.where((u) {
      final s = u.toLowerCase();
      if (s.contains('only_audio=1')) return false;
      return _looksPlayableFlv(u) ||
          s.contains('.flv') ||
          s.contains('pull-flv') ||
          (s.contains('tiktokcdn') && s.contains('flv'));
    })));
    final hlsU = _uniq(hls.where((u) {
      final s = u.toLowerCase();
      return s.startsWith('http') &&
          !s.contains('only_audio=1') &&
          (s.contains('m3u8') || s.contains('pull-hls') || s.contains('hls'));
    }));

    if (flvU.isEmpty && hlsU.isEmpty) {
      return FlvExtractResult.fail(
        'TikTok 未解析到可播地址。请确认主播正在直播并关闭代理后重试。',
        platform: LivePlatform.tiktok,
        roomId: roomId,
      );
    }
    return FlvExtractResult.ok(
      platform: LivePlatform.tiktok,
      roomId: roomId,
      flvUrls: flvU,
      hlsUrls: hlsU,
      allUrls: [...flvU, ...hlsU],
      note: notes.join('；'),
    );
  }

  Future<void> _ttWebcastRoomInfo(
    String roomId,
    String? uniqueId,
    List<String> flv,
    List<String> hls,
    List<String> notes,
  ) async {
    final res = await _dio.get(
      'https://webcast.tiktok.com/webcast/room/info',
      queryParameters: {
        'aid': '1988',
        'room_id': roomId,
        'app_language': 'en',
        'webcast_language': 'en',
      },
      options: Options(
        headers: _ttHeaders(
          referer: uniqueId != null
              ? 'https://www.tiktok.com/@$uniqueId/live'
              : 'https://www.tiktok.com/',
        ),
        responseType: ResponseType.json,
      ),
    );
    final root = res.data;
    if (root is! Map) {
      notes.add('webcast 响应非 JSON');
      return;
    }
    final data = root['data'];
    if (data is! Map) {
      notes.add('webcast 无 data status_code=${root['status_code']}');
      return;
    }
    final status = data['status'];
    notes.add('room_status=$status');
    // status == 2 直播中；4 已结束
    if (status != null && status != 2) {
      notes.add(status == 4 ? '直播已结束' : '未在播 status=$status');
      // 仍尝试解析 URL（部分接口仍返回缓存地址）
    }
    final title = data['title']?.toString();
    if (title != null && title.isNotEmpty) notes.add('title=$title');

    final streamUrl = data['stream_url'];
    if (streamUrl is Map) {
      _ttCollectStreamUrlMap(streamUrl, flv, hls, notes);
    } else {
      notes.add('无 stream_url');
    }
  }

  void _ttCollectStreamUrlMap(
    Map streamUrl,
    List<String> flv,
    List<String> hls,
    List<String> notes,
  ) {
    void addFlv(String? u) {
      if (u == null || u.isEmpty) return;
      final c = _cleanUrl(u);
      if (c.startsWith('http')) flv.add(c);
    }

    void addHls(String? u) {
      if (u == null || u.isEmpty) return;
      final c = _cleanUrl(u);
      if (c.startsWith('http')) hls.add(c);
    }

    final flvMap = streamUrl['flv_pull_url'];
    if (flvMap is Map) {
      for (final e in flvMap.entries) {
        addFlv(e.value?.toString());
      }
      notes.add('flv_pull_url x${flvMap.length}');
    }
    addFlv(streamUrl['rtmp_pull_url']?.toString());
    addHls(streamUrl['hls_pull_url']?.toString());
    final hlsMap = streamUrl['hls_pull_url_map'];
    if (hlsMap is Map) {
      for (final e in hlsMap.entries) {
        addHls(e.value?.toString());
      }
    }

    // live_core_sdk_data.pull_data.stream_data 是 JSON 字符串
    final sdk = streamUrl['live_core_sdk_data'];
    if (sdk is Map) {
      final pull = sdk['pull_data'];
      if (pull is Map) {
        final raw = pull['stream_data'];
        if (raw is String && raw.isNotEmpty) {
          try {
            final parsed = jsonDecode(raw);
            if (parsed is Map) {
              final data = parsed['data'];
              if (data is Map) {
                for (final e in data.entries) {
                  final quality = e.key;
                  final stream = e.value;
                  if (stream is! Map) continue;
                  final main = stream['main'];
                  if (main is! Map) continue;
                  addFlv(main['flv']?.toString());
                  addHls(main['hls']?.toString());
                  notes.add('sdk:$quality');
                }
              }
            }
          } catch (e) {
            notes.add('解析 stream_data 失败: $e');
          }
        }
      }
    }
  }

  Future<void> _ttLiveDetail(
    String roomId,
    List<String> flv,
    List<String> hls,
    List<String> notes,
  ) async {
    final res = await _dio.get(
      'https://www.tiktok.com/api/live/detail/',
      queryParameters: {
        'aid': '1988',
        'roomID': roomId,
      },
      options: Options(
        headers: _ttHeaders(),
        responseType: ResponseType.json,
      ),
    );
    final root = res.data;
    if (root is! Map) return;
    final info = root['LiveRoomInfo'];
    if (info is! Map) {
      notes.add('live/detail 无 LiveRoomInfo');
      return;
    }
    final liveUrl = info['liveUrl']?.toString();
    if (liveUrl != null && liveUrl.startsWith('http')) {
      hls.add(_cleanUrl(liveUrl));
      notes.add('来源: api/live/detail liveUrl');
    }
    final streamData = info['streamData'] ?? info['stream_data'];
    if (streamData is Map) {
      _ttCollectStreamUrlMap(streamData, flv, hls, notes);
    }
  }
}
