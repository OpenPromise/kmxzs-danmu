import 'dart:async';
import 'dart:io';

import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 用独立原生 WebView2 窗口登录快手（非 Flutter 纹理合成，速度接近系统浏览器）。
class KsWebLoginPage {
  KsWebLoginPage._();

  // 轻量登录页（登录后回调到直播站，便于下发 live.web_st）
  static const passportUrl =
      'https://passport.kuaishou.com/pc/account/login/?sid=kuaishou.live.web'
      '&callback=https%3A%2F%2Flive.kuaishou.com%2F';

  static const liveHomeUrl = 'https://live.kuaishou.com/';

  /// 打开原生浏览器窗口登录；成功返回 Cookie，取消返回 null。
  static Future<String?> open(BuildContext context) async {
    final available = await WebviewWindow.isWebviewAvailable();
    if (!available) {
      if (context.mounted) {
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('缺少 WebView2'),
            content: const Text(
              '本机未安装 Microsoft Edge WebView2 运行时，无法打开登录窗口。\n'
              '请安装后重试：\n'
              'https://developer.microsoft.com/microsoft-edge/webview2/',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('知道了'),
              ),
            ],
          ),
        );
      }
      return null;
    }

    final dir = await getApplicationSupportDirectory();
    final profile = p.join(dir.path, 'webview_ks_native');
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
      } catch (_) {}
      if (!completer.isCompleted) completer.complete(cookie);
    }

    Future<({String header, List<String> names, int count})> collect({
      bool goLive = false,
    }) async {
      if (goLive) {
        try {
          webview.launch(liveHomeUrl, triggerOnUrlRequestEvent: false);
        } catch (_) {}
        await _waitNavigatingDone(webview);
        await Future.delayed(const Duration(milliseconds: 1800));
      }

      List nativeCookies = const [];
      try {
        nativeCookies = await webview.getAllCookies();
      } catch (_) {}
      final fromJs = await _documentCookie(webview);
      final merged = _mergeCookies(nativeCookies, fromJs);
      final header = _toHeader(merged);
      final names = merged
          .map((e) => (e['name'] ?? '').trim())
          .where((n) => n.isNotEmpty)
          .toList();
      return (header: header, names: names, count: merged.length);
    }

    // 不再启动时就轮询：避免残留/访客 Cookie 被误判后立刻关窗。
    // 仅在主框真正跳到直播站后，用严格规则自动保存。
    webview.onClose.whenComplete(() {
      finish(null);
    });

    webview.setOnUrlRequestCallback((url) {
      if (!_isLiveHomeNavigation(url)) return true;
      reachedLiveHome = true;
      Future.delayed(const Duration(milliseconds: 2000), () async {
        if (settled) return;
        try {
          final r = await collect(goLive: false);
          if (_isStrongLogin(r.header, r.names)) {
            finish(r.header);
          }
        } catch (_) {}
      });
      return true;
    });

    try {
      await webview.setApplicationNameForUserAgent(' kmxzs/1.0');
    } catch (_) {}
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
            '已打开独立浏览器窗口（已清除旧登录态）。\n'
            '请完成扫码/短信登录，等页面自动跳到直播站后，再点「我已登录」。\n'
            '跳到直播站且检测到真实登录 Cookie 时，也会自动保存。',
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
                  // 你截图里这种 userId + passToken + web_st 直接视为成功
                  if (_isStrongLogin(r.header, r.names) ||
                      _looksLikeKsSession(r.names)) {
                    finish(r.header);
                    return;
                  }

                  if (!ctx.mounted) return;
                  await showDialog<void>(
                    context: ctx,
                    builder: (dCtx) => AlertDialog(
                      title: const Text('尚未检测到登录态'),
                      content: Text(
                        r.count == 0
                            ? '未读到任何 Cookie。\n\n'
                                '请先在弹出窗口完成登录，等地址栏变为 '
                                'live.kuaishou.com 后再点「我已登录」。'
                            : '已读到 ${r.count} 个 Cookie，但还不是登录态'
                                '${reachedLiveHome ? '' : '（尚未跳到直播站）'}：\n'
                                '${r.names.take(16).join(', ')}'
                                '${r.names.length > 16 ? '…' : ''}\n\n'
                                '请完成登录并等待跳转后再试。\n'
                                '若右上角已显示头像，可点「仍要保存」。',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(dCtx),
                          child: const Text('再试一次'),
                        ),
                        if (r.count > 0)
                          FilledButton(
                            onPressed: () {
                              Navigator.pop(dCtx);
                              finish(r.header);
                            },
                            child: const Text('仍要保存'),
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
        // 个别文件可能被占用，尽量删子项
        try {
          await for (final entity in d.list(followLinks: false)) {
            try {
              await entity.delete(recursive: true);
            } catch (_) {}
          }
        } catch (_) {}
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
    } catch (_) {
      return '';
    }
  }

  static List<Map<String, String>> _mergeCookies(
    List nativeCookies,
    String documentCookie,
  ) {
    final map = <String, Map<String, String>>{};

    void put(String rawName, String rawValue, String domain) {
      final name = _sanitizeCookiePart(rawName);
      final value = _sanitizeCookiePart(rawValue);
      if (name.isEmpty) return;
      // 同名时优先保留更长的非空值（document.cookie 常比带 \0 的原生值干净）
      final prev = map[name];
      if (prev == null ||
          (value.length > (prev['value']?.length ?? 0) && value.isNotEmpty)) {
        map[name] = {
          'name': name,
          'value': value,
          'domain': _sanitizeCookiePart(domain),
        };
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

  /// 截图场景：同时有 userId、passToken，或任意 web_st / web_ph。
  static bool _looksLikeKsSession(List names) {
    final norms = names.map((e) => _normName('$e')).toList();
    final blob = norms.join('|');
    final hasUser = norms.any((n) => n == 'userid' || n.endsWith('userid'));
    final hasPass =
        norms.any((n) => n == 'passtoken' || n.contains('passtoken'));
    final hasSt = blob.contains('web_st') || blob.contains('api_st');
    final hasPh = blob.contains('web_ph') || blob.contains('api_ph');
    if (hasSt) return true;
    if (hasUser && hasPass) return true;
    if (hasUser && hasPh) return true;
    return false;
  }

  /// 登录态：live/server st，或 userId+passToken（名称用包含匹配，避免不可见字符）。
  static bool _isStrongLogin(String header, List names) {
    if (_looksLikeKsSession(names)) return true;

    final c = _normName(header);
    if (c.contains('kuaishou.live.web_st') ||
        c.contains('kuaishou.server.web_st') ||
        c.contains('web_st=')) {
      return true;
    }
    final hasUser = c.contains('userid=');
    final hasPass = c.contains('passtoken=');
    return hasUser && hasPass;
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
