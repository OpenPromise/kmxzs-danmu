part of '../flv_extractor.dart';

class KuaishouFlvExtractor extends PlatformExtractor {
  KuaishouFlvExtractor(super.dio, {String? cookie})
      : super(kuaishouCookie: cookie);

  @override
  LivePlatform get platform => LivePlatform.kuaishou;

  String _ksRoomId(String input) {
    final m =
        RegExp(r'live\.kuaishou\.com/u/([A-Za-z0-9_\-]+)').firstMatch(input);
    if (m != null) return m.group(1)!;
    final m2 = RegExp(r'kuaishou\.com/.*/([A-Za-z0-9_\-]+)').firstMatch(input);
    if (m2 != null) return m2.group(1)!;
    return input.trim().split(RegExp(r'[/?#]')).last;
  }

  @override
  Future<FlvExtractResult> extract(String input) async {
    final rid = _ksRoomId(input);
    final notes = <String>[];
    final flv = <String>[];
    final hls = <String>[];

    final hasLoginCookie = _ksHasLoginCookie(kuaishouCookie);
    // 不要每次拉流都伪造新 did：整段 Cookie 有 did= 就沿用原 did；
    // 有 web_st 时补假 did 会被快手当成异常设备。仅当完全没有 did= 且
    // 也没有 web_st 时才补一个占位 did。
    final cookie = _mergeKsCookie(kuaishouCookie);
    notes.add('房间=$rid');
    notes
        .add(hasLoginCookie ? 'Cookie: 已配置（含 web_st）' : 'Cookie: 缺少 web_st 字段');

    var rateLimited = false;
    var livingFalse = false;
    var livingTrue = false;
    String? errHint;

    Future<void> pause() async {
      await Future.delayed(const Duration(milliseconds: 400));
    }

    // —— 主路径：房间页 INITIAL_STATE（输入若已是完整 URL 则用原 URL）
    if (flv.isEmpty && hls.isEmpty) {
      try {
        final trimmed = input.trim();
        final pageUrl = trimmed.toLowerCase().startsWith('http')
            ? trimmed
            : 'https://live.kuaishou.com/u/$rid';
        final res = await _dio.get(
          pageUrl,
          options: Options(headers: {
            'User-Agent': _ksUa,
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
          errHint ??= '操作过于频繁，请关闭代理后等几分钟再试';
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

    // —— 兜底：livedetail API（最多一次；已风控则不再打任何接口）
    if (flv.isEmpty && hls.isEmpty && !rateLimited) {
      try {
        final res = await _dio.get(
          'https://live.kuaishou.com/live_api/liveroom/livedetail',
          queryParameters: {'principalId': rid},
          options: Options(headers: {
            'User-Agent': _ksUa,
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
            errHint = '操作过于频繁，请关闭代理后等几分钟再试';
          } else {
            final author = _asMap(data['author']);
            if (author != null) {
              if (author['living'] == false) livingFalse = true;
              if (author['living'] == true) livingTrue = true;
            }
            final n = _collectKsPlayUrls(data, flv, hls);
            if (n > 0) notes.add('来源: livedetail API（$n）');
            if (result == 400002) {
              errHint = '请先登录快手账号';
            }
          }
        }
      } catch (e) {
        notes.add('livedetail 失败: $e');
      }
      if (flv.isEmpty && hls.isEmpty) await pause();
    }

    // —— GraphQL 兜底（仅保留作兜底：有登录 Cookie、未风控、前面都失败时）
    if (flv.isEmpty && hls.isEmpty && !rateLimited && hasLoginCookie) {
      await _ksGraphqlLiveDetail(rid, cookie, flv, hls, notes);
    }

    if (rateLimited) notes.add('已风控，跳过其余接口以免加重限制');

    final flvU = _rankFlv(_uniq(flv.where(_looksPlayableFlv)));
    final hlsU = _uniq(hls.where((u) => u.toLowerCase().contains('m3u8')));
    if (flvU.isEmpty && hlsU.isEmpty) {
      final String failReason;
      if (rateLimited) {
        failReason = '已触发快手风控/频率限制。请关闭 TUN / 系统代理，等 5–10 分钟再试（无需重新登录）。';
      } else if (livingFalse && !livingTrue) {
        failReason = '接口显示当前未开播。请确认主播正在直播。';
      } else if (!hasLoginCookie) {
        failReason = '请先登录快手账号。';
      } else if (errHint != null) {
        failReason = errHint;
      } else {
        failReason = '未拿到可播放地址。';
      }
      return FlvExtractResult.fail(
        '快手房间 $rid 拉流失败：$failReason\n'
        '提示：请确认主播正在直播；未登录时先点「登录快手账号」。',
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

  /// 判断是否有直播站登录态 Cookie（供 UI / 自动登录引导复用）。
  /// 必须含 live/server 域下发的 `kuaishou.live.web_st` 或 `kuaishou.server.web_st`；
  /// userId / passToken 只是通行证 Cookie，不能当作已登录。
  static bool hasKuaishouLoginCookie(String? raw) {
    final c = sanitizeCookieHeader(raw).toLowerCase();
    if (c.trim().isEmpty) return false;
    return c.contains('kuaishou.live.web_st=') ||
        c.contains('kuaishou.server.web_st=');
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
        r'query LiveDetail($principalId: String) { liveDetail(principalId: $principalId) { liveStream { caption playUrls { h264 { adaptationSet { representation { url backupUrl name } } } } hlsPlayUrl } } }';
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
            'User-Agent': _ksUa,
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

    void onLiving({required bool living, required bool notLiving}) {
      if (living) livingTrue = true;
      if (notLiving) livingFalse = true;
    }

    void applyErrorType(dynamic err) {
      final e = _asMap(err);
      if (e == null) return;
      final title = '${e['title'] ?? ''}';
      final content = '${e['content'] ?? ''}';
      notes.add('页面错误: $title $content'.trim());
      if (title.contains('滑块') ||
          content.contains('滑块') ||
          content.contains('完成验证')) {
        return;
      }
      if (title.contains('频繁') ||
          content.contains('频繁') ||
          content.contains('操作太快') ||
          e['type'] == 2) {
        rateLimited = true;
      }
    }

    // 主路径：与 DouyinLiveRecorder 相同的两段正则。
    // 1) 抠出整段 INITIAL_STATE JS 对象；
    // 2) 再抠出其中的 {"liveStream"...},"gameInfo 块，补 '}' 变回合法 JSON。
    final stateMatch = RegExp(
      r'window\.__INITIAL_STATE__=(.*?);\(function\(\)\{var s;',
      dotAll: true,
    ).firstMatch(body);
    final liveChunk =
        stateMatch == null ? null : ksLiveStreamChunk(stateMatch.group(1)!);
    if (liveChunk != null) {
      final cleaned = ksJsObjectToJson(liveChunk);
      try {
        final root = jsonDecode(cleaned);
        if (root is Map) {
          final liveStream = _asMap(root['liveStream']);
          if (liveStream != null) {
            if (liveStream['living'] == true) {
              onLiving(living: true, notLiving: false);
            }
            if (liveStream['living'] == false) {
              onLiving(living: false, notLiving: true);
            }
            applyErrorType(liveStream['errorType']);
            // 主路径显式走 h264（OBS 不兼容 hevc），优先 representation[].url
            final h264 = _asMap(_asMap(liveStream['playUrls'])?['h264']);
            final adapt = _asMap(h264?['adaptationSet']);
            final reps = adapt?['representation'];
            if (reps is List && reps.isNotEmpty) {
              var n = 0;
              for (final r in reps) {
                final m = _asMap(r);
                if (m == null) continue;
                final u = _cleanUrl(m['url']?.toString() ?? '');
                if (u.isNotEmpty && _looksPlayableFlv(u)) {
                  flv.add(u);
                  n++;
                }
                final backup = _cleanUrl(m['backupUrl']?.toString() ?? '');
                if (backup.isNotEmpty && _looksPlayableFlv(backup)) {
                  flv.add(backup);
                  n++;
                }
              }
              if (n > 0) notes.add('来源: INITIAL_STATE h264（$n）');
            }
            // 补充：递归扫描整个 liveStream，兜住其它候选
            final extra = _collectKsPlayUrls(liveStream, flv, hls);
            if (extra > 0) notes.add('来源: INITIAL_STATE 扫描（$extra）');
          }
        }
      } catch (e) {
        notes.add('liveStream 块解析失败: $e');
      }
    }

    // 两段正则没出地址时，回退整段 INITIAL_STATE 截取
    if (flv.isEmpty && hls.isEmpty) {
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
      final cleaned = ksJsObjectToJson(raw);
      try {
        final root = jsonDecode(cleaned);
        final liveroom = _asMap(_asMap(root)?['liveroom']);
        final playList = liveroom?['playList'];
        if (playList is List && playList.isNotEmpty) {
          final first = _asMap(playList.first);
          if (first != null) {
            if (first['isLiving'] == true) {
              onLiving(living: true, notLiving: false);
            }
            if (first['isLiving'] == false) {
              onLiving(living: false, notLiving: true);
            }
            applyErrorType(first['errorType']);
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
    }
    return (
      livingTrue: livingTrue,
      livingFalse: livingFalse,
      rateLimited: rateLimited,
    );
  }

  /// 从 INITIAL_STATE JS 对象里抠出 `{"liveStream"...}` 之前的 JSON 块并补全。
  /// 结构：`{"liveStream":{...},"gameInfo":{...}}`，捕获组不含外层结尾 `}`，需补一个。
  /// 公开给单测直接调用（纯字符串处理，不打网络）。
  static String? ksLiveStreamChunk(String state) {
    final m = RegExp(
      r'(\{"liveStream".*?),"gameInfo',
      dotAll: true,
    ).firstMatch(state);
    if (m == null) return null;
    return '${m.group(1)!}}';
  }

  /// 把 JS 对象字面量洗成合法 JSON：undefined/NaN → null，删尾逗号。
  /// 公开给单测直接调用。
  static String ksJsObjectToJson(String raw) {
    var s = raw;
    s = s.replaceAll(RegExp(r'\bundefined\b'), 'null');
    s = s.replaceAll(RegExp(r'\bNaN\b'), 'null');
    // 尾逗号必须用 replaceAllMapped 写回捕获组，禁止 r'$1'（那会变成字面量 $1，损坏 JSON）。
    s = s.replaceAllMapped(
      RegExp(r',\s*([}\]])'),
      (m) => m.group(1)!,
    );
    return s;
  }

  /// 测试专用：解析一段含 INITIAL_STATE 的 HTML，返回抽出的地址与状态（不打网络）。
  static ({
    List<String> flvUrls,
    List<String> hlsUrls,
    bool livingTrue,
    bool livingFalse,
    bool rateLimited,
  }) ksParseInitialStateHtml(String body) {
    final f = KuaishouFlvExtractor(Dio());
    final flv = <String>[];
    final hls = <String>[];
    final notes = <String>[];
    final r = f._ksParseInitialState(body, flv, hls, notes);
    return (
      flvUrls: List.unmodifiable(flv),
      hlsUrls: List.unmodifiable(hls),
      livingTrue: r.livingTrue,
      livingFalse: r.livingFalse,
      rateLimited: r.rateLimited,
    );
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

  String _mergeKsCookie(String? userCookie) {
    final raw = sanitizeCookieHeader(userCookie);
    if (raw.isEmpty) return '';
    final lower = raw.toLowerCase();
    // 不要每次生成新 did：有 did= 就沿用原 did；有 web_st 时补假 did 会被当异常设备。
    // 仅当整段 Cookie 完全没有 did= 且也没有 web_st 时才补一个占位 did。
    if (!lower.contains('did=') &&
        !lower.contains('kuaishou.live.web_st=') &&
        !lower.contains('kuaishou.server.web_st=')) {
      final did =
          'web_${DateTime.now().millisecondsSinceEpoch.toRadixString(16)}';
      return '$raw; did=$did';
    }
    return raw;
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
        if (_looksPlayableFlv(u) ||
            low.contains('.flv') ||
            low.contains('flv')) {
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
          for (final entry in playUrls.entries) {
            final codecName = entry.key.toString().toLowerCase();
            // 忽略 hevc/h265/av1（OBS 不兼容），主路径只走 h264
            if (codecName.contains('hevc') ||
                codecName.contains('h265') ||
                codecName.contains('av1')) {
              continue;
            }
            final c = _asMap(entry.value);
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
}
