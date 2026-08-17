import 'dart:io';

import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

/// 检测 / 安装 Microsoft Edge WebView2 运行时。
///
/// 安装包只附带约 1.7MB 官方引导程序；本机没有运行时时，由引导程序从微软 CDN
/// 拉取完整组件（国内直连已测通）。也可在软件内点「立即安装」。
abstract final class WebView2Runtime {
  static const downloadPage =
      'https://go.microsoft.com/fwlink/p/?LinkId=2124703';

  static const setupFileName = 'MicrosoftEdgeWebview2Setup.exe';

  static Future<bool> isAvailable() => WebviewWindow.isWebviewAvailable();

  /// 安装目录 `redist/MicrosoftEdgeWebview2Setup.exe`（官方引导程序）。
  static File? bundledSetup() {
    final dir = File(Platform.resolvedExecutable).parent.path;
    final f = File(p.join(dir, 'redist', setupFileName));
    return f.existsSync() ? f : null;
  }

  static Future<bool> installSilent() async {
    final setup = bundledSetup();
    if (setup == null) return false;
    final r = await Process.run(
      setup.path,
      const ['/silent', '/install', '/norestart'],
      runInShell: false,
    );
    return r.exitCode == 0;
  }

  /// 缺少运行时时弹窗：用安装包自带的官方引导程序安装。
  static Future<void> showMissingDialog(BuildContext context) async {
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('需要安装 WebView2'),
        content: const Text(
          '快手登录和拉流需要 Microsoft Edge WebView2 运行时。\n'
          '这是微软官方组件，部分精简版 Windows 不会预装。\n\n'
          '点「立即安装」会用安装包自带的官方引导程序自动安装（当前用户，一般不用管理员）。'
          '装完后请完全退出本软件再打开。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('稍后'),
          ),
          TextButton(
            onPressed: () async {
              await launchUrl(Uri.parse(downloadPage));
            },
            child: const Text('打开下载页'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              if (!context.mounted) return;
              await _runInstall(context);
            },
            child: const Text('立即安装'),
          ),
        ],
      ),
    );
  }

  static Future<void> _runInstall(BuildContext context) async {
    if (bundledSetup() == null) {
      await launchUrl(Uri.parse(downloadPage));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('未找到自带安装程序，已打开微软下载页')),
        );
      }
      return;
    }
    if (context.mounted) {
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => const AlertDialog(
          content: Row(
            children: [
              CircularProgressIndicator(),
              SizedBox(width: 16),
              Expanded(child: Text('正在安装 WebView2，请稍候…')),
            ],
          ),
        ),
      );
    }
    var ok = false;
    try {
      ok = await installSilent();
    } catch (_) {
      ok = false;
    }
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ok ? '安装完成' : '安装未完成'),
        content: Text(
          ok
              ? '请完全退出快马小助手后再打开，即可登录快手。'
              : '自动安装失败。请点「打开下载页」手动安装，或检查网络后重试。',
        ),
        actions: [
          if (!ok)
            TextButton(
              onPressed: () => launchUrl(Uri.parse(downloadPage)),
              child: const Text('打开下载页'),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }
}
