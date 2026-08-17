import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter/material.dart';
import 'package:kmxzs/services/flv_extractor.dart';
import 'package:kmxzs/services/webview2_runtime.dart';
import 'package:kmxzs/services/win_hotkey.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 用一次性干净 WebView2 会话打开快手房间页取流（类似无痕）。
///
/// 持久登录目录会被快手按设备身份打分；分不够时只扣当前房间 playUrls。
/// 每次拉流换新用户目录，不沿用这份身份。
///
/// 实测 `https://live.kuaishou.com/u/{rid}` 的数据结构：
/// `window.__INITIAL_STATE__.liveroom.playList` 是数组，
/// **只有 author.id == 房间号的那一项**才是当前直播；其余项是推荐位，
/// 也带 playUrls，整页扫描会拿到别人的流。
/// 当前项可能因验证暂时为空；通过后只在本页取流并关窗，不刷新。
class KsWebPullPage {
  KsWebPullPage._();

  static const _hookJs = r'''
(function () {
  if (window.__kmxzsHooked) return;
  window.__kmxzsHooked = true;
  window.__kmxzsByPrincipal = {};
  window.__kmxzsPerf = [];
  function keep(pid, u) {
    if (!u) return;
    var s = String(u);
    if (!/^https?:/i.test(s) || !/(\.flv|m3u8|pull-flv|pull-hls)/i.test(s)) return;
    var id = String(pid || '').toLowerCase();
    if (!id) {
      if (window.__kmxzsPerf.indexOf(s) < 0) window.__kmxzsPerf.push(s);
      return;
    }
    var arr = window.__kmxzsByPrincipal[id] || [];
    if (arr.indexOf(s) < 0) arr.push(s);
    window.__kmxzsByPrincipal[id] = arr;
  }
  function takeH264(ls, pid) {
    if (!ls || typeof ls !== 'object') return;
    keep(pid, ls.hlsPlayUrl);
    var play = ls.playUrls;
    var h264 = play && play.h264;
    var reps = h264 && h264.adaptationSet && h264.adaptationSet.representation;
    if (!Array.isArray(reps)) return;
    for (var i = 0; i < reps.length; i++) {
      var r = reps[i] || {};
      keep(pid, r.url);
      keep(pid, r.backupUrl);
    }
  }
  function ingest(json) {
    if (!json || typeof json !== 'object') return;
    var data = json.data || json;
    var detail = data.liveDetail || data;
    var ls = detail.liveStream || data.liveStream;
    var author = detail.author || data.author || {};
    var pid = author.id || author.principalId || (ls && ls.principalId) || '';
    if (ls && pid) takeH264(ls, pid);
  }
  var ofetch = window.fetch;
  if (typeof ofetch === 'function') {
    window.fetch = function () {
      return ofetch.apply(this, arguments).then(function (res) {
        try {
          var u = String(res.url || '');
          keep('', u);
          if (/graphql|livedetail|live_api/i.test(u)) {
            res.clone().json().then(ingest).catch(function () {});
          }
        } catch (e) {}
        return res;
      });
    };
  }
  var xo = XMLHttpRequest.prototype.open;
  var xs = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function (m, u) {
    this.__kmxzsU = u;
    return xo.apply(this, arguments);
  };
  XMLHttpRequest.prototype.send = function () {
    this.addEventListener('load', function () {
      try {
        keep('', this.responseURL || this.__kmxzsU);
        var t = this.responseText;
        if (t && t.length < 2000000 && (t.charAt(0) === '{' || t.charAt(0) === '[')) {
          ingest(JSON.parse(t));
        }
      } catch (e) {}
    });
    return xs.apply(this, arguments);
  };
})();
''';

  static String _probeJs(String rid) {
    final encoded = jsonEncode(rid);
    return '''
(function () {
  var rid = $encoded;
  function pushH264(ls, urls) {
    if (!ls || typeof ls !== 'object') return;
    var s = ls.hlsPlayUrl ? String(ls.hlsPlayUrl) : '';
    if (/^https?:/i.test(s) && /m3u8|pull-hls/i.test(s)) urls.push(s);
    var play = ls.playUrls;
    var h264 = play && play.h264;
    var reps = h264 && h264.adaptationSet && h264.adaptationSet.representation;
    if (!Array.isArray(reps)) return;
    for (var i = 0; i < reps.length; i++) {
      var r = reps[i] || {};
      var u = r.url ? String(r.url) : '';
      var b = r.backupUrl ? String(r.backupUrl) : '';
      if (/^https?:/i.test(u) && /(\\.flv|pull-flv)/i.test(u)) urls.push(u);
      if (/^https?:/i.test(b) && /(\\.flv|pull-flv)/i.test(b)) urls.push(b);
    }
  }
  function itemOf(raw) {
    var item = raw || {};
    var ls = item.liveStream || {};
    var author = item.author || {};
    var err = item.errorType || {};
    var urls = [];
    pushH264(ls, urls);
    return {
      principalId: String(author.id || author.principalId || ls.principalId || ''),
      urls: urls,
      errorTitle: String(err.title || ''),
      isLiving: item.isLiving === true || ls.living === true
    };
  }
  var href = String(location.href || '');
  var state = {};
  try { state = window.__INITIAL_STATE__ || {}; } catch (e) {}
  var lr = state.liveroom || {};
  var list = Array.isArray(lr.playList) ? lr.playList : [];
  var items = [];
  for (var i = 0; i < list.length; i++) items.push(itemOf(list[i]));
  var hooked = [];
  try {
    var bag = window.__kmxzsByPrincipal || {};
    var hit = bag[String(rid).toLowerCase()] || [];
    for (var j = 0; j < hit.length; j++) hooked.push(hit[j]);
  } catch (e) {}
  var perf = [];
  try {
    var extra = window.__kmxzsPerf || [];
    for (var k = 0; k < extra.length; k++) perf.push(extra[k]);
    var entries = performance.getEntriesByType('resource');
    for (var n = 0; n < entries.length; n++) {
      var name = String(entries[n].name || '');
      if (/^https?:/i.test(name) && /(\\.flv|m3u8|pull-flv|pull-hls)/i.test(name)) perf.push(name);
    }
  } catch (e) {}
  function visibleBox(el) {
    if (!el) return false;
    var r = el.getBoundingClientRect();
    return r.width > 80 && r.height > 80;
  }
  var captcha = false;
  try {
    var iframes = document.querySelectorAll(
      'iframe[src*="captcha"], iframe[src*="verify"], iframe[src*="geetest"]'
    );
    for (var c = 0; c < iframes.length; c++) {
      if (visibleBox(iframes[c])) { captcha = true; break; }
    }
    if (!captcha) {
      var nodes = document.querySelectorAll('div, span, p, h1, h2, h3, button');
      var nmax = Math.min(nodes.length, 120);
      for (var t = 0; t < nmax; t++) {
        if (!visibleBox(nodes[t])) continue;
        var s = String(nodes[t].innerText || '').slice(0, 48);
        if (/请完成滑块|拖动滑块|请点击|依次点击|图形验证|请完成验证/.test(s)) {
          captcha = true;
          break;
        }
      }
    }
  } catch (e) {}
  var activeIndex = lr.activeIndex || 0;
  var active = items[activeIndex] || null;
  return JSON.stringify({
    href: href,
    captcha: captcha,
    activeIndex: activeIndex,
    activeError: active ? active.errorTitle : '',
    items: items,
    hooked: hooked,
    perf: perf
  });
})()
''';
  }

  static Future<FlvExtractResult> open(
    BuildContext context,
    String input, {
    void Function(String msg)? log,
  }) async {
    void note(String m) => log?.call(m);

    final available = await WebviewWindow.isWebviewAvailable();
    if (!available) {
      if (context.mounted) {
        await WebView2Runtime.showMissingDialog(context);
      }
      return FlvExtractResult.fail(
        '本机未安装 WebView2 运行时。请先安装后再拉流。',
        platform: LivePlatform.kuaishou,
      );
    }

    final rid = _roomId(input);
    final pageUrl = input.trim().toLowerCase().startsWith('http')
        ? input.trim()
        : 'https://live.kuaishou.com/u/$rid';
    note('正在用干净会话打开房间 $rid（类似无痕，不沿用已风控身份）');

    final profile = await _freshIncognitoProfile();
    late final Webview webview;
    try {
      webview = await WebviewWindow.create(
        configuration: CreateConfiguration(
          title: '快手直播间（滑块请拖完）',
          windowWidth: 1100,
          windowHeight: 780,
          titleBarHeight: 40,
          userDataFolderWindows: profile,
          openMaximized: true,
        ),
      );
    } catch (e) {
      _wipeProfileLater(profile);
      return FlvExtractResult.fail(
        '无法打开快手浏览器窗口: $e',
        platform: LivePlatform.kuaishou,
        roomId: rid,
      );
    }

    final completer = Completer<FlvExtractResult>();
    var settled = false;
    BuildContext? tipCtx;
    var sliderHinted = false;
    var verifyPassedHinted = false;
    var roomOpenedHinted = false;
    DateTime? verifiedAt;
    final startedAt = DateTime.now();

    Future<void> raisePullWindow() async {
      try {
        await webview.setWebviewWindowVisibility(true);
        await webview.bringToForeground(maximized: true);
      } catch (e) {
        debugPrint('[ks-pull] bringToForeground: $e');
      }
      WinHotkey.raiseTopmostByTitle('快手直播间');
    }

    void dismissTip() {
      final c = tipCtx;
      if (c != null && c.mounted) {
        Navigator.of(c).pop();
      }
      tipCtx = null;
    }

    void finish(FlvExtractResult result) {
      if (settled) return;
      settled = true;
      dismissTip();
      try {
        webview.close();
      } catch (e) {
        debugPrint('[ks-pull] close: $e');
      }
      _wipeProfileLater(profile);
      if (!completer.isCompleted) completer.complete(result);
    }

    webview.onClose.whenComplete(() {
      finish(
        FlvExtractResult.fail(
          '已关闭快手直播间窗口，未取到拉流地址。',
          platform: LivePlatform.kuaishou,
          roomId: rid,
        ),
      );
    });

    try {
      await webview.setApplicationNameForUserAgent(' kmxzs/1.0');
    } catch (e) {
      debugPrint('[ks-pull] ua: $e');
    }
    try {
      webview.addScriptToExecuteOnDocumentCreated(_hookJs);
    } catch (e) {
      debugPrint('[ks-pull] hook: $e');
    }
    webview.launch(pageUrl, triggerOnUrlRequestEvent: false);

    if (context.mounted) {
      unawaited(showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          tipCtx = ctx;
          return AlertDialog(
            title: const Text('正在取流'),
            content: Text(
              '正在用干净会话打开房间 $rid。出现验证时请在弹出窗口完成，'
              '通过后软件会自动取流并关闭窗口。',
            ),
            actions: [
              TextButton(
                onPressed: () => finish(
                  FlvExtractResult.fail(
                    '已取消快手浏览器取流。',
                    platform: LivePlatform.kuaishou,
                    roomId: rid,
                  ),
                ),
                child: const Text('取消'),
              ),
            ],
          );
        },
      ));
    }

    unawaited(() async {
      final probe = _probeJs(rid);
      while (!settled) {
        await Future.delayed(const Duration(milliseconds: 800));
        if (settled) return;
        try {
          final raw = await webview.evaluateJavaScript(probe);
          final parsed = _parseProbe(raw);
          if (parsed == null) continue;
          if (hrefIsTargetRoom(parsed.href, rid) && !roomOpenedHinted) {
            roomOpenedHinted = true;
            note('已进入房间页 ${parsed.href}');
          }
          final urls = pickCurrentRoomUrls(
            rid: rid,
            href: parsed.href,
            items: parsed.items,
            activeIndex: parsed.activeIndex,
            extraUrls: [...parsed.hooked, ...parsed.perf],
          );
          if (urls.isNotEmpty) {
            final packed = FlvExtractor().packPlayUrls(
              platform: LivePlatform.kuaishou,
              roomId: rid,
              urls: urls,
              note: '来源: WebView playList 当前房间',
            );
            if (packed.ok) {
              note(
                '浏览器取流成功，房间 $rid，当前场 ${packed.allUrls.length} 条',
              );
              finish(packed);
              return;
            }
          }
          final needSlide = parsed.captcha ||
              parsed.activeError.contains('滑块') ||
              parsed.activeError.contains('完成验证') ||
              parsed.activeError.contains('图形');
          final rateLimited = parsed.activeError.contains('请求过快') ||
              parsed.activeError.contains('稍后重试');
          if (needSlide) {
            if (!sliderHinted) {
              sliderHinted = true;
              note('出现验证，已把窗口置顶。完成后会自动取流并关窗');
              await raisePullWindow();
            }
            continue;
          }
          if (sliderHinted && !verifyPassedHinted) {
            verifyPassedHinted = true;
            verifiedAt = DateTime.now();
            note('验证已通过，正在取流');
          }
          if (verifyPassedHinted &&
              verifiedAt != null &&
              DateTime.now().difference(verifiedAt!) >=
                  const Duration(seconds: 12)) {
            finish(
              FlvExtractResult.fail(
                rateLimited
                    ? '验证已过，但房间 $rid 仍被风控，没有当前场地址。请等普通浏览器能直接出画面后再试。'
                    : '验证已过，但未拿到房间 $rid 的拉流地址。',
                platform: LivePlatform.kuaishou,
                roomId: rid,
              ),
            );
            return;
          }
          if (!sliderHinted &&
              DateTime.now().difference(startedAt) >=
                  const Duration(seconds: 20) &&
              rateLimited) {
            finish(
              FlvExtractResult.fail(
                '房间 $rid 当前被风控（请求过快），没有可取的直播地址。',
                platform: LivePlatform.kuaishou,
                roomId: rid,
              ),
            );
            return;
          }
          if (!sliderHinted &&
              DateTime.now().difference(startedAt) >=
                  const Duration(seconds: 90)) {
            finish(
              FlvExtractResult.fail(
                '浏览器 90 秒内未拿到房间 $rid 的拉流地址。请确认主播正在直播。',
                platform: LivePlatform.kuaishou,
                roomId: rid,
              ),
            );
            return;
          }
        } catch (e) {
          debugPrint('[ks-pull] probe: $e');
        }
      }
    }());

    return completer.future;
  }

  /// 每次拉流新建空用户目录，效果接近浏览器无痕：新 did、无历史 Cookie。
  static Future<String> _freshIncognitoProfile() async {
    final root = await getTemporaryDirectory();
    final base = Directory(p.join(root.path, 'kmxzs_ks_incognito'));
    await base.create(recursive: true);
    final dir = Directory(
      p.join(base.path, '${DateTime.now().microsecondsSinceEpoch}'),
    );
    await dir.create(recursive: true);
    unawaited(_sweepOldIncognito(base.path, keep: dir.path));
    return dir.path;
  }

  static Future<void> _sweepOldIncognito(String base, {required String keep}) async {
    try {
      final parent = Directory(base);
      if (!await parent.exists()) return;
      await for (final e in parent.list()) {
        if (p.equals(e.path, keep)) continue;
        try {
          await e.delete(recursive: true);
        } catch (_) {}
      }
    } catch (_) {}
  }

  static void _wipeProfileLater(String path) {
    unawaited(() async {
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(Duration(seconds: i == 0 ? 2 : 1));
        try {
          final d = Directory(path);
          if (!await d.exists()) return;
          await d.delete(recursive: true);
          return;
        } catch (_) {}
      }
    }());
  }

  static String _roomId(String input) {
    final m =
        RegExp(r'live\.kuaishou\.com/u/([A-Za-z0-9_\-]+)').firstMatch(input);
    if (m != null) return m.group(1)!;
    return input.trim().split(RegExp(r'[/?#]')).last;
  }

  /// 只取当前房间：author.id 对得上，或地址栏已是该房间时的 activeIndex。
  static List<String> pickCurrentRoomUrls({
    required String rid,
    required String href,
    required List<({String principalId, List<String> urls})> items,
    int activeIndex = 0,
    List<String> extraUrls = const [],
  }) {
    final r = rid.trim().toLowerCase();
    if (r.isEmpty) return const [];
    for (final it in items) {
      if (it.principalId.trim().toLowerCase() == r && it.urls.isNotEmpty) {
        return it.urls;
      }
    }
    if (hrefIsTargetRoom(href, rid) && items.isNotEmpty) {
      final i = activeIndex.clamp(0, items.length - 1);
      final active = items[i];
      final pid = active.principalId.trim().toLowerCase();
      if (active.urls.isNotEmpty && (pid.isEmpty || pid == r)) {
        return active.urls;
      }
    }
    if (hrefIsTargetRoom(href, rid)) {
      final extra = extraUrls
          .map((u) => u.trim())
          .where((u) => u.startsWith('http'))
          .toList();
      if (extra.isNotEmpty) return extra;
    }
    return const [];
  }

  /// 数字用户 ID 和房间短号不是一类，不能当成「进错房间」。
  static bool principalMatchesRoom(String principalId, String rid) {
    final p = principalId.trim().toLowerCase();
    final r = rid.trim().toLowerCase();
    if (p.isEmpty || r.isEmpty) return true;
    if (p == r) return true;
    if (p.contains(r) || r.contains(p)) return true;
    final pDigit = RegExp(r'^\d+$').hasMatch(p);
    final rDigit = RegExp(r'^\d+$').hasMatch(r);
    if (pDigit != rDigit) return true;
    return false;
  }

  static bool hrefIsTargetRoom(String href, String rid) {
    final id = rid.trim();
    if (id.isEmpty) return false;
    final h = href.toLowerCase();
    final r = Uri.encodeComponent(id).toLowerCase();
    final raw = id.toLowerCase();
    if (h.contains('/u/$raw') || h.contains('/u/$r')) return true;
    if (h.contains('principalid=$raw') || h.contains('principalid=$r')) {
      return true;
    }
    return false;
  }

  static ({
    String href,
    bool captcha,
    int activeIndex,
    String activeError,
    List<({String principalId, List<String> urls})> items,
    List<String> hooked,
    List<String> perf,
  })? _parseProbe(String? raw) {
    if (raw == null) return null;
    var s = raw.trim();
    if (s.isEmpty || s == 'null' || s == 'undefined') return null;
    if (s.startsWith('"') && s.endsWith('"')) {
      try {
        s = jsonDecode(s) as String;
      } catch (_) {
        s = s.substring(1, s.length - 1).replaceAll(r'\"', '"');
      }
    }
    try {
      final map = jsonDecode(s);
      if (map is! Map) return null;
      List<String> asUrls(dynamic v) {
        final out = <String>[];
        if (v is List) {
          for (final u in v) {
            final t = '$u'.trim();
            if (t.startsWith('http')) out.add(t);
          }
        }
        return out;
      }

      final items = <({String principalId, List<String> urls})>[];
      final rawItems = map['items'];
      if (rawItems is List) {
        for (final it in rawItems) {
          if (it is! Map) continue;
          items.add((
            principalId: '${it['principalId'] ?? ''}',
            urls: asUrls(it['urls']),
          ));
        }
      }
      return (
        href: '${map['href'] ?? ''}',
        captcha: map['captcha'] == true,
        activeIndex: (map['activeIndex'] is int)
            ? map['activeIndex'] as int
            : int.tryParse('${map['activeIndex'] ?? 0}') ?? 0,
        activeError: '${map['activeError'] ?? ''}',
        items: items,
        hooked: asUrls(map['hooked']),
        perf: asUrls(map['perf']),
      );
    } catch (e) {
      debugPrint('[ks-pull] parse probe: $e');
      return null;
    }
  }
}
