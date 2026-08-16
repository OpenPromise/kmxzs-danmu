import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:kmxzs/services/stream_code_parser.dart';

/// 扫描结果 + 诊断信息（可在 Isolate 间安全拷贝）。
class ScanResult {
  final String? url;
  final int pidCount;
  final int scannedMb;
  final int rtmpHits;
  final List<String> samples;
  final bool privateOnly;

  const ScanResult({
    this.url,
    this.pidCount = 0,
    this.scannedMb = 0,
    this.rtmpHits = 0,
    this.samples = const [],
    this.privateOnly = false,
  });

  bool get found => url != null && url!.trim().isNotEmpty;

  String summary() {
    final b = StringBuffer(
      '扫描 $pidCount 个 kwailive 进程，共 ${scannedMb}MB，rtmp 命中 $rtmpHits 处',
    );
    if (samples.isNotEmpty) {
      final hosts = samples
          .map(StreamCodeParser.hostOf)
          .whereType<String>()
          .toSet()
          .take(5)
          .join(', ');
      if (hosts.isNotEmpty) b.write('；候选主机: $hosts');
    }
    if (privateOnly) {
      b.write('；仅内网地址（OBS 通常无法直连）');
    }
    return b.toString();
  }
}

/// [E] StreamCodeScanner — 扫描 kwailive 进程内存中的推流地址。
/// 重活在 Isolate 中执行，避免卡住 UI。
class StreamCodeScanner {
  StreamCodeScanner._();
  static final StreamCodeScanner instance = StreamCodeScanner._();

  /// 兼容旧调用：只返回 URL。
  Future<String?> scanKwailive({int maxPids = 0}) async {
    final r = await scanKwailiveDiag(maxPids: maxPids);
    return r.url;
  }

  /// 扫描 kwailive 进程并返回诊断结果。maxPids<=0 表示扫描全部。
  Future<ScanResult> scanKwailiveDiag({int maxPids = 0}) async {
    final pids = await _listPids('kwailive.exe');
    if (pids.isEmpty) return const ScanResult();
    pids.sort((a, b) => b.memKb.compareTo(a.memKb));
    final selected = maxPids <= 0 ? pids : pids.take(maxPids).toList();
    final targets = selected.map((e) => e.pid).toList();
    return Isolate.run(() => _scanPidsWorker(targets));
  }

  Future<List<_PidMem>> _listPids(String image) async {
    final r = await Process.run('tasklist', ['/FO', 'CSV', '/NH']);
    final out = <_PidMem>[];
    for (final line in r.stdout.toString().split('\n')) {
      if (!line.toLowerCase().contains(image.toLowerCase())) continue;
      final cols = line.split(',');
      if (cols.length < 2) continue;
      final pid = int.tryParse(cols[1].replaceAll('"', '').trim());
      if (pid == null) continue;
      final memRaw = cols.length >= 5 ? cols[4] : cols.last;
      final memKb = int.tryParse(
            memRaw.replaceAll(RegExp(r'[^0-9]'), ''),
          ) ??
          0;
      out.add(_PidMem(pid, memKb));
    }
    return out;
  }
}

class _PidMem {
  final int pid;
  final int memKb;
  _PidMem(this.pid, this.memKb);
}

/// Isolate 入口：同步扫内存（不触碰 UI isolate）
ScanResult _scanPidsWorker(List<int> pids) {
  var scannedTotal = 0;
  var rtmpHitsTotal = 0;
  final candidates = <String>{};
  final samples = <String>[];

  for (final pid in pids) {
    final acc = _ScanAcc();
    _scanOnePid(pid, acc);
    scannedTotal += acc.scannedBytes;
    rtmpHitsTotal += acc.rtmpHits;
    candidates.addAll(acc.candidates);
    for (final s in acc.samples) {
      if (samples.length < 12 && !samples.contains(s)) samples.add(s);
    }
  }

  final ranked = candidates.toList()
    ..sort(
      (a, b) => StreamCodeParser.scorePushUrl(b)
          .compareTo(StreamCodeParser.scorePushUrl(a)),
    );

  String? best;
  var privateOnly = false;
  if (ranked.isNotEmpty) {
    best = ranked.first;
    privateOnly = StreamCodeParser.isPrivateRtmpUrl(best) &&
        ranked.every(StreamCodeParser.isPrivateRtmpUrl);
  }

  // 样本补全：把评分靠前的候选塞进 samples，方便日志诊断
  for (final c in ranked.take(6)) {
    if (!samples.contains(c)) samples.insert(0, c);
  }

  return ScanResult(
    url: best,
    pidCount: pids.length,
    scannedMb: (scannedTotal / (1024 * 1024)).round(),
    rtmpHits: rtmpHitsTotal,
    samples: samples.take(12).toList(),
    privateOnly: privateOnly,
  );
}

class _ScanAcc {
  int scannedBytes = 0;
  int rtmpHits = 0;
  final List<String> samples = [];
  final Set<String> candidates = {};
}

void _scanOnePid(int pid, _ScanAcc acc) {
  final k32 = DynamicLibrary.open('kernel32.dll');
  final openProcess = k32.lookupFunction<_OpenProcessN, _OpenProcess>('OpenProcess');
  final closeHandle = k32.lookupFunction<_CloseHandleN, _CloseHandle>('CloseHandle');
  final virtualQueryEx =
      k32.lookupFunction<_VirtualQueryExN, _VirtualQueryEx>('VirtualQueryEx');
  final readProcessMemory = k32
      .lookupFunction<_ReadProcessMemoryN, _ReadProcessMemory>('ReadProcessMemory');

  const processVmRead = 0x0010;
  const processQueryInfo = 0x0400;
  const processQueryLimited = 0x1000;

  final h = openProcess(processVmRead | processQueryInfo | processQueryLimited, 0, pid);
  if (h == nullptr) return;

  final mbi = calloc<_MemoryBasicInformation>();
  const bufCap = 0x10000;
  const overlap = 0x400;
  final readBuf = calloc<Uint8>(bufCap);
  final readSize = calloc<IntPtr>();
  try {
    var addr = 0;
    const maxScan = 0x60000000;

    final patterns = <List<int>>[
      'rtmp://'.codeUnits,
      'rtmps://'.codeUnits,
      'RTMP://'.codeUnits,
      'RTMPS://'.codeUnits,
    ];
    final patternsUtf16 = <List<int>>[
      [0x72, 0, 0x74, 0, 0x6d, 0, 0x70, 0, 0x3a, 0, 0x2f, 0, 0x2f, 0],
      [0x72, 0, 0x74, 0, 0x6d, 0, 0x70, 0, 0x73, 0, 0x3a, 0, 0x2f, 0, 0x2f, 0],
    ];

    while (addr >= 0 && acc.scannedBytes < maxScan) {
      final got = virtualQueryEx(
        h,
        Pointer.fromAddress(addr),
        mbi,
        sizeOf<_MemoryBasicInformation>(),
      );
      if (got == 0) break;

      final base = mbi.ref.BaseAddress.address;
      final size = mbi.ref.RegionSize;
      final state = mbi.ref.State;
      final protect = mbi.ref.Protect;
      final next = base + size;
      if (next <= addr) break;

      const memCommit = 0x1000;
      const pageNoAccess = 0x01;
      const pageGuard = 0x100;
      final readable = state == memCommit &&
          (protect & pageNoAccess) == 0 &&
          (protect & pageGuard) == 0 &&
          (protect & 0xEE) != 0;

      if (readable && size > 0 && size < 0x20000000) {
        var offset = 0;
        while (offset < size && acc.scannedBytes < maxScan) {
          final remain = size - offset;
          final chunk = remain > bufCap ? bufCap : remain;
          readSize.value = 0;
          final ok = readProcessMemory(
                h,
                Pointer.fromAddress(base + offset),
                readBuf.cast(),
                chunk,
                readSize,
              ) !=
              0;
          if (ok && readSize.value > 8) {
            final bytes = readBuf.asTypedList(readSize.value);
            _countAndSample(bytes, acc);
            _collectRtmp(bytes, patterns, acc);
            _collectRtmpUtf16(bytes, patternsUtf16, acc);
          }
          acc.scannedBytes += chunk;
          if (chunk < bufCap) break;
          offset += (chunk - overlap);
        }
      }

      addr = next;
      if (addr > 0x7FFFFFFFFFFF) break;
    }
  } finally {
    calloc.free(mbi);
    calloc.free(readBuf);
    calloc.free(readSize);
    closeHandle(h);
  }
}

void _countAndSample(List<int> bytes, _ScanAcc acc) {
  const rtmpAscii = [0x72, 0x74, 0x6d, 0x70]; // rtmp
  var start = 0;
  while (true) {
    final i = _indexOfCi(bytes, rtmpAscii, start);
    if (i < 0) break;
    acc.rtmpHits++;
    if (acc.samples.length < 12) {
      final end = _urlEnd(bytes, i);
      if (end - i >= 8) {
        final s = String.fromCharCodes(bytes.sublist(i, end));
        if (!acc.samples.contains(s)) acc.samples.add(s);
      }
    }
    start = i + rtmpAscii.length;
  }
}

void _collectRtmp(List<int> bytes, List<List<int>> patterns, _ScanAcc acc) {
  for (final pat in patterns) {
    var start = 0;
    while (true) {
      final i = _indexOf(bytes, pat, start);
      if (i < 0) break;
      final end = _urlEnd(bytes, i);
      if (end - i >= 16) {
        final s = StreamCodeParser.sanitize(
          String.fromCharCodes(bytes.sublist(i, end)),
        );
        if (_looksLikePushUrl(s)) acc.candidates.add(s);
      }
      start = i + pat.length;
    }
  }
}

void _collectRtmpUtf16(List<int> bytes, List<List<int>> patterns, _ScanAcc acc) {
  for (final pat in patterns) {
    var start = 0;
    while (true) {
      final i = _indexOf(bytes, pat, start);
      if (i < 0) break;
      final chars = <int>[];
      for (var p = i; p + 1 < bytes.length && chars.length < 512; p += 2) {
        final c = bytes[p] | (bytes[p + 1] << 8);
        if (c < 0x21 || c > 0x7e) break;
        if (c == 0x22 || c == 0x27 || c == 0x3c || c == 0x3e || c == 0x5c) break;
        chars.add(c);
      }
      if (chars.length >= 16) {
        final s = StreamCodeParser.sanitize(String.fromCharCodes(chars));
        if (_looksLikePushUrl(s)) acc.candidates.add(s);
      }
      start = i + pat.length;
    }
  }
}

bool _looksLikePushUrl(String s) {
  final lower = s.toLowerCase();
  if (!lower.startsWith('rtmp://') && !lower.startsWith('rtmps://')) return false;
  if (!s.contains('/')) return false;
  if (s.length < 20) return false;
  if (s.contains(' ')) return false;
  return true;
}

int _urlEnd(List<int> bytes, int start) {
  var i = start;
  while (i < bytes.length) {
    final c = bytes[i];
    if (c < 0x20 || c > 0x7e) break;
    if (c == 0x22 || c == 0x27 || c == 0x3c || c == 0x3e) break;
    if (c == 0x7b || c == 0x7d || c == 0x5c) break;
    i++;
    if (i - start > 512) break;
  }
  return i;
}

int _indexOf(List<int> data, List<int> pat, int start) {
  if (pat.isEmpty || start >= data.length) return -1;
  final first = pat[0];
  for (var i = start; i <= data.length - pat.length; i++) {
    if (data[i] != first) continue;
    var ok = true;
    for (var j = 1; j < pat.length; j++) {
      if (data[i + j] != pat[j]) {
        ok = false;
        break;
      }
    }
    if (ok) return i;
  }
  return -1;
}

int _indexOfCi(List<int> data, List<int> patLower, int start) {
  if (patLower.isEmpty || start >= data.length) return -1;
  for (var i = start; i <= data.length - patLower.length; i++) {
    var ok = true;
    for (var j = 0; j < patLower.length; j++) {
      var c = data[i + j];
      if (c >= 0x41 && c <= 0x5a) c += 0x20;
      if (c != patLower[j]) {
        ok = false;
        break;
      }
    }
    if (ok) return i;
  }
  return -1;
}

final class _MemoryBasicInformation extends Struct {
  external Pointer<Void> BaseAddress;
  external Pointer<Void> AllocationBase;
  @Uint32()
  external int AllocationProtect;
  @Uint32()
  external int _pad1;
  @IntPtr()
  external int RegionSize;
  @Uint32()
  external int State;
  @Uint32()
  external int Protect;
  @Uint32()
  external int Type;
  @Uint32()
  external int _pad2;
}

typedef _OpenProcessN = Pointer<Void> Function(Uint32, Int32, Uint32);
typedef _OpenProcess = Pointer<Void> Function(int, int, int);
typedef _CloseHandleN = Int32 Function(Pointer<Void>);
typedef _CloseHandle = int Function(Pointer<Void>);
typedef _VirtualQueryExN = IntPtr Function(
    Pointer<Void>, Pointer<Void>, Pointer<_MemoryBasicInformation>, IntPtr);
typedef _VirtualQueryEx = int Function(
    Pointer<Void>, Pointer<Void>, Pointer<_MemoryBasicInformation>, int);
typedef _ReadProcessMemoryN = Int32 Function(
    Pointer<Void>, Pointer<Void>, Pointer<Void>, IntPtr, Pointer<IntPtr>);
typedef _ReadProcessMemory = int Function(
    Pointer<Void>, Pointer<Void>, Pointer<Void>, int, Pointer<IntPtr>);
