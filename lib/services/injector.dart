import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

/// DLL 注入 + 远程调用 hook 导出。
class Injector {
  Injector._();
  static final Injector instance = Injector._();

  final DynamicLibrary _k32 = DynamicLibrary.open('kernel32.dll');
  final DynamicLibrary _adv = DynamicLibrary.open('advapi32.dll');

  late final _OpenProcess _openProcess =
      _k32.lookupFunction<_OpenProcessNative, _OpenProcess>('OpenProcess');
  late final _VirtualAllocEx _virtualAllocEx =
      _k32.lookupFunction<_VirtualAllocExN, _VirtualAllocEx>('VirtualAllocEx');
  late final _WriteProcessMemory _writeProcessMemory = _k32
      .lookupFunction<_WriteProcessMemoryN, _WriteProcessMemory>(
          'WriteProcessMemory');
  late final _CreateRemoteThread _createRemoteThread = _k32
      .lookupFunction<_CreateRemoteThreadN, _CreateRemoteThread>(
          'CreateRemoteThread');
  late final _GetProcAddress _getProcAddress =
      _k32.lookupFunction<_GetProcAddressN, _GetProcAddress>('GetProcAddress');
  late final _GetModuleHandleW _getModuleHandleW = _k32
      .lookupFunction<_GetModuleHandleWN, _GetModuleHandleW>('GetModuleHandleW');
  late final _CloseHandle _closeHandle =
      _k32.lookupFunction<_CloseHandleN, _CloseHandle>('CloseHandle');
  late final _WaitForSingleObject _wait = _k32
      .lookupFunction<_WaitForSingleObjectN, _WaitForSingleObject>(
          'WaitForSingleObject');
  late final _CreateToolhelp32Snapshot _createSnap = _k32.lookupFunction<
      _CreateToolhelp32SnapshotN,
      _CreateToolhelp32Snapshot>('CreateToolhelp32Snapshot');
  late final _Module32FirstW _module32First =
      _k32.lookupFunction<_Module32FirstWN, _Module32FirstW>('Module32FirstW');
  late final _Module32NextW _module32Next =
      _k32.lookupFunction<_Module32NextWN, _Module32NextW>('Module32NextW');
  late final _OpenProcessToken _openProcessToken = _adv
      .lookupFunction<_OpenProcessTokenN, _OpenProcessToken>('OpenProcessToken');
  late final _LookupPrivilegeValueW _lookupPrivilegeValueW = _adv.lookupFunction<
      _LookupPrivilegeValueWN,
      _LookupPrivilegeValueW>('LookupPrivilegeValueW');
  late final _AdjustTokenPrivileges _adjustTokenPrivileges = _adv.lookupFunction<
      _AdjustTokenPrivilegesN,
      _AdjustTokenPrivileges>('AdjustTokenPrivileges');
  late final _GetCurrentProcess _getCurrentProcess =
      _k32.lookupFunction<_GetCurrentProcessN, _GetCurrentProcess>(
          'GetCurrentProcess');
  late final _GetExitCodeThread _getExitCodeThread = _k32
      .lookupFunction<_GetExitCodeThreadN, _GetExitCodeThread>(
          'GetExitCodeThread');

  bool enableDebugPrivilege() {
    final token = calloc<IntPtr>();
    final luid = calloc<_LUID>();
    final tp = calloc<_TokenPrivileges>();
    try {
      if (_openProcessToken(
            _getCurrentProcess(),
            0x0020,
            token,
          ) ==
          0) {
        return false;
      }
      final name = 'SeDebugPrivilege'.toNativeUtf16();
      try {
        if (_lookupPrivilegeValueW(nullptr, name, luid) == 0) return false;
      } finally {
        malloc.free(name);
      }
      tp.ref.PrivilegeCount = 1;
      tp.ref.Privileges.Luid = luid.ref;
      tp.ref.Privileges.Attributes = 0x00000002;
      final ok = _adjustTokenPrivileges(
            Pointer.fromAddress(token.value),
            0,
            tp,
            0,
            nullptr,
            nullptr,
          ) !=
          0;
      _closeHandle(Pointer.fromAddress(token.value));
      return ok;
    } finally {
      calloc.free(token);
      calloc.free(luid);
      calloc.free(tp);
    }
  }

  Future<InjectResult> injectAndStartHooks(int pid, String dllPath) async {
    enableDebugPrivilege();
    final absDll = p.normalize(dllPath);
    if (!await File(absDll).exists()) {
      return InjectResult(false, 'hook.dll 不存在: $absDll');
    }

    // WaitForSingleObject / 远程线程在后台 isolate，避免 UI 卡死
    final msg = await Isolate.run(() => _injectWorker(pid, absDll));
    final ok = msg.startsWith('OK|');
    return InjectResult(ok, ok ? msg.substring(3) : msg);
  }

  bool _injectDll(int pid, String dllPath) {
    const processAllAccess = 0x1F0FFF;
    const memCommit = 0x1000;
    const memReserve = 0x2000;
    const pageReadWrite = 0x04;

    final hProcess = _openProcess(processAllAccess, 0, pid);
    if (hProcess == nullptr) return false;

    final pathPtr = dllPath.toNativeUtf16();
    final bytes = (dllPath.length + 1) * 2;
    try {
      final remote = _virtualAllocEx(
        hProcess,
        nullptr,
        bytes,
        memCommit | memReserve,
        pageReadWrite,
      );
      if (remote == nullptr) return false;

      final written = calloc<IntPtr>();
      final okWrite = _writeProcessMemory(
            hProcess,
            remote,
            pathPtr.cast(),
            bytes,
            written,
          ) !=
          0;
      calloc.free(written);
      if (!okWrite) return false;

      final k32Name = 'kernel32.dll'.toNativeUtf16();
      final loadName = 'LoadLibraryW'.toNativeUtf8();
      try {
        final k32 = _getModuleHandleW(k32Name);
        final loadLib = _getProcAddress(k32, loadName);
        if (loadLib == nullptr) return false;

        final hThread = _createRemoteThread(
          hProcess,
          nullptr,
          0,
          loadLib,
          remote,
          0,
          nullptr,
        );
        if (hThread == nullptr) return false;
        _wait(hThread, 15000);
        _closeHandle(hThread);
        return true;
      } finally {
        malloc.free(k32Name);
        malloc.free(loadName);
      }
    } finally {
      malloc.free(pathPtr);
      _closeHandle(hProcess);
    }
  }

  /// 远程调用无参导出；返回值取线程 exit code（DWORD）。失败返回 null。
  int? _remoteCall(int pid, Pointer<Void> fn) {
    const processAllAccess = 0x1F0FFF;
    final hProcess = _openProcess(processAllAccess, 0, pid);
    if (hProcess == nullptr) return null;
    try {
      final hThread = _createRemoteThread(
        hProcess,
        nullptr,
        0,
        fn,
        nullptr,
        0,
        nullptr,
      );
      if (hThread == nullptr) return null;
      _wait(hThread, 5000);
      final code = calloc<Uint32>();
      try {
        final ok = _getExitCodeThread(hThread, code);
        _closeHandle(hThread);
        if (ok == 0) return 0;
        return code.value;
      } finally {
        calloc.free(code);
      }
    } finally {
      _closeHandle(hProcess);
    }
  }

  int? findModuleBase(int pid, String moduleName) {
    const snapModule = 0x00000008;
    const snapModule32 = 0x00000010;
    final snap = _createSnap(snapModule | snapModule32, pid);
    if (snap == nullptr || snap.address == -1) return null;

    final me = calloc<_ModuleEntry32W>();
    me.ref.dwSize = sizeOf<_ModuleEntry32W>();
    try {
      if (_module32First(snap, me) == 0) return null;
      final target = moduleName.toLowerCase();
      do {
        final name = _utf16ArrayToString(me.ref.szModule);
        if (name.toLowerCase() == target ||
            name.toLowerCase().endsWith(target)) {
          return me.ref.modBaseAddr.address;
        }
      } while (_module32Next(snap, me) != 0);
      return null;
    } finally {
      calloc.free(me);
      _closeHandle(snap);
    }
  }

  Future<InjectResult> isoWaitAndInject({
    required String processName,
    required String dllPath,
    Duration timeout = const Duration(seconds: 90),
  }) async {
    final sw = Stopwatch()..start();
    while (sw.elapsed < timeout) {
      // 多开时注入内存最大的主进程，避免打到辅助进程
      final pid = await findLargestPid(processName);
      if (pid != null) {
        await Future.delayed(const Duration(milliseconds: 1000));
        return injectAndStartHooks(pid, dllPath);
      }
      await Future.delayed(const Duration(milliseconds: 500));
    }
    return InjectResult(false, '超时未找到进程 $processName');
  }

  Future<int?> findPid(String name) async => findLargestPid(name);

  Future<int?> findLargestPid(String name) async {
    final r = await Process.run('tasklist', ['/FO', 'CSV', '/NH']);
    int? bestPid;
    var bestMem = -1;
    for (final line in r.stdout.toString().split('\n')) {
      if (!line.toLowerCase().contains(name.toLowerCase())) continue;
      final cols = line.split(',');
      if (cols.length < 2) continue;
      final pid = int.tryParse(cols[1].replaceAll('"', '').trim());
      if (pid == null) continue;
      final memRaw = cols.length >= 5 ? cols[4] : cols.last;
      final mem = int.tryParse(memRaw.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
      if (mem >= bestMem) {
        bestMem = mem;
        bestPid = pid;
      }
    }
    return bestPid;
  }

  String defaultHookDll() {
    final exe = Platform.resolvedExecutable;
    return p.join(p.dirname(exe), 'hook.dll');
  }
}

class InjectResult {
  final bool ok;
  final String message;
  InjectResult(this.ok, this.message);
}

String _utf16ArrayToString(Array<Uint16> arr) {
  final chars = <int>[];
  for (var i = 0; i < 256; i++) {
    final c = arr[i];
    if (c == 0) break;
    chars.add(c);
  }
  return String.fromCharCodes(chars);
}

final class _LUID extends Struct {
  @Uint32()
  external int LowPart;
  @Int32()
  external int HighPart;
}

final class _LuidAndAttributes extends Struct {
  external _LUID Luid;
  @Uint32()
  external int Attributes;
}

final class _TokenPrivileges extends Struct {
  @Uint32()
  external int PrivilegeCount;
  external _LuidAndAttributes Privileges;
}

final class _ModuleEntry32W extends Struct {
  @Uint32()
  external int dwSize;
  @Uint32()
  external int th32ModuleID;
  @Uint32()
  external int th32ProcessID;
  @Uint32()
  external int GlblcntUsage;
  @Uint32()
  external int ProccntUsage;
  external Pointer<Void> modBaseAddr;
  @Uint32()
  external int modBaseSize;
  external Pointer<Void> hModule;
  @Array(256)
  external Array<Uint16> szModule;
  @Array(260)
  external Array<Uint16> szExePath;
}

typedef _OpenProcessNative = Pointer<Void> Function(Uint32, Int32, Uint32);
typedef _OpenProcess = Pointer<Void> Function(int, int, int);
typedef _VirtualAllocExN = Pointer<Void> Function(
    Pointer<Void>, Pointer<Void>, IntPtr, Uint32, Uint32);
typedef _VirtualAllocEx = Pointer<Void> Function(
    Pointer<Void>, Pointer<Void>, int, int, int);
typedef _WriteProcessMemoryN = Int32 Function(
    Pointer<Void>, Pointer<Void>, Pointer<Void>, IntPtr, Pointer<IntPtr>);
typedef _WriteProcessMemory = int Function(
    Pointer<Void>, Pointer<Void>, Pointer<Void>, int, Pointer<IntPtr>);
typedef _CreateRemoteThreadN = Pointer<Void> Function(
    Pointer<Void>,
    Pointer<Void>,
    IntPtr,
    Pointer<Void>,
    Pointer<Void>,
    Uint32,
    Pointer<Uint32>);
typedef _CreateRemoteThread = Pointer<Void> Function(
    Pointer<Void>,
    Pointer<Void>,
    int,
    Pointer<Void>,
    Pointer<Void>,
    int,
    Pointer<Uint32>);
typedef _GetProcAddressN = Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>);
typedef _GetProcAddress = Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>);
typedef _GetModuleHandleWN = Pointer<Void> Function(Pointer<Utf16>);
typedef _GetModuleHandleW = Pointer<Void> Function(Pointer<Utf16>);
typedef _CloseHandleN = Int32 Function(Pointer<Void>);
typedef _CloseHandle = int Function(Pointer<Void>);
typedef _WaitForSingleObjectN = Uint32 Function(Pointer<Void>, Uint32);
typedef _WaitForSingleObject = int Function(Pointer<Void>, int);
typedef _CreateToolhelp32SnapshotN = Pointer<Void> Function(Uint32, Uint32);
typedef _CreateToolhelp32Snapshot = Pointer<Void> Function(int, int);
typedef _Module32FirstWN = Int32 Function(
    Pointer<Void>, Pointer<_ModuleEntry32W>);
typedef _Module32FirstW = int Function(
    Pointer<Void>, Pointer<_ModuleEntry32W>);
typedef _Module32NextWN = Int32 Function(
    Pointer<Void>, Pointer<_ModuleEntry32W>);
typedef _Module32NextW = int Function(Pointer<Void>, Pointer<_ModuleEntry32W>);
typedef _OpenProcessTokenN = Int32 Function(
    Pointer<Void>, Uint32, Pointer<IntPtr>);
typedef _OpenProcessToken = int Function(
    Pointer<Void>, int, Pointer<IntPtr>);
typedef _LookupPrivilegeValueWN = Int32 Function(
    Pointer<Utf16>, Pointer<Utf16>, Pointer<_LUID>);
typedef _LookupPrivilegeValueW = int Function(
    Pointer<Utf16>, Pointer<Utf16>, Pointer<_LUID>);
typedef _AdjustTokenPrivilegesN = Int32 Function(
    Pointer<Void>,
    Int32,
    Pointer<_TokenPrivileges>,
    Uint32,
    Pointer<Void>,
    Pointer<Uint32>);
typedef _AdjustTokenPrivileges = int Function(
    Pointer<Void>,
    int,
    Pointer<_TokenPrivileges>,
    int,
    Pointer<Void>,
    Pointer<Uint32>);
typedef _GetCurrentProcessN = Pointer<Void> Function();
typedef _GetCurrentProcess = Pointer<Void> Function();
typedef _GetExitCodeThreadN = Int32 Function(Pointer<Void>, Pointer<Uint32>);
typedef _GetExitCodeThread = int Function(Pointer<Void>, Pointer<Uint32>);

/// 后台 isolate：执行阻塞式注入，返回 `OK|消息` 或错误文案。
String _injectWorker(int pid, String dllPath) {
  final k32 = DynamicLibrary.open('kernel32.dll');
  final openProcess =
      k32.lookupFunction<_OpenProcessNative, _OpenProcess>('OpenProcess');
  final virtualAllocEx =
      k32.lookupFunction<_VirtualAllocExN, _VirtualAllocEx>('VirtualAllocEx');
  final writeProcessMemory = k32.lookupFunction<_WriteProcessMemoryN,
      _WriteProcessMemory>('WriteProcessMemory');
  final createRemoteThread = k32.lookupFunction<_CreateRemoteThreadN,
      _CreateRemoteThread>('CreateRemoteThread');
  final getProcAddress =
      k32.lookupFunction<_GetProcAddressN, _GetProcAddress>('GetProcAddress');
  final getModuleHandleW =
      k32.lookupFunction<_GetModuleHandleWN, _GetModuleHandleW>(
          'GetModuleHandleW');
  final closeHandle =
      k32.lookupFunction<_CloseHandleN, _CloseHandle>('CloseHandle');
  final wait = k32.lookupFunction<_WaitForSingleObjectN, _WaitForSingleObject>(
      'WaitForSingleObject');
  final getExitCode = k32
      .lookupFunction<_GetExitCodeThreadN, _GetExitCodeThread>('GetExitCodeThread');
  final createSnap = k32.lookupFunction<_CreateToolhelp32SnapshotN,
      _CreateToolhelp32Snapshot>('CreateToolhelp32Snapshot');
  final module32First =
      k32.lookupFunction<_Module32FirstWN, _Module32FirstW>('Module32FirstW');
  final module32Next =
      k32.lookupFunction<_Module32NextWN, _Module32NextW>('Module32NextW');

  const processAllAccess = 0x1F0FFF;
  const memCommit = 0x1000;
  const memReserve = 0x2000;
  const pageReadWrite = 0x04;

  bool injectDll() {
    final hProcess = openProcess(processAllAccess, 0, pid);
    if (hProcess == nullptr) return false;
    final pathPtr = dllPath.toNativeUtf16();
    final bytes = (dllPath.length + 1) * 2;
    try {
      final remote = virtualAllocEx(
        hProcess,
        nullptr,
        bytes,
        memCommit | memReserve,
        pageReadWrite,
      );
      if (remote == nullptr) return false;
      final written = calloc<IntPtr>();
      final okWrite = writeProcessMemory(
            hProcess,
            remote,
            pathPtr.cast(),
            bytes,
            written,
          ) !=
          0;
      calloc.free(written);
      if (!okWrite) return false;

      final k32Name = 'kernel32.dll'.toNativeUtf16();
      final loadName = 'LoadLibraryW'.toNativeUtf8();
      try {
        final k32Mod = getModuleHandleW(k32Name);
        final loadLib = getProcAddress(k32Mod, loadName);
        if (loadLib == nullptr) return false;
        final hThread = createRemoteThread(
          hProcess,
          nullptr,
          0,
          loadLib,
          remote,
          0,
          nullptr,
        );
        if (hThread == nullptr) return false;
        wait(hThread, 15000);
        closeHandle(hThread);
        return true;
      } finally {
        malloc.free(k32Name);
        malloc.free(loadName);
      }
    } finally {
      malloc.free(pathPtr);
      closeHandle(hProcess);
    }
  }

  int? remoteCall(int address, {int parameter = 0}) {
    final hProcess = openProcess(processAllAccess, 0, pid);
    if (hProcess == nullptr) return null;
    try {
      final hThread = createRemoteThread(
        hProcess,
        nullptr,
        0,
        Pointer.fromAddress(address),
        parameter == 0 ? nullptr : Pointer.fromAddress(parameter),
        0,
        nullptr,
      );
      if (hThread == nullptr) return null;
      wait(hThread, 5000);
      final code = calloc<Uint32>();
      try {
        getExitCode(hThread, code);
        closeHandle(hThread);
        return code.value;
      } finally {
        calloc.free(code);
      }
    } finally {
      closeHandle(hProcess);
    }
  }

  int? findBase() {
    const snapModule = 0x00000008;
    const snapModule32 = 0x00000010;
    final snap = createSnap(snapModule | snapModule32, pid);
    if (snap == nullptr || snap.address == -1) return null;
    final me = calloc<_ModuleEntry32W>();
    me.ref.dwSize = sizeOf<_ModuleEntry32W>();
    try {
      if (module32First(snap, me) == 0) return null;
      do {
        final name = _utf16ArrayToString(me.ref.szModule).toLowerCase();
        if (name == 'hook.dll' || name.endsWith('hook.dll')) {
          return me.ref.modBaseAddr.address;
        }
      } while (module32Next(snap, me) != 0);
      return null;
    } finally {
      calloc.free(me);
      closeHandle(snap);
    }
  }

  if (!injectDll()) {
    return 'LoadLibrary 注入失败（请用管理员身份运行本程序）';
  }

  // 给 DllMain 一点时间
  sleep(const Duration(milliseconds: 800));
  final remoteBase = findBase();
  if (remoteBase == null) {
    return '注入后未在目标进程找到 hook.dll';
  }

  // [E] IDA(hook.dll): 导出是成员函数桩 lea rcx,[global]; jmp Method
  // 无参导出可用 CreateRemoteThread(exportVA, NULL)。
  // StartCapture/StartMonitor 依赖 InitCapture/InitPipe（需额外参数），
  // 无 Init 时直接 Start 会返回 0 — 不再盲目调用。
  // 本 DLL 无 CreateFileMapping / KSStreamCode；推流码靠 Dart 侧扫描。
  final exportRvas = <String, int>{
    'Hook_InitApiHook': 0x1100, // ApiHook_Init
    'Hook_HookWinInet': 0x10F0, // inline-hook wininet
    'Hook_StartLogging': 0x1200,
  };
  final done = <String>[];
  for (final e in exportRvas.entries) {
    final code = remoteCall(remoteBase + e.value);
    if (code != null) done.add('${e.key}=$code');
  }

  // InitScan(pid)：导出桩 mov edx,ecx → CreateRemoteThread 的 param 即目标 PID
  final scanInit = remoteCall(remoteBase + 0x1150, parameter: pid);
  if (scanInit != null) done.add('Hook_InitScan=$scanInit');

  sleep(const Duration(milliseconds: 200));
  final captured = remoteCall(remoteBase + 0x10A0);
  final matched = remoteCall(remoteBase + 0x10B0);

  return 'OK|注入成功 pid=$pid base=0x${remoteBase.toRadixString(16)}，'
      '已远程调用: ${done.join(", ")}；'
      'Captured=$captured Match=$matched'
      '（推流码请依赖 StreamCodeScanner / 共享内存）';
}
