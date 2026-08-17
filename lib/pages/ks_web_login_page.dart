import 'dart:async';
import 'dart:io';

import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../services/flv_extractor.dart';
import '../services/webview2_runtime.dart';

/// 用独立原生 WebView2 窗口登录快手（非 Flutter 纹理合成，速度接近系统浏览器）。
class KsWebLoginPage {
  KsWebLoginPage._();

  // 轻量登录页（登录后回调到直播站，便于下发 live.web_st）
  static const passportUrl =
      'https://passport.kuaishou.com/pc/account/login/?sid=kuaishou.live.web'
      '&callback=https%3A%2F%2Flive.kuaishou.com%2F';

  static const liveHomeUrl = 'https://live.kuaishou.com/';

  /// 与拉流共用同一份 WebView2 用户目录，登录态/滑块通过后才能被房间页继承。
  static Future<String> profilePath() async {
    final dir = await getApplicationSupportDirectory();
    return p.join(dir.path, 'webview_ks_native');
  }

  /// 打开原生浏览器窗口登录；成功返回 Cookie，取消返回 null。
  static Future<String?> open(BuildContext context) async {
    final available = await WebviewWindow.isWebviewAvailable();
    if (!available) {
      if (context.mounted) {
        await WebView2Runtime.showMissingDialog(context);
      }
      return null;
    }

    final profile = await profilePath();
    // 每次重新登录都清掉上次会话，避免「未操作就判定已登录」
    await _resetProfile(profile);

    late final Webview webview;
    try {
      webview = await WebviewWindow.create(
        configuration: CreateConfiguration(
          title: '登录快手账号',
          windowWidth: 1100,
          windowHeight: 780,
          titleBarHeight: 40,
          userDataFolderWindows: profile,
          openMaximized: true,
        ),
      );
    } catch (e) {
      if (context.mounted) {
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('无法打开登录窗口'),
            content: Text('$e'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('关闭'),
              ),
            ],
          ),
        );
      }
      return null;
    }

    final completer = Completer<String?>();
    var settled = false;
    var reachedLiveHome = false;
    BuildContext? tipCtx;

    void dismissTip() {
      final c = tipCtx;
      if (c != null && c.mounted) {
        Navigator.of(c).pop();
      }
      tipCtx = null;
    }

    void finish(String? cookie) {
      if (settled) return;
      settled = true;
      dismissTip();
      try {
        webview.close();
      } catch (_) {
        // 窗口可能已被用户手动关闭，close 报错可安全忽略
      }
      // 保存前统一再过一次清洗，禁止把 \0/控制字符写进 Cookie 头
      final safe = cookie == null ? null : FlvExtractor.sanitizeCookieHeader(cookie);
      if (!completer.isCompleted) completer.complete(safe);
    }

    Future<({String header, List<String> names, int count})> readCookies()
        async {
      List nativeCookies = const [];
      try {
        nativeCookies = await webview.getAllCookies();
      } catch (_) {
        // 读不到原生 Cookie 时降级用 document.cookie，可安全忽略
      }
      final fromJs = await _documentCookie(webview);
      final merged = _mergeCookies(nativeCookies, fromJs);
      final header = _toHeader(merged);
      final names = merged
          .map((e) => (e['name'] ?? '').trim())
          .where((n) => n.isNotEmpty)
          .toList();
      return (header: header, names: names, count: merged.length);
    }

    Future<({String header, List<String> names, int count})> collect({
      bool goLive = false,
    }) async {
      if (goLive) {
        try {
          webview.launch(liveHomeUrl, triggerOnUrlRequestEvent: false);
        } catch (_) {
          // 跳转失败不影响后续读取已存 Cookie，可安全忽略
        }
        await _waitNavigatingDone(webview);
        // 真实拉流需要 live.kuaishou.com 下发的 HttpOnly `kuaishou.live.web_st`，
        // document.cookie 读不到，必须轮询 getAllCookies。最长等约 15 秒，
        // 一旦出现强登录态立即返回；超时则返回当前已收集的 Cookie。
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (DateTime.now().isBefore(deadline)) {
          final r = await readCookies();
          if (_isStrongLogin(r.header, r.names)) return r;
          await Future.delayed(const Duration(milliseconds: 500));
        }
        return readCookies();
      }
      return readCookies();
    }

    // 不再启动时就轮询：避免残留/访客 Cookie 被误判后立刻关窗。
    // 仅在主框真正跳到直播站后，用严格规则自动保存。
    webview.onClose.whenComplete(() {
      finish(null);
    });

    webview.setOnUrlRequestCallback((url) {
      if (!_isLiveHomeNavigation(url)) return true;
      reachedLiveHome = true;
      Future.delayed(const Duration(milliseconds: 500), () async {
        // 主框已落到直播站后，轮询等 HttpOnly `kuaishou.live.web_st` 下发，
        // 出现即自动保存；长时间没出现时由「我已登录」按钮兜底。
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (DateTime.now().isBefore(deadline)) {
          if (settled) return;
          try {
            final r = await readCookies();
            if (_isStrongLogin(r.header, r.names)) {
              finish(r.header);
              return;
            }
          } catch (_) {
            // 自动保存失败由「我已登录」按钮兜底，这里静默忽略
          }
          await Future.delayed(const Duration(milliseconds: 500));
        }
      });
      return true;
    });

    try {
      await webview.setApplicationNameForUserAgent(' kmxzs/1.0');
    } catch (_) {
      // 非关键装饰性设置，失败不影响登录流程
    }
    webview.launch(passportUrl);

    if (!context.mounted) {
      finish(null);
      return completer.future;
    }

    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        tipCtx = ctx;
        return AlertDialog(
          title: const Text('请在弹出窗口中登录'),
          content: const Text(
            '已打开登录窗口。\n'
            '请完成扫码或短信登录，等页面跳到快手直播后再点「我已登录」。',
          ),
          actions: [
            TextButton(
              onPressed: () => finish(null),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () async {
                try {
                  final r = await collect(goLive: true);
                  // 必须出现 live 域下发的 HttpOnly `kuaishou.live.web_st` 才算成功，
                  // userId/passToken 只是通行证 Cookie，不能用于拉流。
                  if (_isStrongLogin(r.header, r.names)) {
                    finish(r.header);
                    return;
                  }

                  if (!ctx.mounted) return;
                  await showDialog<void>(
                    context: ctx,
                    builder: (dCtx) => AlertDialog(
                      title: const Text('还没有登录成功'),
                      content: Text(
                        reachedLiveHome
                            ? '还没有检测到登录。请确认弹出窗口右上角已显示头像，然后再点「我已登录」。'
                            : '请先在弹出窗口完成登录，等页面跳到快手直播后再点「我已登录」。',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(dCtx),
                          child: const Text('再试一次'),
                        ),
                      ],
                    ),
                  );
                } catch (e) {
                  if (ctx.mounted) {
                    await showDialog<void>(
                      context: ctx,
                      builder: (dCtx) => AlertDialog(
                        title: const Text('读取失败'),
                        content: Text('$e'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(dCtx),
                            child: const Text('关闭'),
                          ),
                        ],
                      ),
                    );
                  }
                }
              },
              child: const Text('我已登录'),
            ),
          ],
        );
      },
    ));

    return completer.future;
  }

  /// 清掉 WebView2 用户目录，去掉上次残留会话。
  static Future<void> _resetProfile(String profile) async {
    final d = Directory(profile);
    if (await d.exists()) {
      try {
        await d.delete(recursive: true);
      } catch (_) {
        // 个别文件可能被 WebView2 占用，属尽力而为的清理，可安全忽略
        try {
          await for (final entity in d.list(followLinks: false)) {
            try {
              await entity.delete(recursive: true);
            } catch (_) {
              // 单文件删除失败同样尽力而为，继续清理其它子项
            }
          }
        } catch (_) {
          // 目录枚举失败则放弃清理，不影响登录
        }
      }
    }
    await Directory(profile).create(recursive: true);
  }

  /// 主框导航到直播站首页/站内页（排除 passport 回调参数误伤）。
  static bool _isLiveHomeNavigation(String url) {
    final u = url.trim().toLowerCase();
    if (u.contains('passport.kuaishou.com')) return false;
    if (u.contains('id.kuaishou.com')) return false;
    final uri = Uri.tryParse(u);
    if (uri == null) return false;
    final host = uri.host;
    return host == 'live.kuaishou.com' || host.endsWith('.live.kuaishou.com');
  }

  static Future<void> _waitNavigatingDone(Webview webview) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    await Future.delayed(const Duration(milliseconds: 300));
    while (DateTime.now().isBefore(deadline)) {
      try {
        if (!webview.isNavigating.value) break;
      } catch (_) {
        // 读不到导航状态按"已就绪"处理，直接跳出等待循环
        break;
      }
      await Future.delayed(const Duration(milliseconds: 150));
    }
  }

  static Future<String> _documentCookie(Webview webview) async {
    try {
      final raw = await webview.evaluateJavaScript('document.cookie');
      if (raw == null) return '';
      var s = raw.trim();
      if (s.startsWith('"') && s.endsWith('"')) {
        s = s.substring(1, s.length - 1).replaceAll(r'\"', '"');
      }
      return s;
    } catch (e) {
      // 读不到 document.cookie 返回空串，调用方会尝试原生 Cookie；留日志便于排查登录态问题
      debugPrint('[ks-login] 读取 document.cookie 失败: $e');
      return '';
    }
  }

  static List<Map<String, String>> _mergeCookies(
    List nativeCookies,
    String documentCookie,
  ) {
    final map = <String, Map<String, String>>{};

    int domainScore(String d) {
      final x = d.toLowerCase();
      if (x.contains('live.kuaishou')) return 3;
      if (x.contains('kuaishou')) return 2;
      return 1;
    }

    void put(String rawName, String rawValue, String domain) {
      final name = _sanitizeCookiePart(rawName);
      final value = _sanitizeCookiePart(rawValue);
      if (name.isEmpty) return;
      final d = _sanitizeCookiePart(domain);
      // 同名时优先 live.kuaishou.com 域、再非空更长的值
      // （document.cookie 常比带 \0 的原生值干净）
      final prev = map[name];
      if (prev == null) {
        map[name] = {'name': name, 'value': value, 'domain': d};
        return;
      }
      if (value.isEmpty) return;
      final prevDomain = prev['domain'] ?? '';
      final dom = domainScore(d).compareTo(domainScore(prevDomain));
      final prevLen = prev['value']?.length ?? 0;
      if (dom > 0 || (dom == 0 && value.length > prevLen)) {
        map[name] = {'name': name, 'value': value, 'domain': d};
      }
    }

    for (final c in nativeCookies) {
      put(
        '${(c as dynamic).name}',
        '${(c as dynamic).value}',
        '${(c as dynamic).domain}',
      );
    }
    for (final part in documentCookie.split(';')) {
      final t = part.trim();
      if (t.isEmpty) continue;
      final i = t.indexOf('=');
      if (i <= 0) continue;
      put(t.substring(0, i), t.substring(i + 1), '');
    }
    return map.values.toList();
  }

  /// WebView2/插件偶发在 name/value 末尾带 \u0000，会导致 HTTP 头非法。
  static String _sanitizeCookiePart(String raw) {
    return raw
        .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '')
        .replaceAll(RegExp(r'[\u200b-\u200d\ufeff]'), '')
        .trim();
  }

  /// 名称规范化：去空白/零宽字符，点统一成 ASCII。
  static String _normName(String raw) {
    return _sanitizeCookiePart(raw)
        .toLowerCase()
        .replaceAll('．', '.')
        .replaceAll('。', '.')
        .trim();
  }

  /// 真正的快手直播登录态：live/server 域下发的 HttpOnly `kuaishou.live.web_st`
  /// 或 `kuaishou.server.web_st`。userId / passToken 只是 passport 通行证 Cookie，
  /// 不代表 live 拉流已授权，不能当成功。
  static bool _looksLikeKsSession(List names) {
    final norms = names.map((e) => _normName('$e')).toList();
    return norms.any(
      (n) => n.contains('kuaishou.live.web_st') || n.contains('kuaishou.server.web_st'),
    );
  }

  /// 登录态判定：Cookie 头或名称里必须出现 live/server 域下发的 web_st。
  static bool _isStrongLogin(String header, List names) {
    if (_looksLikeKsSession(names)) return true;
    final c = _normName(header).toLowerCase();
    // _toHeader 已过滤空值，这里能进头就说明值非空
    return c.contains('kuaishou.live.web_st=') ||
        c.contains('kuaishou.server.web_st=');
  }

  static String _toHeader(List<Map<String, String>> cookies) {
    final ranked = [...cookies]..sort((a, b) {
        int score(Map<String, String> c) {
          final d = (c['domain'] ?? '').toLowerCase();
          if (d.contains('live.kuaishou')) return 3;
          if (d.contains('kuaishou')) return 2;
          return 1;
        }

        return score(b).compareTo(score(a));
      });
    final map = <String, String>{};
    for (final c in ranked) {
      final name = _sanitizeCookiePart(c['name'] ?? '');
      if (name.isEmpty) continue;
      final value = _sanitizeCookiePart(c['value'] ?? '');
      map.putIfAbsent(name, () => value);
    }
    return map.entries
        .where((e) => e.value.isNotEmpty)
        .map((e) => '${e.key}=${e.value}')
        .join('; ');
  }

  /// 清洗已保存的 Cookie 头（供外部对历史脏数据调用）。
  static String sanitizeCookieHeader(String raw) {
    final cleaned = _sanitizeCookiePart(raw);
    if (cleaned.isEmpty) return '';
    final map = <String, String>{};
    for (final part in cleaned.split(';')) {
      final t = part.trim();
      if (t.isEmpty) continue;
      final i = t.indexOf('=');
      if (i <= 0) continue;
      final name = _sanitizeCookiePart(t.substring(0, i));
      final value = _sanitizeCookiePart(t.substring(i + 1));
      if (name.isEmpty || value.isEmpty) continue;
      map[name] = value;
    }
    return map.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }
}
