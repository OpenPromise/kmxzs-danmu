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

/// 用本进程发送伴侣开关播快捷键；关播后再点确认框里的粉色「确定」。
class KwaiLiveStarter {
  KwaiLiveStarter._();
  static final KwaiLiveStarter instance = KwaiLiveStarter._();

  Future<KwaiStartResult> tryStartLive({
    String hotkey = KwaiHotkey.defaultHotkey,
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
      if (!WinHotkey.focusKwailive()) {
        return KwaiStartResult(false, '没找到直播伴侣窗口');
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
    String hotkey = KwaiHotkey.defaultHotkey,
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
      if (!WinHotkey.focusKwailive()) {
        return KwaiStartResult(false, '没找到直播伴侣窗口');
      }
      await Future.delayed(settle);
      if (hotkey.trim().isEmpty) {
        return KwaiStartResult(false, '未设置开关播快捷键');
      }
      final sent = await WinHotkey.send(hotkey);
      if (!sent) {
        return KwaiStartResult(false, '关播快捷键发送失败');
      }
      await Future.delayed(const Duration(milliseconds: 700));
      final confirmed = await _confirmStopDialog();
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

  /// 关播确认框：点右侧「确定」。不要回车，默认按钮可能是「取消」。
  Future<bool> _confirmStopDialog() async {
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
}

class KwaiStartResult {
  final bool ok;
  final String message;
  final bool needsElevation;
  KwaiStartResult(this.ok, this.message, {this.needsElevation = false});
}
