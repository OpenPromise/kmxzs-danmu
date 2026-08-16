
import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:kmxzs/pages/login_page.dart';
import 'package:kmxzs/pages/ks_web_login_page.dart';
import 'package:kmxzs/services/api.dart';
import 'package:kmxzs/services/auth.dart';
import 'package:kmxzs/services/flv_extractor.dart';
import 'package:kmxzs/services/mem_optimizer.dart';
import 'package:kmxzs/services/obs_config.dart';
import 'package:kmxzs/services/obs_ws.dart';
import 'package:kmxzs/services/path_finder.dart';
import 'package:kmxzs/services/prefs_keys.dart';
import 'package:kmxzs/app_version.dart';
import 'package:kmxzs/config/app_config.dart';
import 'package:kmxzs/widgets/about.dart';
import 'package:kmxzs/widgets/title_bar.dart';
import 'package:kmxzs/widgets/update_prompt.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 主页：拉流虚拟摄像机模式。
class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.api, required this.auth});

  final Api api;
  final Auth auth;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _pathFinder = PathFinder();
  final _obsConfig = OBSConfig();
  final _obsWs = ObsWs();
  final _flvExtractor = FlvExtractor();

  final _obsPathCtrl = TextEditingController(text: PathFinder.defaultObs);
  final _companionPathCtrl = TextEditingController();
  final _wsUrlCtrl = TextEditingController(text: 'ws://127.0.0.1:4455');
  final _roomUrlCtrl = TextEditingController();
  final _ksCookieCtrl = TextEditingController();
  final _ttCookieCtrl = TextEditingController();

  bool _skipCompanion = false;

  bool _busy = false;
  bool _settingsOpen = false;
  String _status = '未连接';
  String _log = '拉流模式：填写直播间链接后点「一键开始」。';

  bool _memOpt = false;
  bool _autoStopOnMediaEnd = true;

  bool _pullBaseline = false;
  bool _wasPlaying = false;
  bool _memRunning = false;
  DateTime? _lastMemLog;

  Timer? _mediaTimer;
  Timer? _memTimer;
  Timer? _licenseTimer;
  Future<bool>? _licenseInflight;

  String? _notice;
  bool _expiryWarned = false;
  bool _pathSetupShowing = false;

  bool get _showExpiryBanner {
    final h = widget.auth.current?.remainingHours;
    return h != null && h > 0 && h < 24;
  }

  String get _expiryHoursLabel {
    final h = widget.auth.current?.remainingHours;
    if (h == null) return '不足 24 小时';
    return '$h 小时';
  }

  String get _companionPath => _companionPathCtrl.text.trim();

  List<String> get _memOptProcessNames {
    final name = _companionPath.replaceAll('\\', '/').split('/').last;
    if (name.isEmpty) {
      return const [
        'kwailive.exe',
        '直播伴侣.exe',
        'WebcastMate.exe',
        '直播伴侣 Launcher.exe',
        'TikTok LIVE Studio.exe',
        'TikTok LIVE Studio Launcher.exe',
      ];
    }
    return [name];
  }

  bool get _ksLoggedIn =>
      FlvExtractor.hasKuaishouLoginCookie(_ksCookieCtrl.text);

  Future<void> _loginKuaishouAccount({bool fromPullFail = false}) async {
    final cookie = await KsWebLoginPage.open(context);
    if (cookie == null || cookie.trim().isEmpty) {
      if (fromPullFail) _appendLog('已取消快手登录');
      return;
    }
    final cleaned = FlvExtractor.sanitizeCookieHeader(cookie);
    _ksCookieCtrl.text = cleaned;
    await _persist();
    _appendLog('快手账号登录成功，Cookie 已自动保存（${cleaned.length} 字符）');
    if (mounted) {
      _toast('快手登录成功');
      setState(() {});
    }
  }

  Future<void> _clearKuaishouCookie() async {
    _ksCookieCtrl.clear();
    await _persist();
    if (mounted) {
      setState(() {});
      _toast('已退出快手网页登录态');
    }
  }

  Future<void> _maybePromptKuaishouLogin(String failMsg) async {
    final need = failMsg.contains('Cookie') ||
        failMsg.contains('风控') ||
        failMsg.contains('result=2') ||
        failMsg.contains('操作太快');
    if (!need || !mounted) return;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_ksLoggedIn ? '快手需要重新登录' : '需要登录快手账号'),
        content: const Text(
          '快手网页拉流需要登录态。点击「去登录」将打开官方页面，'
          '你完成登录后软件会自动保存 Cookie，无需手动复制。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('稍后'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('去登录'),
          ),
        ],
      ),
    );
    if (go == true && mounted) {
      await _loginKuaishouAccount(fromPullFail: true);
    }
  }

  Future<bool> _pathExists(String path) async {
    final p = path.trim();
    return p.isNotEmpty && await File(p).exists();
  }

  @override
  void initState() {
    super.initState();
    _loadAll();
    _licenseTimer = Timer.periodic(const Duration(minutes: 3), (_) {
      unawaited(_ensureLicense(silent: true));
    });
  }

  @override
  void dispose() {
    _mediaTimer?.cancel();
    _memTimer?.cancel();
    _licenseTimer?.cancel();
    _obsPathCtrl.dispose();
    _companionPathCtrl.dispose();
    _wsUrlCtrl.dispose();
    _roomUrlCtrl.dispose();
    _ksCookieCtrl.dispose();
    _ttCookieCtrl.dispose();
    super.dispose();
  }

  /// 在线验权：过期/掉线强制回登录页。并发调用会共用同一次 /me。
  Future<bool> _ensureLicense({bool silent = false}) {
    final existing = _licenseInflight;
    if (existing != null) return existing;

    final future = () async {
      try {
        await widget.auth.refreshProfile();
        if (!widget.auth.isLicensed) {
          await _forceRelogin('账号已过期，请充值后续费');
          return false;
        }
        if (mounted) setState(() {});
        return true;
      } catch (e) {
        if (!silent) {
          _appendLog('授权校验失败: $e');
        }
        await _forceRelogin('授权校验失败，请重新登录');
        return false;
      } finally {
        _licenseInflight = null;
      }
    }();

    _licenseInflight = future;
    return future;
  }

  Future<void> _forceRelogin(String reason) async {
    _licenseTimer?.cancel();
    await widget.auth.logout();
    if (!mounted) return;
    _toast(reason);
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => LoginPage(api: widget.api, auth: widget.auth),
      ),
      (_) => false,
    );
  }

  void _appendLog(String msg) {
    if (!mounted) return;
    final line = '[${DateTime.now().toString().substring(11, 19)}] $msg';
    setState(() => _log = '$line\n$_log');
  }

  Future<void> _loadAll() async {
    final sp = await SharedPreferences.getInstance();
    final savedObs = sp.getString(PrefsKeys.obsPath)?.trim();
    final savedKwai = sp.getString(PrefsKeys.kwailivePath)?.trim();
    final savedDouyin = sp.getString(PrefsKeys.douyinMatePath)?.trim();
    final savedTiktok = sp.getString(PrefsKeys.tiktokStudioPath)?.trim();
    final hasSavedObs = savedObs != null && savedObs.isNotEmpty;
    var savedCompanion = sp.getString(PrefsKeys.companionPath)?.trim() ?? '';
    if (savedCompanion.isEmpty) {
      for (final c in [savedKwai, savedDouyin, savedTiktok]) {
        if (c != null && c.isNotEmpty) {
          savedCompanion = c;
          break;
        }
      }
    }

    _obsPathCtrl.text = hasSavedObs ? savedObs : PathFinder.defaultObs;
    _companionPathCtrl.text = savedCompanion;
    _skipCompanion = sp.getBool(PrefsKeys.skipCompanion) ?? false;
    _wsUrlCtrl.text = sp.getString(PrefsKeys.obsWsUrl) ?? _wsUrlCtrl.text;
    _roomUrlCtrl.text = sp.getString(PrefsKeys.roomUrl) ?? '';
    final rawKs = sp.getString(PrefsKeys.kuaishouCookie) ?? '';
    final cleanKs = FlvExtractor.sanitizeCookieHeader(rawKs);
    _ksCookieCtrl.text = cleanKs;
    if (cleanKs != rawKs && cleanKs.isNotEmpty) {
      await sp.setString(PrefsKeys.kuaishouCookie, cleanKs);
    }
    _ttCookieCtrl.text = sp.getString(PrefsKeys.tiktokCookie) ?? '';
    _flvExtractor.kuaishouCookie = cleanKs.isEmpty ? null : cleanKs;
    _flvExtractor.tiktokCookie = _ttCookieCtrl.text.trim().isEmpty
        ? null
        : _ttCookieCtrl.text.trim();
    _memOpt = sp.getBool(PrefsKeys.memOpt) ?? false;
    _autoStopOnMediaEnd = sp.getBool(PrefsKeys.autoStopOnMediaEnd) ?? true;

    if (!await _pathExists(_obsPathCtrl.text)) {
      await _detectObsPath(silent: true);
    }
    if (!_skipCompanion && !await _pathExists(_companionPathCtrl.text)) {
      await _detectCompanionPath(silent: true);
    }

    final obsOk = await _pathExists(_obsPathCtrl.text);

    try {
      final cfg = await widget.api.loadConfig();
      _notice = cfg.notice;
      if (mounted) {
        await UpdatePrompt.showIfNeeded(context, widget.api, cfg);
      }
    } catch (_) {}

    try {
      await widget.auth.refreshProfile();
      if (!widget.auth.isLicensed) {
        await _forceRelogin('账号已过期，请充值后续费');
        return;
      }
    } catch (_) {
      await _forceRelogin('授权校验失败，请重新登录');
      return;
    }

    final rem = widget.auth.current?.remainingHours;
    if (rem != null && rem > 0 && rem < 24 && !_expiryWarned) {
      _expiryWarned = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _toast('账号将在 $rem 小时内到期，请及时充值');
      });
    }

    if (_memOpt) _startMemOpt();
    if (mounted) setState(() {});

    // 首次使用或 OBS 无效 → 登录后引导设置（直播伴侣可在一键开始时再选/跳过）
    if (!hasSavedObs || !obsOk) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showPathSetupDialog();
      });
    }
  }

  Future<void> _showPathSetupDialog() async {
    if (!mounted || _pathSetupShowing) return;
    _pathSetupShowing = true;
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          return StatefulBuilder(
            builder: (ctx, setLocal) {
              Future<void> refreshLocal() async {
                setLocal(() {});
                if (mounted) setState(() {});
              }

              return AlertDialog(
                title: const Text('首次使用设置'),
                content: SizedBox(
                  width: 480,
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text(
                          '请设置 OBS 路径。直播伴侣可稍后在「一键开始」时选择，也可跳过由自己手动启动。',
                          style: TextStyle(fontSize: 13, height: 1.4),
                        ),
                        const SizedBox(height: 16),
                        _PathRow(
                          label: 'OBS Studio（obs64.exe）',
                          controller: _obsPathCtrl,
                          onDetect: () async {
                            await _detectObsPath(silent: false);
                            await refreshLocal();
                          },
                          onPick: () async {
                            await _pickObsPath();
                            await refreshLocal();
                          },
                          onChanged: (_) => setLocal(() {}),
                        ),
                        const SizedBox(height: 10),
                        _PathRow(
                          label: '直播伴侣（可选）',
                          controller: _companionPathCtrl,
                          onDetect: () async {
                            await _detectCompanionPath(silent: false);
                            await refreshLocal();
                          },
                          onPick: () async {
                            await _pickCompanionPath();
                            await refreshLocal();
                          },
                          onChanged: (_) => setLocal(() {}),
                        ),
                      ],
                    ),
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('稍后设置'),
                  ),
                  FilledButton(
                    onPressed: () async {
                      final obsOk = await _pathExists(_obsPathCtrl.text);
                      if (!obsOk) {
                        const msg = 'OBS 路径无效，请重新选择 obs64.exe';
                        if (!ctx.mounted) return;
                        ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(
                          const SnackBar(
                            content: Text(msg),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                        if (ScaffoldMessenger.maybeOf(ctx) == null && mounted) {
                          _toast(msg);
                        }
                        return;
                      }
                      await _persist();
                      if (ctx.mounted) Navigator.pop(ctx);
                      _appendLog('已保存软件路径');
                      if (mounted) _toast('路径已保存');
                    },
                    child: const Text('完成'),
                  ),
                ],
              );
            },
          );
        },
      );
    } finally {
      _pathSetupShowing = false;
    }
  }

  Future<void> _persist() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(PrefsKeys.obsPath, _obsPathCtrl.text.trim());
    await sp.setString(PrefsKeys.companionPath, _companionPathCtrl.text.trim());
    await sp.setBool(PrefsKeys.skipCompanion, _skipCompanion);
    if (_companionPathCtrl.text.trim().isNotEmpty) {
      await sp.setString(
        PrefsKeys.kwailivePath,
        _companionPathCtrl.text.trim(),
      );
    }
    await sp.setString(PrefsKeys.obsWsUrl, _wsUrlCtrl.text.trim());
    await sp.setString(PrefsKeys.roomUrl, _roomUrlCtrl.text.trim());
    final cleanKs = FlvExtractor.sanitizeCookieHeader(_ksCookieCtrl.text);
    if (_ksCookieCtrl.text != cleanKs) {
      _ksCookieCtrl.text = cleanKs;
    }
    await sp.setString(PrefsKeys.kuaishouCookie, cleanKs);
    await sp.setString(PrefsKeys.tiktokCookie, _ttCookieCtrl.text.trim());
    _flvExtractor.kuaishouCookie = cleanKs.isEmpty ? null : cleanKs;
    _flvExtractor.tiktokCookie = _ttCookieCtrl.text.trim().isEmpty
        ? null
        : _ttCookieCtrl.text.trim();
    await sp.setBool(PrefsKeys.memOpt, _memOpt);
    await sp.setBool(PrefsKeys.autoStopOnMediaEnd, _autoStopOnMediaEnd);
  }

  Future<void> _detectObsPath({bool silent = false}) async {
    final path = await _pathFinder.detectObsPath();
    if (path == null) {
      if (!silent) _toast('未检测到 OBS Studio，请手动选择 obs64.exe');
      return;
    }
    _obsPathCtrl.text = path;
    await _persist();
    if (!silent) _appendLog('OBS: $path');
    setState(() {});
  }

  Future<void> _detectCompanionPath({bool silent = false}) async {
    final path = await _pathFinder.detectCompanionPath();
    if (path == null) {
      if (!silent) _toast('未检测到直播伴侣，请手动选择可执行文件');
      return;
    }
    _companionPathCtrl.text = path;
    _skipCompanion = false;
    await _persist();
    if (!silent) _appendLog('直播伴侣: $path');
    setState(() {});
  }

  Future<void> _pickObsPath() async {
    final r = await FilePicker.platform.pickFiles(
      dialogTitle: '选择 obs64.exe',
      type: FileType.custom,
      allowedExtensions: ['exe'],
    );
    if (r == null || r.files.single.path == null) return;
    _obsPathCtrl.text = r.files.single.path!;
    await _persist();
    setState(() {});
  }

  Future<bool> _pickCompanionPath() async {
    final r = await FilePicker.platform.pickFiles(
      dialogTitle: '选择直播伴侣',
      type: FileType.custom,
      allowedExtensions: ['exe'],
    );
    if (r == null || r.files.single.path == null) return false;
    _companionPathCtrl.text = r.files.single.path!;
    _skipCompanion = false;
    await _persist();
    setState(() {});
    return true;
  }

  /// 一键开始前：路径存在则启动；不存在则弹窗（可选路径 / 跳过）。
  /// 返回 false 表示用户取消，应中止流程。
  Future<bool> _prepareCompanionLaunch() async {
    final companion = _companionPath;
    if (companion.isNotEmpty && await File(companion).exists()) {
      await _launchExe(companion);
      return true;
    }
    if (_skipCompanion) {
      _appendLog('已跳过直播伴侣，请自行手动启动');
      return true;
    }
    if (!mounted) return false;
    final action = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('设置直播伴侣'),
          content: const Text(
            '尚未设置有效的直播伴侣路径。可以选择伴侣程序，'
            '或跳过（稍后自己手动打开直播伴侣）。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'cancel'),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'skip'),
              child: const Text('跳过直播伴侣'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, 'pick'),
              child: const Text('选择路径'),
            ),
          ],
        );
      },
    );
    if (action == 'skip') {
      _skipCompanion = true;
      await _persist();
      _appendLog('已跳过直播伴侣路径设置，请自行手动启动');
      if (mounted) _toast('已跳过，请自行打开直播伴侣');
      return true;
    }
    if (action == 'pick') {
      final ok = await _pickCompanionPath();
      if (!ok) {
        _toast('未选择直播伴侣');
        return false;
      }
      await _launchExe(_companionPath);
      return true;
    }
    return false;
  }

  Future<void> _launchExe(String path, {List<String> args = const []}) async {
    if (path.isEmpty || !await File(path).exists()) {
      _appendLog('启动失败，文件不存在: $path');
      return;
    }
    await Process.start(
      path,
      args,
      workingDirectory: File(path).parent.path,
      mode: ProcessStartMode.detached,
    );
    _appendLog('已启动: $path${args.isEmpty ? '' : ' ${args.join(' ')}'}');
  }

  Future<void> _ensureObsReady() async {
    final fix = await _obsConfig.handleNew();
    _appendLog(
      '已自动配置 OBS WebSocket：${fix.changes.join('；')}'
      '${fix.error == null ? '' : '；写入异常: ${fix.error}'}',
    );

    final running = await _obsConfig.isObsProcessRunning();
    final portOpen = await _obsConfig.isWebsocketPortOpen();
    final shouldRestart = running && (fix.needRestart || !portOpen);
    if (shouldRestart) {
      _appendLog('重启 OBS 以加载 WebSocket 配置...');
      await _obsConfig.killObsIfRunning();
    }

    if (!await _obsConfig.isObsProcessRunning()) {
      await _launchExe(
        _obsPathCtrl.text.trim(),
        args: const ['--disable-shutdown-check', '--disable-updater'],
      );
    }

    final ok = await _obsConfig.waitWebsocketPort(
      timeout: const Duration(seconds: 75),
      onProgress: _appendLog,
    );
    if (!ok) {
      throw StateError(
        '无法连接到 OBS WebSocket（网络或地址错误）\n'
        '请确认 OBS 已启动并启用了 WebSocket',
      );
    }
  }

  Future<void> _testObsWs({required bool silent}) async {
    await _persist();
    setState(() => _status = '连接中');
    try {
      await _ensureObsReady();
      await _obsWs.connectWithRetry(
        _wsUrlCtrl.text.trim(),
        maxAttempts: silent ? 10 : 5,
        gap: const Duration(seconds: 1),
        onAttempt: _appendLog,
      );
      setState(() => _status = '已连接');
      _appendLog('OBS WebSocket 已连接');
      if (!silent) _toast('测试连接成功');
    } catch (e) {
      setState(() => _status = '未连接');
      _appendLog('OBS 连接失败: $e');
      if (!silent) _toast('OBS 拒绝连接，请确认 OBS 已启动并启用了 WebSocket');
      rethrow;
    }
  }

  Future<void> _runPullPipeline() async {
    final room = _roomUrlCtrl.text.trim();
    if (room.isEmpty) {
      _toast('请先填写直播间链接');
      return;
    }
    if (!await _ensureLicense()) return;
    setState(() => _busy = true);
    _pullBaseline = false;
    _wasPlaying = false;
    try {
      await _persist();
      _appendLog('===== 拉流模式开始 =====');

      final obs = _obsPathCtrl.text.trim();
      if (!await File(obs).exists()) {
        _appendLog('OBS 路径无效: $obs');
        _toast('未找到 OBS，请在设置中选择 obs64.exe');
        return;
      }

      if (!await _prepareCompanionLaunch()) {
        _appendLog('已取消：未设置直播伴侣');
        return;
      }
      await Future.delayed(const Duration(seconds: 1));
      try {
        await _testObsWs(silent: true);
      } catch (e) {
        _toast(
          'OBS WebSocket 未连通。请确认：\n'
          '1) OBS 已启动\n'
          '2) 工具 → WebSocket 服务器设置已启用\n'
          '3) 地址与设置一致（当前 ${_wsUrlCtrl.text.trim()}）',
        );
        return;
      }
      final extracted = await _flvExtractor.extract(room);
      if (!extracted.ok || extracted.bestUrl().isEmpty) {
        final tip = _friendlyPullError(extracted.message);
        _appendLog('拉流失败: ${extracted.message}');
        _toast(tip);
        await _maybePromptKuaishouLogin(extracted.message);
        return;
      }
      final pullUrl = extracted.bestUrl();
      final candidates = extracted.playCandidates();
      _appendLog('拉流: $pullUrl');
      _appendLog(
        await _obsWs.ensurePullMediaSource(
          pullUrl,
          fallbacks: candidates.skip(1).toList(),
        ),
      );
      try {
        _appendLog(await _obsWs.ensureVirtualCamStarted());
      } catch (e) {
        _appendLog('虚拟摄像机失败: $e');
        _toast('媒体源已就绪，但虚拟摄像机启动失败，请在 OBS 手动开启');
      }
      setState(() => _status = '已就绪');
      _startMediaMonitor();
      _toast('已就绪，请在直播伴侣里手动开播');
    } catch (e) {
      _appendLog('异常: $e');
      _toast('执行失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _friendlyPullError(String raw) {
    final m = raw.toLowerCase();
    if (m.contains('result=2') ||
        m.contains('操作频繁') ||
        m.contains('操作太快') ||
        m.contains('风控') ||
        m.contains('captcha')) {
      return '快手需要登录态或触发了风控。请点「登录快手账号」，并关闭 Clash TUN 后重试';
    }
    if (m.contains('tiktok') &&
        (m.contains('cookie') || m.contains('未解析') || m.contains('地区'))) {
      return 'TikTok 解析失败。请确认开播中，关闭代理或粘贴 www.tiktok.com Cookie 后重试';
    }
    if (m.contains('未开播') || m.contains('not live') || m.contains('offline') || m.contains('直播已结束')) {
      return '直播间似乎未开播，请确认链接后重试';
    }
    if (m.contains('cookie')) {
      return '需要登录态。请点击「登录快手账号」完成网页登录';
    }
    if (m.contains('timeout') || m.contains('timed out') || m.contains('连接')) {
      return '网络连接失败。若开了 Clash TUN，请先关闭或将目标域名设为直连';
    }
    if (raw.trim().isEmpty) return '拉流提取失败，请检查链接与网络';
    return '拉流失败：$raw';
  }

  void _startMediaMonitor() {
    _mediaTimer?.cancel();
    _mediaTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _tickMediaMonitor(),
    );
  }

  Future<void> _tickMediaMonitor() async {
    if (_busy || !mounted) return;
    final pull = await _obsWs.pullState();
    if (pull == PullState.idle) return;
    if (!_pullBaseline) {
      _pullBaseline = true;
      _wasPlaying = pull == PullState.playing;
      return;
    }
    if (pull == PullState.ended && _wasPlaying) {
      _wasPlaying = false;
      _appendLog('检测到关播：媒体源已结束');
      if (_autoStopOnMediaEnd) {
        await _obsWs.stopVirtualCam();
        _appendLog('已自动停止虚拟摄像机（关播）');
      }
      if (mounted) setState(() => _status = '已关播');
    } else if (pull == PullState.playing && !_wasPlaying) {
      _wasPlaying = true;
      try {
        _appendLog(await _obsWs.ensureVirtualCamStarted());
      } catch (e) {
        _appendLog('重启虚拟摄像机失败: $e');
      }
      if (mounted) setState(() => _status = '已就绪');
    }
  }

  void _startMemOpt() {
    _memTimer?.cancel();
    _memTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _tickMemOpt(),
    );
  }

  void _stopMemOpt() {
    _memTimer?.cancel();
    _memTimer = null;
  }

  Future<void> _tickMemOpt() async {
    if (_memRunning) return;
    _memRunning = true;
    try {
      final trimmed =
          await MemOptimizer.instance.trimProcesses(_memOptProcessNames);
      if (trimmed > 0 &&
          (_lastMemLog == null ||
              DateTime.now().difference(_lastMemLog!) >=
                  const Duration(minutes: 1))) {
        _lastMemLog = DateTime.now();
        _appendLog('优化直播伴侣内存：已回收工作集');
      }
    } catch (_) {
    } finally {
      _memRunning = false;
    }
  }

  Future<void> _showTopup() async {
    final ctrl = TextEditingController();
    final kami = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('卡密充值'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(
            labelText: '请输入充值卡密',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('充值'),
          ),
        ],
      ),
    );
    if (kami == null || kami.isEmpty) return;
    try {
      _appendLog('正在充值…');
      final profile = await widget.api.kamiTopup(kami);
      await widget.auth.applyProfile(profile);
      if (profile == null) {
        try {
          await widget.auth.refreshProfile();
        } catch (_) {}
      }
      if (mounted) setState(() {});
      _toast('充值成功');
      final rem = widget.auth.current?.remainingLabel ?? '';
      _appendLog('充值成功${rem.isEmpty ? '' : '，剩余 $rem'}');
    } catch (e) {
      _toast('$e');
    }
  }

  Future<void> _confirmLogout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('确定要退出登录吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.auth.logout();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => LoginPage(api: widget.api, auth: widget.auth),
      ),
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F9),
      body: Column(
        children: [
          const Material(
            color: Colors.white,
            elevation: 0.5,
            child: AppTitleBar(),
          ),
          if (_notice != null && _notice!.isNotEmpty)
            MaterialBanner(
              content: Text(
                '公告：$_notice',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              actions: [
                TextButton(
                  onPressed: () => setState(() => _notice = null),
                  child: const Text('知道了'),
                ),
              ],
            ),
          if (_showExpiryBanner)
            MaterialBanner(
              backgroundColor: const Color(0xFFFFF7ED),
              content: Text(
                '账号剩余 $_expiryHoursLabel，请及时充值以免中断使用',
                style: const TextStyle(color: Color(0xFF9A3412)),
              ),
              actions: [
                TextButton(
                  onPressed: _showTopup,
                  child: const Text('去充值'),
                ),
              ],
            ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
              children: [
                _AccountBanner(
                  auth: widget.auth,
                  onTopup: _showTopup,
                  onLogout: _confirmLogout,
                ),
                const SizedBox(height: 12),
                Text(
                  '把直播间画面拉进 OBS 并开启虚拟摄像机，然后在所选平台伴侣里手动开播',
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _roomUrlCtrl,
                  onChanged: (_) => _persist(),
                  decoration: InputDecoration(
                    labelText: '直播间链接',
                    hintText: '抖音 / 快手 / B站 / 小红书 / YouTube / TikTok',
                    filled: true,
                    fillColor: Colors.white,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 48,
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _runPullPipeline,
                    icon: Icon(_busy ? Icons.hourglass_top : Icons.play_arrow),
                    label: Text(
                      _busy ? '执行中...' : '一键开始',
                      style: const TextStyle(fontSize: 16),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    _StatusChip(label: 'OBS', value: _status),
                    const SizedBox(width: 8),
                    InkWell(
                      onTap: _busy ? null : () => _loginKuaishouAccount(),
                      borderRadius: BorderRadius.circular(20),
                      child: _StatusChip(
                        label: '快手',
                        value: _ksLoggedIn ? '已登录' : '点此登录',
                      ),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () async {
                              try {
                                await _testObsWs(silent: false);
                              } catch (_) {}
                            },
                      child: const Text('测试连接'),
                    ),
                  ],
                ),
                Theme(
                  data: Theme.of(context)
                      .copyWith(dividerColor: Colors.transparent),
                  child: ExpansionTile(
                    initiallyExpanded: false,
                    tilePadding: EdgeInsets.zero,
                    onExpansionChanged: (v) =>
                        setState(() => _settingsOpen = v),
                    title: Text(
                      _settingsOpen ? '收起设置' : '设置',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    children: [
                      _PathRow(
                        label: 'OBS Studio 安装路径',
                        controller: _obsPathCtrl,
                        onDetect: () => _detectObsPath(),
                        onPick: _pickObsPath,
                        onChanged: (_) => _persist(),
                      ),
                      const SizedBox(height: 8),
                      _PathRow(
                        label: '直播伴侣',
                        controller: _companionPathCtrl,
                        onDetect: () => _detectCompanionPath(),
                        onPick: _pickCompanionPath,
                        onChanged: (_) {
                          _skipCompanion = false;
                          _persist();
                        },
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('跳过直播伴侣路径设置'),
                        subtitle: const Text('没有有效路径时不弹窗；已设置路径时仍会自动启动'),
                        value: _skipCompanion,
                        onChanged: (v) {
                          setState(() => _skipCompanion = v);
                          _persist();
                        },
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _wsUrlCtrl,
                        onChanged: (_) => _persist(),
                        decoration: InputDecoration(
                          labelText: 'OBS WebSocket 地址',
                          filled: true,
                          fillColor: Colors.white,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFFE2E8F0)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  _ksLoggedIn
                                      ? Icons.verified_user
                                      : Icons.login,
                                  size: 18,
                                  color: _ksLoggedIn
                                      ? Colors.green.shade700
                                      : Colors.blueGrey,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    _ksLoggedIn
                                        ? '快手网页账号：已登录（拉流可用）'
                                        : '快手网页账号：未登录（拉流易被风控）',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              _ksLoggedIn
                                  ? 'Cookie 已自动保存。失效时可重新登录。'
                                  : '点击下方按钮打开快手官网登录，完成后自动获取 Cookie。',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey.shade700,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                FilledButton.icon(
                                  onPressed: _busy
                                      ? null
                                      : () => _loginKuaishouAccount(),
                                  icon: const Icon(Icons.open_in_browser, size: 18),
                                  label: Text(_ksLoggedIn ? '重新登录' : '登录快手账号'),
                                ),
                                const SizedBox(width: 8),
                                if (_ksLoggedIn)
                                  TextButton(
                                    onPressed: _busy ? null : _clearKuaishouCookie,
                                    child: const Text('退出登录'),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _ttCookieCtrl,
                        onChanged: (_) => _persist(),
                        maxLines: 2,
                        decoration: InputDecoration(
                          labelText: 'TikTok Cookie（可选）',
                          hintText: '浏览器登录 www.tiktok.com 后粘贴，部分地区/18+需要',
                          filled: true,
                          fillColor: Colors.white,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('优化直播伴侣内存'),
                        value: _memOpt,
                        onChanged: (v) async {
                          setState(() => _memOpt = v);
                          await _persist();
                          if (v) {
                            _startMemOpt();
                            _appendLog('已开启内存优化');
                          } else {
                            _stopMemOpt();
                            _appendLog('已关闭内存优化');
                          }
                        },
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('关播自动停止虚拟摄像机'),
                        value: _autoStopOnMediaEnd,
                        onChanged: (v) async {
                          setState(() => _autoStopOnMediaEnd = v);
                          await _persist();
                        },
                      ),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.info_outline),
                        title: const Text('关于'),
                        subtitle: const Text(
                          '${AppConfig.productName}  v${AppVersion.name}\n${AppAbout.publisherLine}',
                        ),
                        onTap: () => AppAbout.show(context),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '运行日志',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  height: 200,
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFFE2E8F0)),
                  ),
                  child: SelectionArea(
                    child: SingleChildScrollView(
                      child: Text(
                        _log,
                        style: const TextStyle(
                          fontSize: 12,
                          height: 1.45,
                          fontFamily: 'Consolas',
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  AppAbout.copyright,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AccountBanner extends StatelessWidget {
  const _AccountBanner({
    required this.auth,
    required this.onTopup,
    required this.onLogout,
  });

  final Auth auth;
  final VoidCallback onTopup;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final a = auth.current;
    final card = a?.card ?? '—';
    final remain = a?.remainingLabel ?? '未知';
    final expires = a?.expiresLabel ?? '未知';
    final device = a?.deviceId ?? '—';
    final used = a?.deviceCount;
    final max = a?.maxDevices;
    final deviceLine = (used != null && max != null)
        ? '设备 $used/$max · $device'
        : '设备 · $device';
    final low = (a?.remainingHours ?? 999) < 24;
    final expired = (a?.remainingHours ?? 1) <= 0;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      decoration: BoxDecoration(
        color: expired
            ? const Color(0xFFFEF2F2)
            : low
                ? const Color(0xFFFFF7ED)
                : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: expired
              ? const Color(0xFFFECACA)
              : low
                  ? const Color(0xFFFED7AA)
                  : const Color(0xFFE2E8F0),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '卡密 $card',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '剩余 $remain · 到期 $expires',
                  style: TextStyle(
                    fontSize: 12,
                    color: expired
                        ? const Color(0xFFB91C1C)
                        : low
                            ? const Color(0xFFC2410C)
                            : const Color(0xFF475569),
                    fontWeight:
                        low || expired ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  deviceLine,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              TextButton(
                onPressed: onTopup,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: const Text('卡密充值'),
              ),
              TextButton(
                onPressed: onLogout,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  foregroundColor: const Color(0xFF64748B),
                ),
                child: const Text('退出登录'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final ok = value == '已连接' ||
        value == '已就绪' ||
        value == '已登录';
    final color = ok ? const Color(0xFF15803D) : const Color(0xFF64748B);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        '$label · $value',
        style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _PathRow extends StatelessWidget {
  const _PathRow({
    required this.label,
    required this.controller,
    required this.onDetect,
    required this.onPick,
    required this.onChanged,
  });

  final String label;
  final TextEditingController controller;
  final VoidCallback onDetect;
  final VoidCallback onPick;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            onChanged: onChanged,
            decoration: InputDecoration(
              labelText: label,
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        OutlinedButton(onPressed: onDetect, child: const Text('检测')),
        const SizedBox(width: 4),
        OutlinedButton(onPressed: onPick, child: const Text('手动选择')),
      ],
    );
  }
}
