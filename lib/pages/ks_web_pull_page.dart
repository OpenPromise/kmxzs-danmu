import 'dart:async';
import 'dart:convert';

import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter/material.dart';
import 'package:kmxzs/pages/ks_web_login_page.dart';
import 'package:kmxzs/services/flv_extractor.dart';
import 'package:kmxzs/services/webview2_runtime.dart';

/// 用登录时同一套 WebView2 会话打开快手房间页取流。
///
/// Dio 直连会被快手当成机器人，页面返回「请完成滑块验证」且没有 playUrls。
/// 真实 Chromium 里用户拖完滑块后，页面才会写入 FLV 地址。
class KsWebPullPage {
  KsWebPullPage._();

  static const _probeJs = r'''
(function () {
  function walk(node, out, skipHevc) {
    if (!node) return;
    if (typeof node === 'string') {
      if (/^https?:/i.test(node) && /(\.flv|m3u8|pull-flv|pull-hls)/i.test(node)) {
        out.push(node);
      }
      return;
    }
    if (Array.isArray(node)) {
      for (var i = 0; i < node.length; i++) walk(node[i], out, skipHevc);
      return;
    }
    if (typeof node !== 'object') return;
    if (skipHevc) {
      var h264 = node.playUrls && node.playUrls.h264;
      var adapt = h264 && h264.adaptationSet;
      var reps = adapt && adapt.representation;
      if (Array.isArray(reps)) {
        for (var j = 0; j < reps.length; j++) {
          var r = reps[j] || {};
          if (r.url) out.push(String(r.url));
          if (r.backupUrl) out.push(String(r.backupUrl));
        }
      }
    }
    for (var k in node) {
      if (!Object.prototype.hasOwnProperty.call(node, k)) continue;
      if (skipHevc && /hevc|h265|av1/i.test(k)) continue;
      walk(node[k], out, skipHevc);
    }
  }
  var urls = [];
  try { walk(window.__INITIAL_STATE__, urls, true); } catch (e) {}
  try {
    document.querySelectorAll('video').forEach(function (v) {
      var s = v.currentSrc || v.src;
      if (s) urls.push(s);
    });
  } catch (e) {}
  var html = '';
  try { html = document.documentElement ? document.documentElement.innerText : ''; } catch (e) {}
  var hasSlider = /滑块|请完成验证|拖动完成|浏览其他内容/.test(html);
  return JSON.stringify({
    href: String(location.href || ''),
    hasSlider: hasSlider,
    urls: urls
  });
})()
''';

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
    note('正在用浏览器打开快手直播间（出现滑块请拖完）');

    final profile = await KsWebLoginPage.profilePath();
    late final Webview webview;
    try {
      webview = await WebviewWindow.create(
        configuration: CreateConfiguration(
          title: '快手直播间（如出现滑块请拖完）',
          windowWidth: 1100,
          windowHeight: 780,
          titleBarHeight: 40,
          userDataFolderWindows: profile,
          openMaximized: true,
        ),
      );
    } catch (e) {
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
    webview.launch(pageUrl, triggerOnUrlRequestEvent: false);

    if (context.mounted) {
      unawaited(showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          tipCtx = ctx;
          return AlertDialog(
            title: const Text('请在弹出窗口完成验证'),
            content: const Text(
              '已用你登录过的快手浏览器打开直播间。\n'
              '若出现滑块，请在弹出窗口里拖完；通过后软件会自动取流并关掉窗口。\n'
              '不要关窗口太快，等画面里主播出镜或进度走完即可。',
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
      final deadline = DateTime.now().add(const Duration(seconds: 90));
      while (!settled && DateTime.now().isBefore(deadline)) {
        await Future.delayed(const Duration(milliseconds: 800));
        if (settled) return;
        try {
          final raw = await webview.evaluateJavaScript(_probeJs);
          final parsed = _parseProbe(raw);
          if (parsed == null) continue;
          if (parsed.hasSlider && !sliderHinted) {
            sliderHinted = true;
            note('直播间要求滑块验证，请在弹出窗口拖完');
          }
          if (parsed.urls.isNotEmpty) {
            final packed = FlvExtractor().packPlayUrls(
              platform: LivePlatform.kuaishou,
              roomId: rid,
              urls: parsed.urls,
              note: parsed.hasSlider
                  ? '来源: WebView（滑块通过后）'
                  : '来源: WebView 房间页',
            );
            if (packed.ok) {
              note('浏览器取流成功，共 ${packed.allUrls.length} 条');
              finish(packed);
              return;
            }
          }
        } catch (e) {
          debugPrint('[ks-pull] probe: $e');
        }
      }
      if (!settled) {
        finish(
          FlvExtractResult.fail(
            sliderHinted
                ? '等待滑块超时：请在弹出窗口拖完验证后再点一键开始。'
                : '浏览器打开直播间 90 秒内未拿到 FLV。请确认主播正在直播。',
            platform: LivePlatform.kuaishou,
            roomId: rid,
          ),
        );
      }
    }());

    return completer.future;
  }

  static String _roomId(String input) {
    final m =
        RegExp(r'live\.kuaishou\.com/u/([A-Za-z0-9_\-]+)').firstMatch(input);
    if (m != null) return m.group(1)!;
    return input.trim().split(RegExp(r'[/?#]')).last;
  }

  static ({bool hasSlider, List<String> urls})? _parseProbe(String? raw) {
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
      final urls = <String>[];
      final rawUrls = map['urls'];
      if (rawUrls is List) {
        for (final u in rawUrls) {
          final t = '$u'.trim();
          if (t.startsWith('http')) urls.add(t);
        }
      }
      return (
        hasSlider: map['hasSlider'] == true,
        urls: urls,
      );
    } catch (e) {
      debugPrint('[ks-pull] parse probe: $e');
      return null;
    }
  }
}
