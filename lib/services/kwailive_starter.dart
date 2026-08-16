import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// 尝试自动点击快手直播伴侣「开始直播 / 开播」。
/// 方式：Windows UI Automation（可点自定义绘制按钮）+ 可选快捷键兜底。
class KwaiLiveStarter {
  KwaiLiveStarter._();
  static final KwaiLiveStarter instance = KwaiLiveStarter._();

  /// 纯 ASCII 脚本：中文按钮名用 Unicode 码点拼接，避免 PS5 按 GBK 读脚本乱码。
  static const _uiaScript = r'''
$ErrorActionPreference = 'Continue'
try {
  [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
  $OutputEncoding = [Console]::OutputEncoding
} catch {}
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms
function U([int[]]$codes) { return -join ($codes | ForEach-Object { [char]$_ }) }
$startLive   = U @(0x5F00, 0x59CB, 0x76F4, 0x64AD)
$kaiBo       = U @(0x5F00, 0x64AD)
$liJiKaiBo   = U @(0x7ACB, 0x5373, 0x5F00, 0x64AD)
$queRenKaiBo = U @(0x786E, 0x8BA4, 0x5F00, 0x64AD)
$kaiShi      = U @(0x5F00, 0x59CB)
$targets = @($startLive, $kaiBo, $liJiKaiBo, $queRenKaiBo, $kaiShi)
$root = [System.Windows.Automation.AutomationElement]::RootElement
$wins = $root.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
$clicked = $false
$log = New-Object System.Collections.Generic.List[string]
function Try-Invoke($el, $label) {
  try {
    $inv = $el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
    if ($null -ne $inv) { $inv.Invoke(); $script:log.Add("INVOKED:$label"); return $true }
  } catch {}
  try {
    $el.SetFocus(); Start-Sleep -Milliseconds 100
    [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
    $script:log.Add("ENTER:$label"); return $true
  } catch {}
  return $false
}
foreach ($w in $wins) {
  try {
    $name = $w.Current.Name
    $pid = $w.Current.ProcessId
    if ([string]::IsNullOrWhiteSpace($name)) { continue }
    $proc = Get-Process -Id $pid -ErrorAction SilentlyContinue
    if ($null -eq $proc) { continue }
    if ($proc.ProcessName -notmatch 'kwailive') { continue }
    $log.Add("WIN:$name pid=$pid")
    $all = $w.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    foreach ($el in $all) {
      $n = $el.Current.Name
      if ([string]::IsNullOrWhiteSpace($n)) { continue }
      foreach ($t in $targets) {
        if ($n -eq $t -or $n.Contains($t)) {
          $ctype = $el.Current.ControlType.ProgrammaticName
          $log.Add("FOUND:$n type=$ctype")
          if ($n.Contains($startLive) -or $n.Contains($kaiBo) -or $n.Contains($liJiKaiBo) -or $n.Contains($queRenKaiBo)) {
            if (Try-Invoke $el $n) { $clicked = $true; Start-Sleep -Milliseconds 800 }
          }
        }
      }
    }
  } catch { $log.Add("ERR:$($_.Exception.Message)") }
}
if (-not $clicked) {
  foreach ($w in $wins) {
    try {
      $proc = Get-Process -Id $w.Current.ProcessId -ErrorAction SilentlyContinue
      if ($null -eq $proc -or $proc.ProcessName -notmatch 'kwailive') { continue }
      $btnCond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, $startLive)
      $btn = $w.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $btnCond)
      if ($null -ne $btn) {
        $log.Add("FOUND_EXACT:$startLive")
        if (Try-Invoke $btn $startLive) { $clicked = $true }
      }
    } catch {}
  }
}
$result = @{ ok = $clicked; log = ($log -join "`n") }
($result | ConvertTo-Json -Compress)
''';

  Future<KwaiStartResult> tryStartLive({
    String hotkey = '',
    Duration settle = const Duration(seconds: 2),
  }) async {
    final logs = <String>[];
    try {
      final focused = await _focusKwaiWindow();
      logs.add(focused ? '已激活伴侣窗口' : '未找到可激活的伴侣窗口（仍尝试 UIA）');
      await Future.delayed(settle);

      final uia = await _runUiaScript();
      logs.add(uia.log);
      if (uia.ok) {
        await Future.delayed(const Duration(milliseconds: 1000));
        final confirm = await _runUiaScript();
        logs.add('确认轮: ${confirm.log}');
        return KwaiStartResult(true, logs.join('\n'));
      }

      if (hotkey.trim().isNotEmpty) {
        await _focusKwaiWindow();
        await Future.delayed(const Duration(milliseconds: 400));
        final sent = await _sendKeys(hotkey.trim());
        logs.add(sent ? '已发送快捷键 $hotkey' : '快捷键发送失败');
        if (sent) {
          await Future.delayed(const Duration(milliseconds: 800));
          await _runUiaScript();
          return KwaiStartResult(true, logs.join('\n'));
        }
      }

      return KwaiStartResult(
        false,
        '${logs.join('\n')}\n未能自动点到开播按钮。请确认伴侣已登录且主界面可见；'
        '或手动点一次「开始直播」。',
      );
    } catch (e) {
      return KwaiStartResult(
        false,
        '${logs.join('\n')}\n自动开播异常: $e\n请手动在伴侣点「开始直播」。',
      );
    }
  }

  String _decodePs(List<int> bytes) {
    if (bytes.isEmpty) return '';
    try {
      return utf8.decode(bytes);
    } catch (_) {}
    try {
      return systemEncoding.decode(bytes);
    } catch (_) {}
    return latin1.decode(bytes, allowInvalid: true);
  }

  Future<ProcessResult> _runPs(List<String> args) {
    return Process.run(
      'powershell',
      args,
      stdoutEncoding: null,
      stderrEncoding: null,
    );
  }

  Future<bool> _focusKwaiWindow() async {
    const script = r'''
Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Diagnostics;
public class WinFocus {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
  public static bool FocusProcess(string name) {
    foreach (var p in Process.GetProcessesByName(name)) {
      var h = p.MainWindowHandle;
      if (h == IntPtr.Zero) continue;
      if (IsIconic(h)) ShowWindowAsync(h, 9);
      return SetForegroundWindow(h);
    }
    return false;
  }
}
"@
if ([WinFocus]::FocusProcess('kwailive')) { 'OK' } else { 'FAIL' }
''';
    final r = await _runPs(
      ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', script],
    );
    return _decodePs(_asBytes(r.stdout)).contains('OK');
  }

  Future<_UiaResult> _runUiaScript() async {
    final scriptPath = await _materializeScript();
    final r = await _runPs([
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      scriptPath,
    ]);
    final out =
        '${_decodePs(_asBytes(r.stdout))}\n${_decodePs(_asBytes(r.stderr))}'
            .trim();
    try {
      final jsonStart = out.lastIndexOf('{');
      if (jsonStart >= 0) {
        final map =
            jsonDecode(out.substring(jsonStart)) as Map<String, dynamic>;
        return _UiaResult(map['ok'] == true, (map['log'] ?? out).toString());
      }
    } catch (_) {}
    return _UiaResult(
      out.contains('"ok":true') || out.contains('INVOKED:'),
      out.isEmpty ? 'UIA 无输出 (exit=${r.exitCode})' : out,
    );
  }

  /// 每次运行写出纯 ASCII 临时脚本，彻底绕过 Release 目录文件编码问题。
  Future<String> _materializeScript() async {
    final dir = await Directory.systemTemp.createTemp('kmxzs_uia_');
    final file = File(p.join(dir.path, 'auto_start_kwailive.ps1'));
    // UTF-8 BOM：部分环境仍按文件编码探测
    final bom = [0xEF, 0xBB, 0xBF];
    await file.writeAsBytes([...bom, ...utf8.encode(_uiaScript)]);
    // 同步一份到 exe 旁 tools，方便排查
    try {
      final beside = File(p.join(
        p.dirname(Platform.resolvedExecutable),
        'tools',
        'auto_start_kwailive.ps1',
      ));
      await beside.parent.create(recursive: true);
      await beside.writeAsBytes([...bom, ...utf8.encode(_uiaScript)]);
    } catch (_) {}
    return file.path;
  }

  Future<bool> _sendKeys(String keys) async {
    final script = '''
Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.SendKeys]::SendWait('$keys')
'OK'
''';
    final r = await _runPs(
      ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', script],
    );
    return _decodePs(_asBytes(r.stdout)).contains('OK');
  }

  List<int> _asBytes(dynamic raw) {
    if (raw is List<int>) return raw;
    if (raw is String) return utf8.encode(raw);
    return const [];
  }
}

class KwaiStartResult {
  final bool ok;
  final String message;
  KwaiStartResult(this.ok, this.message);
}

class _UiaResult {
  final bool ok;
  final String log;
  _UiaResult(this.ok, this.log);
}
