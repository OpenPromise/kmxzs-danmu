import 'dart:io';

import 'package:kmxzs/services/win_hotkey.dart';
import 'package:kmxzs/services/win_shell.dart';

/// 与历史 UIA 脚本中的 Unicode 码点保持一致，避免按钮名写错。
class KwaiLiveUiText {
  static const endLive = '结束直播';
  static const confirm = '确定';
  static const cancel = '取消';
  static const startLive = '开始直播';
}

/// 当前设置的直播伴侣类型，由伴侣 exe 路径自动推断。
enum CompanionKind {
  /// 快手直播伴侣（kwailive.exe）
  kuaishou,

  /// 抖音直播伴侣（webcast_mate / 直播伴侣.exe）
  douyin,

  /// TikTok LIVE Studio
  tiktok,

  /// 未识别或未设置
  unknown;

  /// 根据伴侣 exe 路径推断类型。
  static CompanionKind fromPath(String path) {
    final p = path.trim().toLowerCase().replaceAll('/', '\\');
    if (p.isEmpty) return CompanionKind.unknown;
    if (p.contains('kwailive') || p.contains('快手')) {
      return CompanionKind.kuaishou;
    }
    if (p.contains('tiktok live studio') ||
        p.contains('tiktoklivestudio') ||
        p.contains('tiktok\\live') ||
        (p.contains('tiktok') && p.contains('studio'))) {
      return CompanionKind.tiktok;
    }
    if (p.contains('webcast_mate') ||
        p.contains('webcastmate') ||
        p.contains('直播伴侣') ||
        p.contains('douyin') ||
        p.contains('抖音')) {
      return CompanionKind.douyin;
    }
    return CompanionKind.unknown;
  }

  /// 是否需要分开配置开播/关播快捷键。
  bool get usesSeparateHotkeys => this == CompanionKind.douyin;

  /// 默认开播快捷键。
  String get defaultStartHotkey {
    switch (this) {
      case CompanionKind.kuaishou:
        return KwaiHotkey.defaultHotkey;
      case CompanionKind.douyin:
        return 'Alt+P';
      case CompanionKind.tiktok:
      case CompanionKind.unknown:
        return '';
    }
  }

  /// 默认关播快捷键。
  String get defaultEndHotkey {
    switch (this) {
      case CompanionKind.kuaishou:
        return KwaiHotkey.defaultHotkey;
      case CompanionKind.douyin:
        return 'Alt+O';
      case CompanionKind.tiktok:
      case CompanionKind.unknown:
        return '';
    }
  }

  /// 兼容旧代码：单热键伴侣时等于默认开/关播快捷键。
  String get defaultHotkey {
    switch (this) {
      case CompanionKind.kuaishou:
        return defaultStartHotkey;
      case CompanionKind.douyin:
      case CompanionKind.tiktok:
      case CompanionKind.unknown:
        return '';
    }
  }

  /// 用于界面提示的伴侣名称。
  String get label {
    switch (this) {
      case CompanionKind.kuaishou:
        return '快手直播伴侣';
      case CompanionKind.douyin:
        return '抖音直播伴侣';
      case CompanionKind.tiktok:
        return 'TikTok LIVE Studio';
      case CompanionKind.unknown:
        return '直播伴侣';
    }
  }

  /// 开播快捷键输入框的 hintText。
  String get startHotkeyHint {
    switch (this) {
      case CompanionKind.kuaishou:
        return 'Alt+P';
      case CompanionKind.douyin:
        return 'Alt+P';
      case CompanionKind.tiktok:
        return '请在 TikTok Studio 设置里查看并填入';
      case CompanionKind.unknown:
        return '例如 Alt+P';
    }
  }

  /// 关播快捷键输入框的 hintText。
  String get endHotkeyHint {
    switch (this) {
      case CompanionKind.kuaishou:
        return 'Alt+P';
      case CompanionKind.douyin:
        return 'Alt+O';
      case CompanionKind.tiktok:
        return '请在 TikTok Studio 设置里查看并填入';
      case CompanionKind.unknown:
        return '例如 Alt+P';
    }
  }

  /// 该伴侣关播后是否需要自动点确认弹窗（快手和抖音都有粉色确认框）。
  bool get needsStopConfirm =>
      this == CompanionKind.kuaishou || this == CompanionKind.douyin;
}

/// 把「Alt+P」转成 SendKeys 串（%p）。已是 ^+% 形式则原样返回。
class KwaiHotkey {
  static const defaultHotkey = 'Alt+P';

  /// 空值或旧默认 Ctrl+Alt+P 都改成当前默认，避免设置页还留着旧组合。
  static String normalize(String? raw) {
    final s = (raw ?? '').trim();
    if (s.isEmpty) return defaultHotkey;
    final lower = s.toLowerCase();
    if (lower == 'ctrl+alt+p' || lower == '^%p') return defaultHotkey;
    return s;
  }

  static String toSendKeys(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return '';
    final looksSendKeys = RegExp(r'^[\^%+{]').hasMatch(s) &&
        !s.toLowerCase().contains('ctrl') &&
        !s.toLowerCase().contains('alt') &&
        !s.toLowerCase().contains('shift');
    if (looksSendKeys) return s;

    final buf = StringBuffer();
    var key = '';
    for (final part in s.split(RegExp(r'\s*\+\s*'))) {
      final p = part.trim();
      if (p.isEmpty) continue;
      switch (p.toLowerCase()) {
        case 'ctrl':
        case 'control':
          buf.write('^');
        case 'shift':
          buf.write('+');
        case 'alt':
          buf.write('%');
        default:
          key = p;
      }
    }
    if (key.isEmpty) return buf.toString();
    if (RegExp(r'^F\d{1,2}$', caseSensitive: false).hasMatch(key)) {
      return '$buf{${key.toUpperCase()}}';
    }
    if (key.length == 1) return '$buf${key.toLowerCase()}';
    return '$buf{$key}';
  }
}

/// 通用直播伴侣开关播控制：按 [CompanionKind] 选焦点策略和关播确认行为。
///
/// - 快手：找 kwailive.exe 窗口 → 发 Alt+P → 点粉色确认框
/// - 抖音 / TikTok：找任意可见伴侣窗口（按标题打分）→ 发用户配置的快捷键 → 不点确认框
class CompanionStarter {
  CompanionStarter._();
  static final CompanionStarter instance = CompanionStarter._();

  Future<KwaiStartResult> tryStartLive({
    required CompanionKind kind,
    required String hotkey,
    Duration settle = const Duration(milliseconds: 400),
  }) async {
    try {
      if (Platform.isWindows && !WinShell.isElevated) {
        return KwaiStartResult(
          false,
          '直播伴侣以管理员运行，普通权限发快捷键会被系统拦住',
          needsElevation: true,
        );
      }
      if (!_focusCompanion(kind)) {
        return KwaiStartResult(false, '没找到 ${kind.label} 窗口');
      }
      await Future.delayed(settle);
      if (hotkey.trim().isEmpty) {
        return KwaiStartResult(false, '未设置开关播快捷键');
      }
      final sent = await WinHotkey.send(hotkey);
      if (sent) {
        return KwaiStartResult(true, '已在本进程发送开播快捷键');
      }
      return KwaiStartResult(false, '开播快捷键发送失败');
    } catch (e) {
      return KwaiStartResult(false, '自动开播失败，请手动在伴侣点「开始直播」');
    }
  }

  Future<KwaiStartResult> tryEndLive({
    required CompanionKind kind,
    required String hotkey,
    Duration settle = const Duration(milliseconds: 400),
  }) async {
    try {
      if (Platform.isWindows && !WinShell.isElevated) {
        return KwaiStartResult(
          false,
          '直播伴侣以管理员运行，普通权限发快捷键会被系统拦住',
          needsElevation: true,
        );
      }
      if (!_focusCompanion(kind)) {
        return KwaiStartResult(false, '没找到 ${kind.label} 窗口');
      }
      await Future.delayed(settle);
      if (hotkey.trim().isEmpty) {
        return KwaiStartResult(false, '未设置开关播快捷键');
      }
      final sent = await WinHotkey.send(hotkey);
      if (!sent) {
        return KwaiStartResult(false, '关播快捷键发送失败');
      }
      if (!kind.needsStopConfirm) {
        return KwaiStartResult(true, '已在本进程发送关播快捷键');
      }
      await Future.delayed(const Duration(milliseconds: 700));
      final confirmed = await _confirmStopDialog(kind);
      if (confirmed) {
        return KwaiStartResult(true, '已在本进程发送关播快捷键并确认弹窗');
      }
      final detail = WinHotkey.lastConfirmDetail;
      return KwaiStartResult(
        true,
        detail.isEmpty
            ? '已发送关播快捷键；确认框未点上，请再看一眼伴侣窗口'
            : '已发送关播快捷键；确认框未点上（$detail）',
      );
    } catch (e) {
      return KwaiStartResult(false, '自动关播失败，请手动在伴侣点「结束直播」');
    }
  }

  /// 把目标伴侣窗口提到前台。
  bool _focusCompanion(CompanionKind kind) {
    switch (kind) {
      case CompanionKind.kuaishou:
        return WinHotkey.focusKwailive();
      case CompanionKind.douyin:
        return WinHotkey.raiseTopmostByTitle('直播伴侣');
      case CompanionKind.tiktok:
        // TikTok LIVE Studio 主窗口标题含 "LIVE Studio"
        return WinHotkey.raiseTopmostByTitle('LIVE Studio');
      case CompanionKind.unknown:
        return WinHotkey.focusKwailive();
    }
  }

  /// 关播确认弹窗：按 [kind] 选快手或抖音专属实现。
  Future<bool> _confirmStopDialog(CompanionKind kind) async {
    switch (kind) {
      case CompanionKind.kuaishou:
        return _confirmKwaiStopDialog();
      case CompanionKind.douyin:
        return _confirmDouyinStopDialog();
      case CompanionKind.tiktok:
      case CompanionKind.unknown:
        return false;
    }
  }

  /// 快手专属：点粉色关播确认弹窗。
  Future<bool> _confirmKwaiStopDialog() async {
    for (var i = 0; i < 8; i++) {
      await Future.delayed(
        Duration(milliseconds: i == 0 ? 400 : 350),
      );
      final clicked = await WinHotkey.clickKwaiStopConfirm();
      if (!clicked) continue;
      await Future.delayed(const Duration(milliseconds: 280));
      if (!WinHotkey.stopConfirmVisible()) return true;
    }
    return false;
  }

  /// 抖音专属：点粉色关播确认弹窗（Electron 窗口）。
  Future<bool> _confirmDouyinStopDialog() async {
    for (var i = 0; i < 8; i++) {
      await Future.delayed(
        Duration(milliseconds: i == 0 ? 400 : 350),
      );
      final clicked = await WinHotkey.clickDouyinStopConfirm();
      if (!clicked) continue;
      await Future.delayed(const Duration(milliseconds: 280));
      if (!WinHotkey.douyinStopConfirmVisible()) return true;
    }
    return false;
  }
}

/// 向后兼容别名，外部代码可以继续用 [KwaiLiveStarter.instance]。
@Deprecated('Use CompanionStarter.instance with CompanionKind.kuaishou')
class KwaiLiveStarter {
  KwaiLiveStarter._();
  static final KwaiLiveStarter instance = KwaiLiveStarter._();

  Future<KwaiStartResult> tryStartLive({
    String hotkey = KwaiHotkey.defaultHotkey,
    Duration settle = const Duration(milliseconds: 400),
  }) => CompanionStarter.instance.tryStartLive(
        kind: CompanionKind.kuaishou,
        hotkey: hotkey,
        settle: settle,
      );

  Future<KwaiStartResult> tryEndLive({
    String hotkey = KwaiHotkey.defaultHotkey,
    Duration settle = const Duration(milliseconds: 400),
  }) => CompanionStarter.instance.tryEndLive(
        kind: CompanionKind.kuaishou,
        hotkey: hotkey,
        settle: settle,
      );
}

class KwaiStartResult {
  final bool ok;
  final String message;
  final bool needsElevation;
  KwaiStartResult(this.ok, this.message, {this.needsElevation = false});
}
