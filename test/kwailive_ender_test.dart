import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kmxzs/services/kwailive_starter.dart';
import 'package:kmxzs/services/win_hotkey.dart';

void main() {
  test('关播按钮名与 UIA 脚本码点一致', () {
    expect(
      String.fromCharCodes(const [0x7ED3, 0x675F, 0x76F4, 0x64AD]),
      KwaiLiveUiText.endLive,
    );
    expect(String.fromCharCodes(const [0x786E, 0x5B9A]), KwaiLiveUiText.confirm);
    expect(String.fromCharCodes(const [0x53D6, 0x6D88]), KwaiLiveUiText.cancel);
    expect(
      String.fromCharCodes(const [0x5F00, 0x59CB, 0x76F4, 0x64AD]),
      KwaiLiveUiText.startLive,
    );
    expect(
      String.fromCharCodes(const [0x7ACB, 0x5373, 0x5F00, 0x64AD]),
      '立即开播',
    );
  });

  test('快捷键转成 SendKeys', () {
    expect(KwaiHotkey.toSendKeys('Alt+P'), '%p');
    expect(KwaiHotkey.toSendKeys('alt+p'), '%p');
    expect(KwaiHotkey.toSendKeys('Ctrl+Alt+P'), '^%p');
    expect(KwaiHotkey.toSendKeys('ctrl+alt+p'), '^%p');
    expect(KwaiHotkey.toSendKeys('Ctrl+Shift+F10'), '^+{F10}');
    expect(KwaiHotkey.toSendKeys('%p'), '%p');
    expect(KwaiHotkey.toSendKeys('^%p'), '^%p');
    expect(KwaiHotkey.toSendKeys('{ENTER}'), '{ENTER}');
  });

  test('空值和旧默认快捷键归一成 Alt+P', () {
    expect(KwaiHotkey.normalize(null), 'Alt+P');
    expect(KwaiHotkey.normalize(''), 'Alt+P');
    expect(KwaiHotkey.normalize('Ctrl+Alt+P'), 'Alt+P');
    expect(KwaiHotkey.normalize('ctrl+alt+p'), 'Alt+P');
    expect(KwaiHotkey.normalize('^%p'), 'Alt+P');
    expect(KwaiHotkey.normalize('F10'), 'F10');
  });

  test('快捷键解析成本进程虚拟键', () {
    final start = KwaiHotkeyChord.parse('Alt+P')!;
    expect(start.ctrl, isFalse);
    expect(start.alt, isTrue);
    expect(start.shift, isFalse);
    expect(start.vk, 0x50);

    final sendKeys = KwaiHotkeyChord.parse('%p')!;
    expect(sendKeys.ctrl, isFalse);
    expect(sendKeys.alt, isTrue);
    expect(sendKeys.vk, 0x50);

    final old = KwaiHotkeyChord.parse('Ctrl+Alt+P')!;
    expect(old.ctrl, isTrue);
    expect(old.alt, isTrue);
    expect(old.vk, 0x50);

    final f10 = KwaiHotkeyChord.parse('Ctrl+Shift+F10')!;
    expect(f10.ctrl, isTrue);
    expect(f10.shift, isTrue);
    expect(f10.vk, 0x79);

    expect(KwaiHotkeyChord.parse('{ENTER}')!.vk, WinHotkey.vkReturn);
    expect(KwaiHotkeyChord.parse('enter')!.vk, WinHotkey.vkReturn);
  });

  test('x64 INPUT 键盘结构体是 40 字节', () {
    expect(WinHotkey.keyboardInputSize, 40);
    expect(WinHotkey.mouseInputSize, 40);
  }, skip: !Platform.isWindows);

  test('关播确认框尺寸能同时覆盖逻辑像素和 150% DPI', () {
    expect(WinHotkey.isStopConfirmSize(376, 196), isTrue);
    expect(WinHotkey.isStopConfirmSize(564, 294), isTrue);
    expect(WinHotkey.isStopConfirmSize(470, 245), isTrue);
    expect(WinHotkey.isStopConfirmSize(712, 400), isFalse);
    expect(WinHotkey.isStopConfirmSize(1544, 991), isFalse);
    expect(WinHotkey.isStopConfirmSize(225, 400), isFalse);
  });

  group('CompanionKind.fromPath', () {
    test('快手 KwaiLive', () {
      expect(
        CompanionKind.fromPath(r'C:\Program Files\KwaiLive\KwaiLive.exe'),
        CompanionKind.kuaishou,
      );
      expect(
        CompanionKind.fromPath(r'D:\快手直播伴侣\kwailive.exe'),
        CompanionKind.kuaishou,
      );
    });

    test('抖音直播伴侣', () {
      expect(
        CompanionKind.fromPath(r'C:\Users\foo\AppData\Local\webcast_mate\App\webcast_mate.exe'),
        CompanionKind.douyin,
      );
      expect(
        CompanionKind.fromPath(r'D:\直播伴侣\直播伴侣.exe'),
        CompanionKind.douyin,
      );
    });

    test('TikTok LIVE Studio', () {
      expect(
        CompanionKind.fromPath(r'C:\Program Files\TikTok LIVE Studio\TikTok LIVE Studio.exe'),
        CompanionKind.tiktok,
      );
      expect(
        CompanionKind.fromPath(r'C:\Users\foo\AppData\Local\TikTokLiveStudio\app\tiktoklivestudio.exe'),
        CompanionKind.tiktok,
      );
    });

    test('空路径或未知路径返回 unknown', () {
      expect(CompanionKind.fromPath(''), CompanionKind.unknown);
      expect(
        CompanionKind.fromPath(r'C:\StreamLabs\Streamlabs.exe'),
        CompanionKind.unknown,
      );
    });

    test('不同伴侣的默认开播/关播快捷键符合预期', () {
      expect(CompanionKind.kuaishou.usesSeparateHotkeys, isFalse);
      expect(CompanionKind.kuaishou.defaultStartHotkey, 'Alt+P');
      expect(CompanionKind.kuaishou.defaultEndHotkey, 'Alt+P');

      expect(CompanionKind.douyin.usesSeparateHotkeys, isTrue);
      expect(CompanionKind.douyin.defaultStartHotkey, 'Alt+P');
      expect(CompanionKind.douyin.defaultEndHotkey, 'Alt+O');

      expect(CompanionKind.tiktok.usesSeparateHotkeys, isFalse);
      expect(CompanionKind.tiktok.defaultStartHotkey, isEmpty);
      expect(CompanionKind.tiktok.defaultEndHotkey, isEmpty);

      expect(CompanionKind.unknown.defaultStartHotkey, isEmpty);
      expect(CompanionKind.unknown.defaultEndHotkey, isEmpty);
    });

    test('快手和抖音需要点关播确认弹窗，TikTok 和 unknown 不需要', () {
      expect(CompanionKind.kuaishou.needsStopConfirm, isTrue);
      expect(CompanionKind.douyin.needsStopConfirm, isTrue);
      expect(CompanionKind.tiktok.needsStopConfirm, isFalse);
      expect(CompanionKind.unknown.needsStopConfirm, isFalse);
    });
  });
}
