import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:kmxzs/app_version.dart';
import 'package:kmxzs/models/api_models.dart';
import 'package:kmxzs/services/api.dart';
import 'package:kmxzs/services/updater.dart';
import 'package:url_launcher/url_launcher.dart';

/// 登录页与主页共用：发现新版本后后台下载并静默安装。
class UpdatePrompt {
  static bool _sessionHandled = false;

  static Future<void> check(BuildContext context, Api api) async {
    try {
      final cfg = await api.loadConfig();
      if (!context.mounted) return;
      await showIfNeeded(context, api, cfg);
    } catch (e) {
      // 更新检查失败必须留日志，避免静默错过客户端关键升级
      debugPrint('[update] 更新检查失败: $e');
    }
  }

  static Future<void> showIfNeeded(
    BuildContext context,
    Api api,
    AppRemoteConfig cfg,
  ) async {
    if (_sessionHandled) return;
    final latest = (cfg.version ?? '').trim();
    final belowMin = cfg.minVersion != null &&
        cfg.minVersion!.isNotEmpty &&
        AppVersion.isOlderThan(cfg.minVersion!);
    final hasUpdate = latest.isNotEmpty && AppVersion.isOlderThan(latest);
    // 修复：仅配置 minVersion（无 version）时也要能触发强更
    if (latest.isEmpty &&
        (cfg.minVersion == null || cfg.minVersion!.isEmpty)) {
      return;
    }
    if (!hasUpdate && !belowMin) return;
    if (!context.mounted) return;
    _sessionHandled = true;
    final force = cfg.forceUpdate || belowMin;
    await showDialog<void>(
      context: context,
      barrierDismissible: !force,
      builder: (_) => _SilentUpdateDialog(
        api: api,
        cfg: cfg,
        latest: latest,
        force: force,
        belowMin: belowMin,
      ),
    );
  }
}

class _SilentUpdateDialog extends StatefulWidget {
  const _SilentUpdateDialog({
    required this.api,
    required this.cfg,
    required this.latest,
    required this.force,
    required this.belowMin,
  });

  final Api api;
  final AppRemoteConfig cfg;
  final String latest;
  final bool force;
  final bool belowMin;

  @override
  State<_SilentUpdateDialog> createState() => _SilentUpdateDialogState();
}

class _SilentUpdateDialogState extends State<_SilentUpdateDialog> {
  final _updater = AppUpdater();
  final _cancel = CancelToken();

  bool _downloading = false;
  bool _applying = false;
  String? _error;
  int _received = 0;
  int _total = 0;

  @override
  void initState() {
    super.initState();
    if (widget.force) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _start());
    }
  }

  @override
  void dispose() {
    if (!_applying && !_cancel.isCancelled) {
      _cancel.cancel('closed');
    }
    super.dispose();
  }

  Future<void> _start() async {
    if (_downloading || _applying) return;
    setState(() {
      _downloading = true;
      _error = null;
      _received = 0;
      _total = widget.cfg.downloadSize ?? 0;
    });
    try {
      final file = await _updater.download(
        url: widget.api.latestInstallerUrl(widget.latest),
        version: widget.latest,
        expectedSize: widget.cfg.downloadSize,
        cancelToken: _cancel,
        onProgress: (r, t) {
          if (!mounted) return;
          setState(() {
            _received = r;
            _total = t > 0 ? t : (widget.cfg.downloadSize ?? 0);
          });
        },
      );
      // 阶段3：先验签再安装，防投毒；失败抛错由下方 catch 展示
      await _updater.verifyPackage(
        file,
        sha256: widget.cfg.downloadSha256,
        signature: widget.cfg.downloadSig,
      );
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _applying = true;
      });
      await _updater.applySilent(file);
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) return;
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _applying = false;
        _error = '下载失败，请检查网络后重试';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _applying = false;
        _error = e.toString().replaceFirst('StateError: ', '');
      });
    }
  }

  Future<void> _openBrowser() async {
    final url = widget.api.latestInstallerUrl(widget.latest);
    await launchUrl(Uri.parse(url));
  }

  String get _progressLabel {
    if (_applying) return '正在安装，软件即将重启…';
    if (!_downloading) return '';
    final rec = _received / (1024 * 1024);
    if (_total > 0) {
      final tot = _total / (1024 * 1024);
      final pct = (_received / _total * 100).clamp(0, 100).toStringAsFixed(0);
      return '正在下载 $pct%（${rec.toStringAsFixed(1)} / ${tot.toStringAsFixed(1)} MB）';
    }
    return '正在下载 ${rec.toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final busy = _downloading || _applying;
    return AlertDialog(
      title: Text(widget.force ? '需要更新' : '发现新版本'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '当前版本 ${AppVersion.name}\n最新版本 ${widget.latest.isEmpty ? (widget.cfg.minVersion ?? '') : widget.latest}'
            '\n将自动下载并静默安装，完成后自动重启。'
            '${widget.belowMin ? '\n低于最低可用版本 ${widget.cfg.minVersion}' : ''}'
            '${widget.force ? '\n请更新后继续使用' : ''}',
          ),
          if (busy) ...[
            const SizedBox(height: 16),
            LinearProgressIndicator(
              value: _applying
                  ? null
                  : (_total > 0 ? (_received / _total).clamp(0.0, 1.0) : null),
            ),
            const SizedBox(height: 8),
            Text(_progressLabel, style: Theme.of(context).textTheme.bodySmall),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ],
      ),
      actions: [
        if (!widget.force && !busy)
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('稍后'),
          ),
        if (!busy)
          TextButton(
            onPressed: _start,
            child: Text(_error == null ? '立即更新' : '重试'),
          ),
        if (_error != null && !busy)
          TextButton(
            onPressed: _openBrowser,
            child: const Text('浏览器下载'),
          ),
      ],
    );
  }
}
