import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import 'douyin_abogus.dart';

/// 直播间拉流地址提取。支持抖音 / 快手 / B站 / 小红书 / YouTube / TikTok / 虎牙 / 斗鱼。
class FlvExtractor {
  FlvExtractor({Dio? dio, this.kuaishouCookie, this.tiktokCookie})
      : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 15),
                receiveTimeout: const Duration(seconds: 15),
                followRedirects: true,
                maxRedirects: 5,
                validateStatus: (s) => s != null && s < 500,
                headers: {
                  'User-Agent': _ua,
                  'Accept': 'text/html,application/json,*/*',
                  'Accept-Language': 'zh-CN,zh;q=0.9',
                },
              ),
            );

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Safari/537.36';

  /// OBS FFmpeg 媒体源复用同一 UA（YouTube 等 CDN 常校验）
  static const browserUa = _ua;

  final Dio _dio;

  /// 浏览器登录 live.kuaishou.com 后复制的 Cookie（可显著降低风控）
  String? kuaishouCookie;

  /// 浏览器登录 www.tiktok.com 后复制的 Cookie（部分地区/18+ 房间需要）
  String? tiktokCookie;

  Future<FlvExtractResult> extract(String input) async {
    final text = input.trim();
    if (text.isEmpty) {
      return FlvExtractResult.fail('请输入直播间链接或房间号');
    }

    final platform = detectPlatform(text);
    try {
      switch (platform) {
        case LivePlatform.kuaishou:
          return await _extractKuaishou(text);
        case LivePlatform.douyin:
          return await _extractDouyin(text);
        case LivePlatform.bilibili:
          return await _extractBilibili(text);
        case LivePlatform.xiaohongshu:
          return await _extractXiaohongshu(text);
        case LivePlatform.youtube:
          return await _extractYoutube(text);
        case LivePlatform.tiktok:
          return await _extractTiktok(text);
        case LivePlatform.huya:
          return await _extractHuya(text);
        case LivePlatform.douyu:
          return await _extractDouyu(text);
        case LivePlatform.unknown:
          if (RegExp(r'^[A-Za-z0-9_\-]+$').hasMatch(text)) {
            return await _extractKuaishou(text);
          }
          if (RegExp(r'^\d+$').hasMatch(text)) {
            // 纯数字：优先按 B 站房间号试，再抖音
            final bili = await _extractBilibili(text);
            if (bili.ok) return bili;
            return await _extractDouyin(text);
          }
          return FlvExtractResult.fail(
            '无法识别平台，请粘贴完整链接（抖音/快手/B站/小红书/YouTube/TikTok）',
          );
      }
    } catch (e) {
      return FlvExtractResult.fail('提取失败: $e');
    }
  }

  LivePlatform detectPlatform(String text) {
    final u = text.toLowerCase();
    if (u.contains('kuaishou') ||
        u.contains('gifshow') ||
        u.contains('chenzhongtech') ||
        u.contains('v.kuaishou')) {
      return LivePlatform.kuaishou;
    }
    // TikTok 国际版（勿与抖音混用）
    if (u.contains('tiktok.com') ||
        u.contains('tiktokv.com') ||
        u.contains('vt.tiktok') ||
        u.contains('vm.tiktok') ||
        (u.startsWith('@') && !u.contains('douyin'))) {
      return LivePlatform.tiktok;
    }
    if (u.contains('douyin') || u.contains('iesdouyin')) {
      return LivePlatform.douyin;
    }
    if (u.contains('xiaohongshu.com') ||
        u.contains('xhslink.com') ||
        u.contains('xhs.cn') ||
        u.contains('xiaohongshu')) {
      return LivePlatform.xiaohongshu;
    }
    if (u.contains('bilibili') ||
        u.contains('b23.tv') ||
        u.contains('bili.tv') ||
        u.contains('live.bilibili')) {
      return LivePlatform.bilibili;
    }
    if (u.contains('youtube.com') ||
        u.contains('youtu.be') ||
        u.contains('youtube.com/live')) {
      return LivePlatform.youtube;
    }
    if (u.contains('huya.com')) return LivePlatform.huya;
    if (u.contains('douyu.com')) return LivePlatform.douyu;
    return LivePlatform.unknown;
  }

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
      final roomId = uri.queryParameters['room_id'] ??
          uri.queryParameters['roomId'];
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

  String _ksRoomId(String input) {
    final m =
        RegExp(r'live\.kuaishou\.com/u/([A-Za-z0-9_\-]+)').firstMatch(input);
    if (m != null) return m.group(1)!;
    final m2 = RegExp(r'kuaishou\.com/.*/([A-Za-z0-9_\-]+)').firstMatch(input);
    if (m2 != null) return m2.group(1)!;
    return input.trim().split(RegExp(r'[/?#]')).last;
  }

  Future<FlvExtractResult> _extractDouyin(String input) async {
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
    if (flv.isEmpty && hls.isEmpty && (kind == 'room_id' || kind == 'modal_id')) {
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
        final roomId = author['room_id']?.toString() ??
            author['room_id_str']?.toString();
        if (liveStatus == 1 && roomId != null && roomId != '0') {
          // 有些字段是 web_rid，有些是 room_id；短号优先当 web_rid
          if (roomId.length < 16) liveWebRid = roomId;
        }
      }
      final awemeType = detail['aweme_type'];
      final hasVideo = detail['video'] is Map;
      final isVideo = hasVideo && (awemeType == 0 || awemeType == 4 || awemeType == null);
      if (isVideo) notes.add('modal_id 对应短视频${authorName == null ? "" : " @$authorName"}');
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

  Map<String, dynamic>? _asMap(dynamic data) {
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    if (data is String) {
      try {
        final j = jsonDecode(data);
        if (j is Map) return Map<String, dynamic>.from(j);
      } catch (_) {
        // 字符串不是合法 JSON 时按无数据返回，属正常回退
      }
    }
    return null;
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

  void _collectStreamDataUrls(dynamic node, List<String> flv, List<String> hls) {
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
    for (final m in RegExp(r'https:\\/\\/[^"\\]+?\.flv[^"\\]*').allMatches(body)) {
      flv.add(_cleanUrl(m.group(0)!));
    }
    for (final m in RegExp(r'https?://[^"\s<>]+?\.flv[^"\s<>]*').allMatches(body)) {
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

  Future<FlvExtractResult> _extractKuaishou(String input) async {
    final rid = _ksRoomId(input);
    final notes = <String>[];
    final flv = <String>[];
    final hls = <String>[];
    final did = 'web_${DateTime.now().millisecondsSinceEpoch.toRadixString(16)}';
    final cookie = _mergeKsCookie(kuaishouCookie, did);
    final hasLoginCookie = _ksHasLoginCookie(kuaishouCookie);
    notes.add('房间=$rid');
    notes.add(hasLoginCookie ? 'Cookie: 已配置' : 'Cookie: 未配置');

    var rateLimited = false;
    var livingFalse = false;
    var livingTrue = false;
    String? errHint;

    Future<void> pause() async {
      await Future.delayed(const Duration(milliseconds: 400));
    }

    // —— 有登录 Cookie：优先 GraphQL（社区工具普遍依赖此路径）
    if (hasLoginCookie) {
      await _ksGraphqlLiveDetail(rid, cookie, flv, hls, notes);
      if (flv.isEmpty && hls.isEmpty) await pause();
    }

    // —— PC 直播页 INITIAL_STATE（可修 undefined；正则兜底）
    if (flv.isEmpty && hls.isEmpty) {
      try {
        final pageUrl = input.contains('http')
            ? input.trim()
            : 'https://live.kuaishou.com/u/$rid';
        final res = await _dio.get(
          pageUrl.startsWith('http')
              ? pageUrl
              : 'https://live.kuaishou.com/u/$rid',
          options: Options(headers: {
            'User-Agent': _ua,
            'Referer': 'https://live.kuaishou.com/',
            'Cookie': cookie,
            'Accept-Language': 'zh-CN,zh;q=0.9',
          }),
        );
        final body = res.data?.toString() ?? '';
        final parsed = _ksParseInitialState(body, flv, hls, notes);
        if (parsed.livingTrue) livingTrue = true;
        if (parsed.livingFalse) livingFalse = true;
        if (parsed.rateLimited) {
          rateLimited = true;
          errHint ??= '快手网页触发风控（操作频繁），请稍后或换 Cookie';
        }
        // 页面正则兜底：即使 JSON 失败也能捞 flv/m3u8
        if (flv.isEmpty && hls.isEmpty) {
          final n = _ksScrapeUrlsFromHtml(body, flv, hls);
          if (n > 0) notes.add('来源: 页面正则（$n）');
        }
      } catch (e) {
        notes.add('PC页失败: $e');
      }
      if (flv.isEmpty && hls.isEmpty) await pause();
    }

    // —— profile 页（go-olive v2）
    if (flv.isEmpty && hls.isEmpty && hasLoginCookie) {
      try {
        final res = await _dio.get(
          'https://live.kuaishou.com/profile/$rid',
          options: Options(headers: {
            'User-Agent': _ua,
            'Referer': 'https://live.kuaishou.com/',
            'Cookie': cookie,
          }),
        );
        final body = res.data?.toString() ?? '';
        if (body.contains('直播中') || body.contains('isLiving')) {
          livingTrue = true;
        }
        final n = _ksScrapeUrlsFromHtml(body, flv, hls);
        if (n > 0) notes.add('来源: profile 页（$n）');
      } catch (e) {
        notes.add('profile 失败: $e');
      }
      if (flv.isEmpty && hls.isEmpty) await pause();
    }

    // —— livedetail API
    if (flv.isEmpty && hls.isEmpty) {
      try {
        final res = await _dio.get(
          'https://live.kuaishou.com/live_api/liveroom/livedetail',
          queryParameters: {'principalId': rid},
          options: Options(headers: {
            'User-Agent': _ua,
            'Referer': 'https://live.kuaishou.com/u/$rid',
            'Cookie': cookie,
            'Accept': 'application/json',
          }),
        );
        final root = _asMap(res.data);
        final data = root == null ? null : _asMap(root['data']);
        if (data != null) {
          final result = data['result'];
          notes.add('livedetail.result=$result');
          if (result == 2) {
            rateLimited = true;
            errHint = '快手接口返回风控(result=2)，请稍后再试或粘贴浏览器 Cookie';
          }
          final author = _asMap(data['author']);
          if (author != null) {
            if (author['living'] == false) livingFalse = true;
            if (author['living'] == true) livingTrue = true;
          }
          final n = _collectKsPlayUrls(data, flv, hls);
          if (n > 0) notes.add('来源: livedetail API（$n）');
        }
      } catch (e) {
        notes.add('livedetail 失败: $e');
      }
    }

    // —— H5 byUser：已风控则跳过，避免雪上加霜
    if (flv.isEmpty && hls.isEmpty && !rateLimited) {
      await pause();
      try {
        final res = await _dio.post(
          'https://livev.m.chenzhongtech.com/rest/k/live/byUser',
          queryParameters: {
            'kpn': 'GAME_ZONE',
            'captchaToken': '',
          },
          data: {
            'source': 5,
            'eid': rid,
            'shareMethod': 'card',
            'clientType': 'WEB_OUTSIDE_SHARE_H5',
          },
          options: Options(headers: {
            'User-Agent':
                'ios/7.830 (ios 17.0; ; iPhone 15 (A2846/A3089/A3090/A3092))',
            'content-type': 'application/json',
            'Referer': 'https://v.m.chenzhongtech.com/',
            'Cookie': cookie,
            'Accept-Language': 'zh-CN,zh;q=0.9',
          }),
        );
        final root = _asMap(res.data);
        if (root != null) {
          final result = root['result'];
          notes.add('byUser.result=$result');
          final err = root['error_msg']?.toString() ?? '';
          if (err.isNotEmpty) {
            notes.add('byUser: $err');
            if (err.contains('频繁') ||
                err.contains('操作太快') ||
                err.toLowerCase().contains('frequent') ||
                result == 2) {
              rateLimited = true;
              errHint ??= '快手 H5 接口触发频率限制';
            }
          }
          final liveStream = _asMap(root['liveStream']);
          if (liveStream != null) {
            if (liveStream['living'] == false) livingFalse = true;
            if (liveStream['living'] == true) livingTrue = true;
            final n = _collectKsPlayUrls(liveStream, flv, hls);
            if (n > 0) notes.add('来源: byUser API（$n）');
          }
        }
      } catch (e) {
        notes.add('byUser 失败: $e');
      }
    } else if (rateLimited && flv.isEmpty && hls.isEmpty) {
      notes.add('已风控，跳过 byUser 以免加重限制');
    }

    final flvU = _rankFlv(_uniq(flv.where(_looksPlayableFlv)));
    final hlsU = _uniq(hls.where((u) => u.toLowerCase().contains('m3u8')));
    if (flvU.isEmpty && hlsU.isEmpty) {
      final reasons = <String>[];
      if (rateLimited) reasons.add('触发快手风控/频率限制');
      if (livingFalse && !livingTrue) reasons.add('接口显示当前未开播');
      if (livingTrue) reasons.add('页面显示在播，但未拿到地址（多半要 Cookie）');
      if (!hasLoginCookie) {
        reasons.add('未配置浏览器 Cookie（快手几乎必填）');
      }
      if (errHint != null) reasons.add(errHint);
      if (reasons.isEmpty) reasons.add('未拿到可播放地址');
      return FlvExtractResult.fail(
        '快手房间 $rid 拉流失败：${reasons.join('；')}\n'
        '正确做法：\n'
        '1) 在本软件点击「登录快手账号」，完成网页登录后自动保存\n'
        '2) 关闭 Clash TUN / 系统代理后再试（假 IP 会加重风控）\n'
        '3) 确认主播正在直播；风控后等 5–10 分钟再点\n'
        '${notes.join('\n')}',
        platform: LivePlatform.kuaishou,
        roomId: rid,
      );
    }
    return FlvExtractResult.ok(
      platform: LivePlatform.kuaishou,
      roomId: rid,
      flvUrls: flvU,
      hlsUrls: hlsU,
      allUrls: [...flvU, ...hlsU],
      note: notes.join('；'),
    );
  }

  bool _ksHasLoginCookie(String? raw) => hasKuaishouLoginCookie(raw);

  /// 判断是否像登录态 Cookie（供 UI / 自动登录引导复用）。
  static bool hasKuaishouLoginCookie(String? raw) {
    final c = sanitizeCookieHeader(raw).toLowerCase();
    if (c.trim().isEmpty) return false;
    if (c.contains('kuaishou.live.web_st=') ||
        c.contains('kuaishou.server.web_st=')) {
      return true;
    }
    final hasUser = c.contains('userid=') || c.contains('buserid=');
    final hasToken = c.contains('passtoken=') ||
        c.contains('api_st=') ||
        c.contains('web_st=');
    return hasUser && hasToken;
  }

  /// 去掉 WebView/\u0000 等非法字符，避免 Dio 拒绝 Cookie 头。
  static String sanitizeCookieHeader(String? raw) {
    final cleaned = (raw ?? '')
        .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '')
        .replaceAll(RegExp(r'[\u200b-\u200d\ufeff]'), '')
        .trim();
    if (cleaned.isEmpty) return '';
    final map = <String, String>{};
    for (final part in cleaned.split(';')) {
      final t = part.trim();
      if (t.isEmpty) continue;
      final i = t.indexOf('=');
      if (i <= 0) continue;
      final name = t.substring(0, i).trim();
      final value = t.substring(i + 1).trim();
      if (name.isEmpty || value.isEmpty) continue;
      map[name] = value;
    }
    return map.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  Future<void> _ksGraphqlLiveDetail(
    String rid,
    String cookie,
    List<String> flv,
    List<String> hls,
    List<String> notes,
  ) async {
    const query =
        r'query LiveDetail($principalId: String) { liveDetail(principalId: $principalId) { liveStream { caption playUrls { quality url } hlsPlayUrl } } }';
    for (final endpoint in [
      'https://live.kuaishou.com/graphql',
      'https://live.kuaishou.com/live_graphql',
    ]) {
      try {
        final res = await _dio.post(
          endpoint,
          data: {
            'operationName': 'LiveDetail',
            'variables': {'principalId': rid},
            'query': query,
          },
          options: Options(headers: {
            'User-Agent': _ua,
            'Referer': 'https://live.kuaishou.com/u/$rid',
            'Origin': 'https://live.kuaishou.com',
            'Cookie': cookie,
            'content-type': 'application/json',
            'Accept': 'application/json',
          }),
        );
        final root = _asMap(res.data);
        final n = _collectKsPlayUrls(root, flv, hls);
        if (n > 0) {
          notes.add('来源: $endpoint（$n）');
          return;
        }
        notes.add('$endpoint 无可用地址');
      } catch (e) {
        notes.add('$endpoint 失败: $e');
      }
    }
  }

  ({bool livingTrue, bool livingFalse, bool rateLimited}) _ksParseInitialState(
    String body,
    List<String> flv,
    List<String> hls,
    List<String> notes,
  ) {
    var livingTrue = false;
    var livingFalse = false;
    var rateLimited = false;

    final marker = body.indexOf('__INITIAL_STATE__');
    if (marker < 0) {
      notes.add('PC 页无 INITIAL_STATE');
      return (
        livingTrue: livingTrue,
        livingFalse: livingFalse,
        rateLimited: rateLimited,
      );
    }
    final start = body.indexOf('{', marker);
    if (start < 0) {
      notes.add('INITIAL_STATE 无对象起始');
      return (
        livingTrue: livingTrue,
        livingFalse: livingFalse,
        rateLimited: rateLimited,
      );
    }
    final raw = _ttSliceJsonObject(body, start);
    if (raw == null) {
      notes.add('INITIAL_STATE 括号截取失败');
      return (
        livingTrue: livingTrue,
        livingFalse: livingFalse,
        rateLimited: rateLimited,
      );
    }

    // 页面是 JS 对象，含 undefined/NaN，需先洗成合法 JSON
    final cleaned = _ksJsObjectToJson(raw);
    try {
      final root = jsonDecode(cleaned);
      final liveroom = _asMap(_asMap(root)?['liveroom']);
      final playList = liveroom?['playList'];
      if (playList is List && playList.isNotEmpty) {
        final first = _asMap(playList.first);
        if (first != null) {
          if (first['isLiving'] == true) livingTrue = true;
          if (first['isLiving'] == false) livingFalse = true;
          final err = _asMap(first['errorType']);
          if (err != null) {
            final title = '${err['title'] ?? ''}';
            final content = '${err['content'] ?? ''}';
            notes.add('页面错误: $title $content'.trim());
            if (title.contains('频繁') ||
                content.contains('频繁') ||
                content.contains('操作太快') ||
                err['type'] == 2) {
              rateLimited = true;
            }
          }
          final n = _collectKsPlayUrls(first, flv, hls);
          if (n > 0) notes.add('来源: INITIAL_STATE（$n）');
        }
      } else {
        final n = _collectKsPlayUrls(root, flv, hls);
        if (n > 0) notes.add('来源: INITIAL_STATE 扫描（$n）');
      }
      if (RegExp(r'"isLiving"\s*:\s*true').hasMatch(cleaned)) {
        livingTrue = true;
      }
    } catch (e) {
      notes.add('INITIAL_STATE 解析失败: $e');
      // JSON 仍失败时，从原文正则捞地址
      final n = _ksScrapeUrlsFromHtml(raw, flv, hls);
      if (n > 0) notes.add('来源: INITIAL_STATE 正则（$n）');
      if (RegExp(r'"isLiving"\s*:\s*true').hasMatch(raw)) livingTrue = true;
      if (raw.contains('频繁') || raw.contains('操作太快')) rateLimited = true;
    }
    return (
      livingTrue: livingTrue,
      livingFalse: livingFalse,
      rateLimited: rateLimited,
    );
  }

  String _ksJsObjectToJson(String raw) {
    var s = raw;
    s = s.replaceAll(RegExp(r'\bundefined\b'), 'null');
    s = s.replaceAll(RegExp(r'\bNaN\b'), 'null');
    s = s.replaceAll(RegExp(r',\s*([}\]])'), r'$1');
    return s;
  }

  int _ksScrapeUrlsFromHtml(
    String body,
    List<String> flv,
    List<String> hls,
  ) {
    final before = flv.length + hls.length;
    // "url":"https://....flv?..."
    final urlRe = RegExp(
      r'"url"\s*:\s*"(https?:[^"]+)"',
      caseSensitive: false,
    );
    for (final m in urlRe.allMatches(body)) {
      var u = m.group(1)!;
      u = u.replaceAll(r'\/', '/').replaceAll(r'\u002F', '/');
      u = _cleanUrl(u);
      final low = u.toLowerCase();
      if (!low.startsWith('http')) continue;
      if (low.contains('m3u8')) {
        hls.add(u);
      } else if (_looksPlayableFlv(u) ||
          low.contains('.flv') ||
          low.contains('pull-flv') ||
          low.contains('yximgs.com')) {
        flv.add(u);
      }
    }
    for (final m in RegExp(
      r'https?:\\?/\\?/[^\s"<>]+?\.m3u8[^\s"<>]*',
    ).allMatches(body)) {
      hls.add(_cleanUrl(m.group(0)!.replaceAll(r'\/', '/')));
    }
    return (flv.length + hls.length) - before;
  }

  String _mergeKsCookie(String? userCookie, String did) {
    final parts = <String>[];
    final raw = sanitizeCookieHeader(userCookie);
    if (raw.isNotEmpty) parts.add(raw);
    if (!raw.contains('did=')) parts.add('did=$did');
    return parts.join('; ');
  }

  /// 从快手响应里收集 flv/hls。返回新增条数。
  int _collectKsPlayUrls(
    dynamic node,
    List<String> flv,
    List<String> hls,
  ) {
    final before = flv.length + hls.length;
    void addUrl(String? raw) {
      if (raw == null || raw.isEmpty) return;
      final u = _cleanUrl(raw);
      final low = u.toLowerCase();
      if (!low.startsWith('http')) return;
      // 页面跳转壳，不是媒体地址
      if (low.contains('gifshow.com/fw/live') ||
          low.contains('live.kuaishou.com/u/') ||
          low.endsWith('/undefined')) {
        return;
      }
      if (low.contains('m3u8')) {
        hls.add(u);
      } else if (_looksPlayableFlv(u) ||
          low.contains('pull-') ||
          low.contains('yximgs') ||
          low.contains('kcdn') ||
          low.contains('/gift/') || // some ks cdn paths
          low.contains('stream')) {
        if (_looksPlayableFlv(u) || low.contains('.flv') || low.contains('flv')) {
          flv.add(u);
        } else if (low.contains('m3u8')) {
          hls.add(u);
        }
      }
    }

    void walk(dynamic n) {
      if (n is Map) {
        // 新版：playUrls.h264.adaptationSet.representation[].url
        final playUrls = n['playUrls'];
        if (playUrls is Map) {
          for (final codec in playUrls.values) {
            final c = _asMap(codec);
            final adapt = _asMap(c?['adaptationSet']);
            final reps = adapt?['representation'];
            if (reps is List) {
              for (final r in reps) {
                final m = _asMap(r);
                addUrl(m?['url']?.toString());
                addUrl(m?['backupUrl']?.toString());
              }
            }
            addUrl(c?['url']?.toString());
          }
        } else if (playUrls is List) {
          for (final item in playUrls) {
            final m = _asMap(item);
            addUrl(m?['url']?.toString());
            final adapt = _asMap(m?['adaptationSet']);
            final reps = adapt?['representation'];
            if (reps is List) {
              for (final r in reps) {
                final rm = _asMap(r);
                addUrl(rm?['url']?.toString());
              }
            }
          }
        }

        addUrl(n['url']?.toString());
        addUrl(n['flvUrl']?.toString());
        addUrl(n['hlsPlayUrl']?.toString());
        addUrl(n['playUrl']?.toString());

        for (final v in n.values) {
          walk(v);
        }
      } else if (n is List) {
        for (final x in n) {
          walk(x);
        }
      } else if (n is String && n.startsWith('http')) {
        addUrl(n);
      }
    }

    walk(node);
    return (flv.length + hls.length) - before;
  }

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

  Future<FlvExtractResult> _extractBilibili(String input) async {
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
        return FlvExtractResult.fail('B站无 data', platform: LivePlatform.bilibili, roomId: roomId);
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

  Future<FlvExtractResult> _extractYoutube(String input) async {
    final notes = <String>[];
    final hls = <String>[];
    final flv = <String>[];
    final vid = _youtubeVideoId(input);
    final watchUrl = vid != null
        ? 'https://www.youtube.com/watch?v=$vid'
        : (input.startsWith('http') ? input : 'https://www.youtube.com/watch?v=$input');
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

  Future<List<String>> _ytDlpGetUrls(String url) async {
    final candidates = <List<String>>[
      ['yt-dlp', '-g', '-f', 'b/best', '--no-playlist', url],
      ['yt-dlp.exe', '-g', '-f', 'b/best', '--no-playlist', url],
      ['python', '-m', 'yt_dlp', '-g', '-f', 'b/best', '--no-playlist', url],
      ['py', '-3', '-m', 'yt_dlp', '-g', '-f', 'b/best', '--no-playlist', url],
    ];
    for (final cmd in candidates) {
      try {
        final r = await Process.run(
          cmd.first,
          cmd.sublist(1),
          runInShell: true,
        ).timeout(const Duration(seconds: 45));
        if (r.exitCode != 0) continue;
        final out = '${r.stdout}';
        final urls = <String>[];
        for (final line in out.split(RegExp(r'\r?\n'))) {
          final t = line.trim();
          if (t.startsWith('http')) urls.add(t);
        }
        if (urls.isNotEmpty) return urls;
      } catch (_) {
        // 子进程输出解析失败按无候选处理，正常回退
      }
    }
    return const [];
  }

  void _walkUrls(dynamic node, List<String> out) {
    if (node is Map) {
      for (final e in node.entries) {
        if (e.value is String && (e.value as String).startsWith('http')) {
          out.add(_cleanUrl(e.value as String));
        } else {
          _walkUrls(e.value, out);
        }
      }
    } else if (node is List) {
      for (final x in node) {
        _walkUrls(x, out);
      }
    }
  }

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

  String? _ttSliceJsonObject(String body, int start) {
    var depth = 0;
    var inStr = false;
    var escape = false;
    for (var i = start; i < body.length; i++) {
      final ch = body[i];
      if (inStr) {
        if (escape) {
          escape = false;
        } else if (ch == '\\') {
          escape = true;
        } else if (ch == '"') {
          inStr = false;
        }
        continue;
      }
      if (ch == '"') {
        inStr = true;
      } else if (ch == '{') {
        depth++;
      } else if (ch == '}') {
        depth--;
        if (depth == 0) return body.substring(start, i + 1);
      }
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
        ['__DEFAULT_SCOPE__', 'webapp.user-detail', 'userInfo', 'user', 'roomId'],
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

  Future<FlvExtractResult> _extractTiktok(String input) async {
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
            if (u.contains('.flv') || u.contains('pull-flv') || u.contains('flv')) {
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
        'https://www.tiktok.com/@用户名/live\n'
        '${notes.join('\n')}',
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
          if (u.contains('.flv') || u.contains('pull-flv') || u.contains('/flv')) {
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
        'TikTok 未解析到可播地址（需开播中；部分地区需 Cookie 或关闭代理）\n'
        '${notes.join('\n')}',
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

  Future<FlvExtractResult> _extractXiaohongshu(String input) async {
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
        if (status.isNotEmpty &&
            status != 'success' &&
            status != 'null') {
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

  Future<FlvExtractResult> _extractHuya(String input) async {
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

  Future<FlvExtractResult> _extractDouyu(String input) async {
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

  String _cleanUrl(String raw) {
    var u = raw.trim();
    u = u.replaceAll(r'\/', '/');
    u = u.replaceAll(r'\u002F', '/');
    u = u.replaceAll(r'\u002f', '/');
    u = u.replaceAll(r'\u0026', '&');
    u = u.replaceAll(r'\\u0026', '&');
    u = u.replaceAll('&amp;', '&');
    // YouTube googlevideo 路径里常有逗号（met/xxx,/mh/..），绝不能按逗号截断
    if (u.startsWith('http://') || u.startsWith('https://')) {
      // 只去掉尾部 JSON/引号残片，保留 URL 内部逗号
      u = u.split('"').first.split("'").first;
      while (u.endsWith('\\') ||
          u.endsWith(']') ||
          u.endsWith(')') ||
          u.endsWith('}') ||
          u.endsWith(';') ||
          u.endsWith(',')) {
        u = u.substring(0, u.length - 1);
      }
      return u.trim();
    }
    // 非 URL 的旧逻辑（页面残片）
    u = u.split('"').first.split("'").first.split('}').first.split(',').first;
    while (u.endsWith('\\') || u.endsWith(']') || u.endsWith(')')) {
      u = u.substring(0, u.length - 1);
    }
    return u.trim();
  }

  bool _looksPlayableFlv(String u) {
    final s = u.toLowerCase();
    if (!s.startsWith('http')) return false;
    if (s.contains('only_audio=1')) return false;
    if (s.contains('gifshow.com/fw/live') || s.endsWith('/undefined')) {
      return false;
    }
    if (!(s.contains('.flv') ||
        s.contains('pull-flv') ||
        s.contains('/flv/') ||
        s.contains('filetype=flv') ||
        s.contains('streamtype=flv') ||
        (s.contains('tiktokcdn') && s.contains('flv')))) {
      return false;
    }
    // 太短基本是截断垃圾
    if (u.length < 40) return false;
    return true;
  }

  /// 清晰度排序：原画/FULL_HD 优先；避开 HEVC/AV1（OBS 兼容性）
  List<String> _rankFlv(Iterable<String> urls) {
    final list = urls.toList();
    int score(String u) {
      final s = u.toLowerCase();
      var base = 60;
      if (s.contains('origin') || s.contains('or4') || s.contains('uhd')) {
        base = 100;
      } else if (s.contains('full_hd') || s.contains('hd1') || s.contains('_hd')) {
        base = 80;
      } else if (s.contains('sd1') || s.contains('_sd')) {
        base = 40;
      } else if (s.contains('ld1')) {
        base = 20;
      }
      // B站 hevc / av1 部分机器 OBS 打不开
      if (s.contains('hevc') || s.contains('h265') || s.contains('av1') || s.contains('minihevc')) {
        base -= 40;
      }
      if (s.contains('avc') || s.contains('2500') || s.contains('10000')) {
        base += 5;
      }
      // gotcha 线路比运营商节点更稳；cn-xxx-cu 在 OBS 里常立刻 ended
      if (s.contains('gotcha')) {
        base += 18;
      }
      if (RegExp(r'cn-[a-z0-9]+-(cu|ct|cm)-').hasMatch(s)) {
        base -= 12;
      }
      if (s.contains('xhscdn')) {
        if (s.startsWith('https://')) base += 8;
        if (s.contains('live-source-play-hw') && !s.contains('bak')) base += 10;
        if (s.contains('-bak-')) base -= 6;
      }
      return base;
    }

    list.sort((a, b) {
      final c = score(b).compareTo(score(a));
      if (c != 0) return c;
      return b.length.compareTo(a.length);
    });
    return list;
  }

  List<String> _uniq(Iterable<String> urls) {
    final seen = <String>{};
    final out = <String>[];
    for (var u in urls) {
      u = _cleanUrl(u);
      if (u.length < 20) continue;
      if (seen.add(u)) out.add(u);
    }
    return out;
  }
}

enum LivePlatform {
  kuaishou,
  douyin,
  bilibili,
  xiaohongshu,
  youtube,
  tiktok,
  huya,
  douyu,
  unknown,
}

class _DyAwemeProbe {
  final bool isVideo;
  final String? author;
  final String? liveWebRid;

  _DyAwemeProbe({
    required this.isVideo,
    this.author,
    this.liveWebRid,
  });
}

class FlvExtractResult {
  final bool ok;
  final String message;
  final LivePlatform platform;
  final String? roomId;
  final List<String> flvUrls;
  final List<String> hlsUrls;
  final List<String> allUrls;
  final String? note;

  FlvExtractResult.ok({
    required this.platform,
    this.roomId,
    required this.flvUrls,
    required this.hlsUrls,
    required this.allUrls,
    this.note,
  })  : ok = true,
        message = '提取成功';

  FlvExtractResult.fail(
    this.message, {
    this.platform = LivePlatform.unknown,
    this.roomId,
  })  : ok = false,
        flvUrls = const [],
        hlsUrls = const [],
        allUrls = const [],
        note = null;

  String bestUrl() {
    if (flvUrls.isNotEmpty) return flvUrls.first;
    if (hlsUrls.isNotEmpty) return hlsUrls.first;
    if (allUrls.isNotEmpty) return allUrls.first;
    return '';
  }

  /// OBS 试播顺序：FLV 优先，再 HLS；已去重。
  List<String> playCandidates({int max = 6}) {
    final seen = <String>{};
    final out = <String>[];
    for (final u in [...flvUrls, ...hlsUrls, ...allUrls]) {
      if (u.trim().isEmpty || !seen.add(u)) continue;
      out.add(u);
      if (out.length >= max) break;
    }
    return out;
  }

  String summary() {
    if (!ok) return message;
    final buf = StringBuffer()
      ..writeln('平台: $platform')
      ..writeln(roomId == null ? '' : '房间: $roomId');
    if (note != null && note!.isNotEmpty) buf.writeln(note);
    if (flvUrls.isNotEmpty) {
      buf.writeln('FLV（优先第一条给 OBS）:');
      for (final u in flvUrls.take(5)) {
        buf.writeln(u);
      }
    }
    if (hlsUrls.isNotEmpty) {
      buf.writeln('HLS:');
      for (final u in hlsUrls.take(3)) {
        buf.writeln(u);
      }
    }
    return buf.toString().trim();
  }
}
