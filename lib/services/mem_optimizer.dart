import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// 内存优化：仅对空闲的后台进程（默认 kwailive.exe）做 EmptyWorkingSet。
///
/// 不做 SetProcessWorkingSetSize 硬性上限 —— 硬压上限（例如把 OBS 压到 200MB）
/// 会导致频繁换页、卡顿、掉帧。EmptyWorkingSet 只是把当前不活跃的物理页释放
/// 回系统，进程需要时会自动重新调入，风险低很多；并加了工作集阈值，只有占用
/// 较大的进程才会被回收。
class MemOptimizer {
  MemOptimizer._();
  static final MemOptimizer instance = MemOptimizer._();

  final DynamicLibrary _k32 = DynamicLibrary.open('kernel32.dll');
  final DynamicLibrary _psapi = DynamicLibrary.open('psapi.dll');

  late final _OpenProcess _openProcess =
      _k32.lookupFunction<_OpenProcessNative, _OpenProcess>('OpenProcess');
  late final _EmptyWorkingSet _emptyWorkingSet = _k32
      .lookupFunction<_EmptyWorkingSetNative, _EmptyWorkingSet>(
          'EmptyWorkingSet');
  late final _CloseHandle _closeHandle =
      _k32.lookupFunction<_CloseHandleNative, _CloseHandle>('CloseHandle');
  late final _GetProcessMemoryInfo _getProcessMemoryInfo = _psapi
      .lookupFunction<_GetProcessMemoryInfoNative, _GetProcessMemoryInfo>(
          'GetProcessMemoryInfo');

  /// 扫描指定进程并回收工作集，返回实际执行了回收的进程数。
  Future<int> trimProcesses(
    List<String> imageNames, {
    int minWorkingSetKb = 120 * 1024,
  }) async {
    var trimmed = 0;
    for (final pid in await _listPids(imageNames)) {
      if (_trimOne(pid, minWorkingSetKb)) trimmed++;
    }
    return trimmed;
  }

  bool _trimOne(int pid, int minWorkingSetKb) {
    const processQueryInfo = 0x0400;
    const processSetQuota = 0x0100;
    final h = _openProcess(processQueryInfo | processSetQuota, 0, pid);
    if (h == nullptr) return false;
    try {
      final pmc = calloc<_ProcessMemoryCounters>();
      try {
        pmc.ref.cb = sizeOf<_ProcessMemoryCounters>();
        if (_getProcessMemoryInfo(
              h,
              pmc.cast(),
              sizeOf<_ProcessMemoryCounters>(),
            ) ==
            0) {
          return false;
        }
        if (pmc.ref.WorkingSetSize < minWorkingSetKb * 1024) return false;
        if (_emptyWorkingSet(h) == 0) return false;
        return true;
      } finally {
        calloc.free(pmc);
      }
    } finally {
      _closeHandle(h);
    }
  }

  Future<List<int>> _listPids(List<String> imageNames) async {
    final lower = imageNames.map((e) => e.toLowerCase()).toList();
    try {
      final r = await Process.run('tasklist', ['/FO', 'CSV', '/NH']);
      final pids = <int>[];
      for (final line in r.stdout.toString().split('\n')) {
        final l = line.toLowerCase();
        if (!lower.any((n) => l.contains(n))) continue;
        final cols = line.split(',');
        if (cols.length < 2) continue;
        final pid = int.tryParse(cols[1].replaceAll('"', '').trim());
        if (pid != null) pids.add(pid);
      }
      return pids;
    } catch (_) {
      return const [];
    }
  }
}

final class _ProcessMemoryCounters extends Struct {
  @Uint32()
  external int cb;
  @Uint32()
  external int PageFaultCount;
  @UintPtr()
  external int PeakWorkingSetSize;
  @UintPtr()
  external int WorkingSetSize;
  @UintPtr()
  external int QuotaPeakPagedPoolUsage;
  @UintPtr()
  external int QuotaPagedPoolUsage;
  @UintPtr()
  external int QuotaPeakNonPagedPoolUsage;
  @UintPtr()
  external int QuotaNonPagedPoolUsage;
  @UintPtr()
  external int PagefileUsage;
  @UintPtr()
  external int PeakPagefileUsage;
}

typedef _OpenProcessNative = Pointer<Void> Function(Uint32, Int32, Uint32);
typedef _OpenProcess = Pointer<Void> Function(int, int, int);
typedef _EmptyWorkingSetNative = Int32 Function(Pointer<Void>);
typedef _EmptyWorkingSet = int Function(Pointer<Void>);
typedef _CloseHandleNative = Int32 Function(Pointer<Void>);
typedef _CloseHandle = int Function(Pointer<Void>);
typedef _GetProcessMemoryInfoNative =
    Int32 Function(Pointer<Void>, Pointer<Void>, Uint32);
typedef _GetProcessMemoryInfo = int Function(
    Pointer<Void>, Pointer<Void>, int);
