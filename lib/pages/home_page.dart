import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:kmxzs/pages/login_page.dart';
import 'package:kmxzs/pages/ks_web_login_page.dart';
import 'package:kmxzs/pages/ks_web_pull_page.dart';
import 'package:kmxzs/services/api.dart';
import 'package:kmxzs/services/auth.dart';
import 'package:kmxzs/services/flv_extractor.dart';
import 'package:kmxzs/services/kwailive_starter.dart';
import 'package:kmxzs/services/mem_optimizer.dart';
import 'package:kmxzs/services/obs_config.dart';
import 'package:kmxzs/services/obs_ws.dart';
import 'package:kmxzs/services/path_finder.dart';
import 'package:kmxzs/services/prefs_keys.dart';
import 'package:kmxzs/services/pull_error_copy.dart';
import 'package:kmxzs/services/win_shell.dart';
import 'package:kmxzs/app_version.dart';
import 'package:kmxzs/config/app_config.dart';
import 'package:kmxzs/widgets/about.dart';
import 'package:kmxzs/widgets/title_bar.dart';
import 'package:kmxzs/widgets/update_prompt.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'home_page/path_setup.dart';
part 'home_page/license_controller.dart';
part 'home_page/mem_controller.dart';
part 'home_page/ks_login_controller.dart';
part 'home_page/obs_controller.dart';
part 'home_page/settings_widgets.dart';

/// 主页：拉流虚拟摄像机模式。
class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.api, required this.auth});

  final Api api;
  final Auth auth;

  @override
  State<HomePage> createState() => _HomePageState();
}

/// 状态基类：存放所有共享字段与基础方法，供各职责 mixin（`on _HomePageBase`）直接读写。
abstract class _HomePageBase extends State<HomePage> {
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
  final _startHotkeyCtrl =
      TextEditingController(text: KwaiHotkey.defaultHotkey);
  final _endHotkeyCtrl = TextEditingController(text: KwaiHotkey.defaultHotkey);

  bool _skipCompanion = false;

  bool _busy = false;
  String _status = '未连接';
  String _log = '拉流模式：填写直播间链接后点「一键开播」。';

  bool _memOpt = false;
  bool _autoClickStartLive = true;
  bool _autoStopOnMediaEnd = true;

  final _pullMonitor = PullMonitorPolicy();
  bool _endStopRunning = false;
  bool _memRunning = false;
  DateTime? _lastMemLog;

  Timer? _mediaTimer;
  Timer? _memTimer;
  Timer? _licenseTimer;
  Timer? _persistDebounce;
  Future<bool>? _licenseInflight;

  String? _notice;
  bool _expiryWarned = false;
  bool _pathSetupShowing = false;

  static const int _maxLogLines = 500;

  String get _companionPath => _companionPathCtrl.text.trim();

  CompanionKind get _companionKind => CompanionKind.fromPath(_companionPath);

  String get _effectiveStartHotkey {
    final raw = _startHotkeyCtrl.text.trim();
    if (raw.isNotEmpty) return raw;
    return _companionKind.defaultStartHotkey;
  }

  String get _effectiveEndHotkey {
    if (!_companionKind.usesSeparateHotkeys) {
      return _effectiveStartHotkey;
    }
    final raw = _endHotkeyCtrl.text.trim();
    if (raw.isNotEmpty) return raw;
    return _companionKind.defaultEndHotkey;
  }

  void _syncHotkeyDefaultsForKind(CompanionKind kind) {
    final start = _startHotkeyCtrl.text.trim();
    final end = _endHotkeyCtrl.text.trim();
    final legacy = KwaiHotkey.normalize(start.isNotEmpty ? start : end);
    switch (kind) {
      case CompanionKind.kuaishou:
        final value = legacy.isNotEmpty ? legacy : kind.defaultStartHotkey;
        if (start.isEmpty) {
          _startHotkeyCtrl.text = value;
        }
        if (end.isEmpty) {
          _endHotkeyCtrl.text = value;
        }
        break;
      case CompanionKind.douyin:
        if (start.isEmpty) {
          _startHotkeyCtrl.text = kind.defaultStartHotkey;
        }
        final looksLegacySingle =
            (start.isEmpty || start == kind.defaultStartHotkey) &&
                (end.isEmpty || end == kind.defaultStartHotkey);
        if (end.isEmpty || looksLegacySingle) {
          _endHotkeyCtrl.text = kind.defaultEndHotkey;
        }
        break;
      case CompanionKind.tiktok:
      case CompanionKind.unknown:
        // 保持用户现有输入，不做覆盖。
        break;
    }
  }

  void _appendLog(String msg) {
    if (!mounted) return;
    final line = '[${DateTime.now().toString().substring(11, 19)}] $msg';
    setState(() {
      // 日志无界增长防护：只保留最近 _maxLogLines 行（新行在前）
      final lines = '$line\n$_log'.split('\n');
      _log = lines.length > _maxLogLines
          ? lines.sublist(0, _maxLogLines).join('\n')
          : lines.join('\n');
    });
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  /// 文本框每次按键即写盘开销大，统一走 400ms 防抖；离开页面或一键开始前仍会直接持久化。
  void _schedulePersist() {
    _persistDebounce?.cancel();
    _persistDebounce = Timer(const Duration(milliseconds: 400), () {
      unawaited(_persist());
    });
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
    _flvExtractor.tiktokCookie =
        _ttCookieCtrl.text.trim().isEmpty ? null : _ttCookieCtrl.text.trim();
    await sp.setBool(PrefsKeys.memOpt, _memOpt);
    await sp.setBool(PrefsKeys.autoClickStartLive, _autoClickStartLive);
    await sp.setBool(PrefsKeys.autoStopOnMediaEnd, _autoStopOnMediaEnd);
    final startHotkey = _startHotkeyCtrl.text.trim();
    final endHotkey = _endHotkeyCtrl.text.trim();
    await sp.setString(PrefsKeys.startLiveHotkey, startHotkey);
    await sp.setString(PrefsKeys.endLiveHotkey, endHotkey);
    final kind = _companionKind;
    final legacyHotkey =
        kind.usesSeparateHotkeys ? _effectiveStartHotkey : _effectiveEndHotkey;
    await sp.setString(PrefsKeys.liveHotkey, legacyHotkey);
  }

  Future<void> _launchExe(String path, {List<String> args = const []}) async {
    if (path.isEmpty || !await File(path).exists()) {
      _appendLog('启动失败，文件不存在: $path');
      return;
    }
    final image = path.replaceAll('/', '\\').split('\\').last;
    if (Platform.isWindows && await _isWindowsImageRunning(image)) {
      _appendLog('已在运行: $image');
      return;
    }
    if (Platform.isWindows) {
      // 快手伴侣清单是 requireAdministrator，CreateProcess 会报需要提升。
      final ok = WinShell.open(
        path,
        workingDirectory: File(path).parent.path,
        args: args,
      );
      if (!ok) {
        _appendLog('启动失败（若弹出了管理员确认，请点是）: $path');
        return;
      }
      _appendLog('已启动: $path${args.isEmpty ? '' : ' ${args.join(' ')}'}');
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

  Future<bool> _isWindowsImageRunning(String image) async {
    if (image.isEmpty) return false;
    final r = await Process.run('tasklist', [
      '/FI',
      'IMAGENAME eq $image',
      '/NH',
    ]);
    return r.stdout.toString().toLowerCase().contains(image.toLowerCase());
  }

  /// 伴侣强制管理员运行时，必须用同样权限才能把快捷键打进去。
  Future<void> _offerRelaunchAsAdmin() async {
    if (!mounted || !Platform.isWindows) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('需要管理员权限'),
        content: const Text(
          '快手直播伴侣本身以管理员运行。Windows 不允许普通权限程序给它发快捷键。\n\n'
          '快马小助手可以继续不提权使用；若要自动开播/关播，需要以管理员重新打开本软件。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('稍后手动开播'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('以管理员重新打开'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (WinShell.relaunchElevated()) {
      _appendLog('已请求管理员权限，本窗口即将关闭');
      exit(0);
    }
    _appendLog('未获得管理员权限（可能取消了 UAC）');
    _toast('未获得管理员权限');
  }
}

class _HomePageState extends _HomePageBase
    with
        _PathSetupController,
        _LicenseController,
        _MemController,
        _KuaishouController,
        _ObsController {
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
    _persistDebounce?.cancel();
    _obsPathCtrl.dispose();
    _companionPathCtrl.dispose();
    _wsUrlCtrl.dispose();
    _roomUrlCtrl.dispose();
    _ksCookieCtrl.dispose();
    _ttCookieCtrl.dispose();
    _startHotkeyCtrl.dispose();
    _endHotkeyCtrl.dispose();
    super.dispose();
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
    _flvExtractor.tiktokCookie =
        _ttCookieCtrl.text.trim().isEmpty ? null : _ttCookieCtrl.text.trim();
    _memOpt = sp.getBool(PrefsKeys.memOpt) ?? false;
    _autoClickStartLive = sp.getBool(PrefsKeys.autoClickStartLive) ?? true;
    _autoStopOnMediaEnd = sp.getBool(PrefsKeys.autoStopOnMediaEnd) ?? true;
    final kind = _companionKind;
    final rawLegacyHotkey = sp.getString(PrefsKeys.liveHotkey);
    final rawStartHotkey = sp.getString(PrefsKeys.startLiveHotkey);
    final rawEndHotkey = sp.getString(PrefsKeys.endLiveHotkey);
    if (kind.usesSeparateHotkeys) {
      _startHotkeyCtrl.text =
          (rawStartHotkey ?? rawLegacyHotkey ?? kind.defaultStartHotkey).trim();
      _endHotkeyCtrl.text = (rawEndHotkey ?? kind.defaultEndHotkey).trim();
    } else {
      final single = KwaiHotkey.normalize(
        rawLegacyHotkey ?? rawStartHotkey ?? rawEndHotkey,
      );
      _startHotkeyCtrl.text = single;
      _endHotkeyCtrl.text = single;
      if (_startHotkeyCtrl.text != (rawLegacyHotkey ?? '').trim()) {
        await sp.setString(PrefsKeys.liveHotkey, _startHotkeyCtrl.text);
      }
    }
    _syncHotkeyDefaultsForKind(kind);

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
    } catch (e) {
      // 配置/更新检查失败不阻断启动，但必须在 debug 日志留痕便于排查。
      debugPrint('[config] 拉取客户端配置失败: $e');
    }

    try {
      await widget.auth.refreshProfile();
      if (!widget.auth.isLicensed) {
        await _forceRelogin('账号已过期，请充值后续费');
        return;
      }
    } catch (e) {
      debugPrint('[auth] 启动时刷新档案失败: $e');
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

  Future<void> _runPullPipeline() async {
    final room = _roomUrlCtrl.text.trim();
    if (room.isEmpty) {
      _toast('请先填写直播间链接');
      return;
    }
    if (!await _ensureLicense()) return;
    setState(() => _busy = true);
    _pullMonitor.reset();
    _endStopRunning = false;
    _obsWs.resetPullMonitor();
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
        _toast('无法连接 OBS。请确认 OBS 已启动后再试');
        return;
      }
      late final FlvExtractResult extracted;
      if (FlvExtractor.looksLikeKuaishou(room)) {
        if (!mounted) return;
        extracted = await KsWebPullPage.open(
          context,
          room,
          log: _appendLog,
        );
      } else {
        extracted = await _flvExtractor.extract(room);
      }
      if (!extracted.ok || extracted.bestUrl().isEmpty) {
        final tip = _friendlyPullError(
          extracted.message,
          platform: extracted.platform,
        );
        _appendLog('拉流失败: $tip');
        if (tip != extracted.message) {
          _appendLog(extracted.message);
        }
        _toast(tip);
        if (extracted.platform == LivePlatform.kuaishou ||
            FlvExtractor.looksLikeKuaishou(room)) {
          await _maybePromptKuaishouLogin(extracted.message);
        }
        return;
      }
      final pullUrl = extracted.bestUrl();
      final candidates = extracted.playCandidates();
      _appendLog('已获取直播地址（房间 ${extracted.roomId ?? '未知'}）');
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
      final kind = _companionKind;
      if (_autoClickStartLive &&
          !_skipCompanion &&
          kind != CompanionKind.unknown) {
        _appendLog('正在发送开播快捷键（${kind.label}）…');
        final start = await CompanionStarter.instance.tryStartLive(
          kind: kind,
          hotkey: _effectiveStartHotkey,
        );
        _appendLog(start.message);
        if (start.needsElevation) {
          _toast('已就绪；自动开播需要与伴侣相同的管理员权限');
          await _offerRelaunchAsAdmin();
        } else if (start.ok) {
          _toast('已就绪，并已尝试开播');
        } else {
          _toast('已就绪，请在伴侣里点「开始直播」');
        }
      } else {
        _toast('已就绪，请在直播伴侣里手动开播');
      }
    } catch (e) {
      _appendLog('异常: $e');
      _toast('执行失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
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
        } catch (e) {
          // 充值成功但刷新档案失败：授权轮询会补拉，这里不打扰用户。
          debugPrint('[topup] 充值后刷新档案失败: $e');
        }
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
                  onChanged: (_) => _schedulePersist(),
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
                      _busy ? '执行中...' : '一键开播',
                      style: const TextStyle(fontSize: 16),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    _StatusChip(label: 'OBS', value: _status),
                    const Spacer(),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () async {
                              try {
                                await _testObsWs(silent: false);
                              } catch (_) {
                                // _testObsWs 已把失败原因写入日志与 toast，这里吞掉避免重复弹窗。
                              }
                            },
                      child: const Text('测试连接'),
                    ),
                  ],
                ),
                _SettingsPanel(state: this),
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
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.info_outline),
                  title: const Text('关于'),
                  subtitle: const Text(
                    '${AppConfig.productName}  v${AppVersion.name}\n${AppAbout.publisherLine}',
                  ),
                  onTap: () => AppAbout.show(context),
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
