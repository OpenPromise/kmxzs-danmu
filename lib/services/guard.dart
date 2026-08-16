import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// [E] package:kmxzs/services/guard.dart
/// [E] initStreamCodeShm / disposeStreamCodeShm / fetchKmxzsConfig / writeKmxzsConfig
/// [E] 共享内存名: Local\KMXZSConfig , Local\KSStreamCode
class Guard {
  Guard._();
  static final Guard instance = Guard._();

  static const kmxzsConfigShm = r'Local\KMXZSConfig';
  static const ksStreamCodeShm = r'Local\KSStreamCode';

  final DynamicLibrary _k32 = DynamicLibrary.open('kernel32.dll');

  // [E] 原版符号为 CreateFileMappingA / OpenFileMappingA（ANSI）
  late final _OpenFileMappingA _openFileMapping = _k32
      .lookupFunction<_OpenFileMappingAN, _OpenFileMappingA>('OpenFileMappingA');
  late final _MapViewOfFile _mapViewOfFile =
      _k32.lookupFunction<_MapViewOfFileN, _MapViewOfFile>('MapViewOfFile');
  late final _UnmapViewOfFile _unmapViewOfFile = _k32
      .lookupFunction<_UnmapViewOfFileN, _UnmapViewOfFile>('UnmapViewOfFile');
  late final _CloseHandle _closeHandle =
      _k32.lookupFunction<_CloseHandleN, _CloseHandle>('CloseHandle');
  late final _CreateFileMappingA _createFileMapping = _k32.lookupFunction<
      _CreateFileMappingAN, _CreateFileMappingA>('CreateFileMappingA');

  Pointer<Void>? _streamCodeMapping;
  Pointer<Void>? _streamCodeView;
  Pointer<Void>? _configMapping;
  Pointer<Void>? _configView;

  /// [E] initStreamCodeShm — 必须由助手进程创建并长期持有，hook/扫描器才能写入
  bool initStreamCodeShm({int size = 4096}) {
    if (_streamCodeView != null) return true;
    final created = _createAndMap(ksStreamCodeShm, size);
    if (created == null) return false;
    _streamCodeMapping = created.$1;
    _streamCodeView = created.$2;
    // 清空
    _streamCodeView!.cast<Uint8>().asTypedList(size).fillRange(0, size, 0);
    return true;
  }

  bool initKmxzsConfigShm({int size = 4096}) {
    if (_configView != null) return true;
    final created = _createAndMap(kmxzsConfigShm, size);
    if (created == null) return false;
    _configMapping = created.$1;
    _configView = created.$2;
    _configView!.cast<Uint8>().asTypedList(size).fillRange(0, size, 0);
    return true;
  }

  /// [E] fetchKmxzsConfig
  String? fetchKmxzsConfig({int maxBytes = 4096}) {
    if (_configView != null) {
      return _readView(_configView!, maxBytes);
    }
    return _readShm(kmxzsConfigShm, maxBytes);
  }

  /// [E] 读取快手推流码共享内存
  String? readStreamCode({int maxBytes = 4096}) {
    if (_streamCodeView != null) {
      return _readView(_streamCodeView!, maxBytes);
    }
    return _readShm(ksStreamCodeShm, maxBytes);
  }

  /// [E] writeKmxzsConfig / 写入推流码到共享内存
  bool writeKmxzsConfig(String data) {
    initKmxzsConfigShm();
    if (_configView != null) {
      return _writeView(_configView!, data);
    }
    return _writeShm(kmxzsConfigShm, data);
  }

  bool writeStreamCode(String data) {
    initStreamCodeShm();
    if (_streamCodeView != null) {
      return _writeView(_streamCodeView!, data);
    }
    return _writeShm(ksStreamCodeShm, data);
  }

  /// [E] consumeStreamCode — 读出后清空
  String? consumeStreamCode({int maxBytes = 4096}) {
    final s = readStreamCode(maxBytes: maxBytes);
    if (s != null && s.isNotEmpty && _streamCodeView != null) {
      _streamCodeView!.cast<Uint8>().asTypedList(maxBytes).fillRange(0, maxBytes, 0);
    }
    return s;
  }

  bool get streamCodeShmReady => _streamCodeView != null;

  /// [E] disposeStreamCodeShm / disposeKmxzsConfigShm
  void disposeKmxzsConfigShm() {
    if (_streamCodeView != null) {
      _unmapViewOfFile(_streamCodeView!);
      _streamCodeView = null;
    }
    if (_streamCodeMapping != null) {
      _closeHandle(_streamCodeMapping!);
      _streamCodeMapping = null;
    }
    if (_configView != null) {
      _unmapViewOfFile(_configView!);
      _configView = null;
    }
    if (_configMapping != null) {
      _closeHandle(_configMapping!);
      _configMapping = null;
    }
  }

  (Pointer<Void>, Pointer<Void>)? _createAndMap(String name, int size) {
    const pageReadWrite = 0x04;
    const fileMapAllAccess = 0xF001F;
    final namePtr = name.toNativeUtf8();
    try {
      final h = _createFileMapping(
        Pointer.fromAddress(-1),
        nullptr, // 默认 ACL；同会话 Local\ 下 hook 一般可打开
        pageReadWrite,
        0,
        size,
        namePtr,
      );
      if (h == nullptr) return null;
      final view = _mapViewOfFile(h, fileMapAllAccess, 0, 0, size);
      if (view == nullptr) {
        _closeHandle(h);
        return null;
      }
      return (h, view);
    } finally {
      malloc.free(namePtr);
    }
  }

  String? _readView(Pointer<Void> view, int maxBytes) {
    final bytes = view.cast<Uint8>().asTypedList(maxBytes);
    var end = bytes.indexOf(0);
    if (end < 0) end = maxBytes;
    if (end == 0) return null;
    final s = String.fromCharCodes(bytes.sublist(0, end)).trim();
    return s.isEmpty ? null : s;
  }

  bool _writeView(Pointer<Void> view, String data) {
    final mem = view.cast<Uint8>().asTypedList(4096);
    mem.fillRange(0, 4096, 0);
    final units = data.codeUnits;
    final n = units.length > 4095 ? 4095 : units.length;
    mem.setRange(0, n, units.sublist(0, n));
    return true;
  }

  String? _readShm(String name, int maxBytes) {
    const fileMapRead = 0x0004;
    final namePtr = name.toNativeUtf8();
    try {
      final h = _openFileMapping(fileMapRead, 0, namePtr);
      if (h == nullptr) return null;
      final view = _mapViewOfFile(h, fileMapRead, 0, 0, maxBytes);
      if (view == nullptr) {
        _closeHandle(h);
        return null;
      }
      final s = _readView(view, maxBytes);
      _unmapViewOfFile(view);
      _closeHandle(h);
      return s;
    } finally {
      malloc.free(namePtr);
    }
  }

  bool _writeShm(String name, String data) {
    const pageReadWrite = 0x04;
    const fileMapAllAccess = 0xF001F;
    final namePtr = name.toNativeUtf8();
    final bytes = data.toNativeUtf8();
    try {
      final h = _createFileMapping(
        Pointer.fromAddress(-1),
        nullptr,
        pageReadWrite,
        0,
        4096,
        namePtr,
      );
      if (h == nullptr) return false;
      final view = _mapViewOfFile(h, fileMapAllAccess, 0, 0, 4096);
      if (view == nullptr) {
        _closeHandle(h);
        return false;
      }
      final mem = view.cast<Uint8>().asTypedList(4096);
      mem.fillRange(0, 4096, 0);
      final src = bytes.cast<Uint8>().asTypedList(data.length);
      final n = data.length > 4095 ? 4095 : data.length;
      mem.setRange(0, n, src.sublist(0, n));
      _unmapViewOfFile(view);
      _closeHandle(h);
      return true;
    } finally {
      malloc.free(namePtr);
      malloc.free(bytes);
    }
  }
}

typedef _OpenFileMappingAN = Pointer<Void> Function(
    Uint32, Int32, Pointer<Utf8>);
typedef _OpenFileMappingA = Pointer<Void> Function(int, int, Pointer<Utf8>);
typedef _MapViewOfFileN = Pointer<Void> Function(
    Pointer<Void>, Uint32, Uint32, Uint32, IntPtr);
typedef _MapViewOfFile = Pointer<Void> Function(
    Pointer<Void>, int, int, int, int);
typedef _UnmapViewOfFileN = Int32 Function(Pointer<Void>);
typedef _UnmapViewOfFile = int Function(Pointer<Void>);
typedef _CloseHandleN = Int32 Function(Pointer<Void>);
typedef _CloseHandle = int Function(Pointer<Void>);
typedef _CreateFileMappingAN = Pointer<Void> Function(
    Pointer<Void>, Pointer<Void>, Uint32, Uint32, Uint32, Pointer<Utf8>);
typedef _CreateFileMappingA = Pointer<Void> Function(
    Pointer<Void>, Pointer<Void>, int, int, int, Pointer<Utf8>);
