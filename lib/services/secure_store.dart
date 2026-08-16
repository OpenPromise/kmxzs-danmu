import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Windows DPAPI 加密存储（CryptProtectData），替换 SharedPreferences 明文卡密。
///
/// 存储键带 `sec_` 前缀，旧明文数据在首次读取时自动迁移：加密写入 → 删除明文。
/// 非 Windows 平台退化为 SharedPreferences 明文（客户端仅面向 Windows 桌面）。
abstract final class SecureStore {
  static const _secPrefix = 'sec_';
  static bool get _isWindows => Platform.isWindows;

  static Future<String?> read(String key) async {
    final sp = await SharedPreferences.getInstance();
    if (!_isWindows) return sp.getString(key);
    final enc = sp.getString('$_secPrefix$key');
    if (enc != null && enc.isNotEmpty) {
      try {
        final plain = _dpapiUnprotect(base64Decode(enc));
        if (plain != null) return utf8.decode(plain, allowMalformed: true);
      } catch (e) {
        // 密文损坏，继续走迁移/清理逻辑；留日志便于定位 DPAPI 环境问题
        debugPrint('[secure-store] DPAPI 解密失败: $e');
      }
      // 解密失败：清掉损坏密文，避免每次启动都卡在读取
      await sp.remove('$_secPrefix$key');
    }
    // 旧明文迁移：老版本把卡密直接存在 SharedPreferences
    final legacy = sp.getString(key);
    if (legacy != null && legacy.isNotEmpty) {
      await _writeWindows(sp, key, legacy);
      await sp.remove(key);
      return legacy;
    }
    return null;
  }

  static Future<void> write(String key, String value) async {
    final sp = await SharedPreferences.getInstance();
    if (!_isWindows) {
      await sp.setString(key, value);
      return;
    }
    await _writeWindows(sp, key, value);
  }

  static Future<void> remove(String key) async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove('$_secPrefix$key');
    await sp.remove(key);
  }

  static Future<void> _writeWindows(
    SharedPreferences sp,
    String key,
    String value,
  ) async {
    if (value.isEmpty) {
      await sp.remove('$_secPrefix$key');
      await sp.remove(key);
      return;
    }
    final enc = base64Encode(_dpapiProtect(utf8.encode(value)));
    await sp.setString('$_secPrefix$key', enc);
    await sp.remove(key); // 顺带清理旧明文
  }

  // -------------------------------------------------------------------------
  // DPAPI FFI
  // -------------------------------------------------------------------------
  static Uint8List _dpapiProtect(Uint8List input) {
    final crypt32 = DynamicLibrary.open('crypt32.dll');
    final protect = crypt32.lookupFunction<_ProtectNative, _ProtectDart>(
      'CryptProtectData',
    );
    final inBlob = calloc<_DataBlob>();
    final outBlob = calloc<_DataBlob>();
    try {
      inBlob.ref.cbData = input.length;
      inBlob.ref.pbData = calloc<Uint8>(input.length);
      inBlob.ref.pbData.asTypedList(input.length).setAll(0, input);
      final ok = protect(
        inBlob,
        nullptr,
        nullptr,
        nullptr,
        nullptr,
        0, // CRYPTPROTECT_UI_FORBIDDEN
        outBlob,
      );
      if (ok == 0) {
        throw Exception('CryptProtectData failed: ${_lastError()}');
      }
      final bytes = outBlob.ref.pbData.asTypedList(outBlob.ref.cbData);
      return Uint8List.fromList(bytes);
    } finally {
      if (inBlob.ref.pbData != nullptr) calloc.free(inBlob.ref.pbData);
      if (outBlob.ref.pbData != nullptr) {
        _localFree(outBlob.ref.pbData.address);
      }
      calloc.free(inBlob);
      calloc.free(outBlob);
    }
  }

  static Uint8List? _dpapiUnprotect(Uint8List input) {
    final crypt32 = DynamicLibrary.open('crypt32.dll');
    final unprotect = crypt32.lookupFunction<_UnprotectNative, _UnprotectDart>(
      'CryptUnprotectData',
    );
    final inBlob = calloc<_DataBlob>();
    final outBlob = calloc<_DataBlob>();
    try {
      inBlob.ref.cbData = input.length;
      inBlob.ref.pbData = calloc<Uint8>(input.length);
      inBlob.ref.pbData.asTypedList(input.length).setAll(0, input);
      final ok = unprotect(
        inBlob,
        nullptr,
        nullptr,
        nullptr,
        nullptr,
        0,
        outBlob,
      );
      if (ok == 0) return null;
      final bytes = outBlob.ref.pbData.asTypedList(outBlob.ref.cbData);
      return Uint8List.fromList(bytes);
    } finally {
      if (inBlob.ref.pbData != nullptr) calloc.free(inBlob.ref.pbData);
      if (outBlob.ref.pbData != nullptr) {
        _localFree(outBlob.ref.pbData.address);
      }
      calloc.free(inBlob);
      calloc.free(outBlob);
    }
  }

  static int _localFree(int address) {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final localFree =
        kernel32.lookupFunction<_LocalFreeNative, _LocalFreeDart>('LocalFree');
    return localFree(address);
  }

  static int _lastError() {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final getLastError = kernel32.lookupFunction<
      Int32 Function(),
      int Function()
    >('GetLastError');
    return getLastError();
  }
}

final class _DataBlob extends Struct {
  @Uint32()
  external int cbData;

  external Pointer<Uint8> pbData;
}

typedef _ProtectNative = Int32 Function(
  Pointer<_DataBlob> pDataIn,
  Pointer<Utf16> szDataDescr,
  Pointer<_DataBlob> pOptionalEntropy,
  Pointer<Void> pvReserved,
  Pointer<Void> pPromptStruct,
  Uint32 dwFlags,
  Pointer<_DataBlob> pDataOut,
);

typedef _ProtectDart = int Function(
  Pointer<_DataBlob>,
  Pointer<Utf16>,
  Pointer<_DataBlob>,
  Pointer<Void>,
  Pointer<Void>,
  int,
  Pointer<_DataBlob>,
);

typedef _UnprotectNative = Int32 Function(
  Pointer<_DataBlob> pDataIn,
  Pointer<Pointer<Utf16>> ppszDataDescr,
  Pointer<_DataBlob> pOptionalEntropy,
  Pointer<Void> pvReserved,
  Pointer<Void> pPromptStruct,
  Uint32 dwFlags,
  Pointer<_DataBlob> pDataOut,
);

typedef _UnprotectDart = int Function(
  Pointer<_DataBlob>,
  Pointer<Pointer<Utf16>>,
  Pointer<_DataBlob>,
  Pointer<Void>,
  Pointer<Void>,
  int,
  Pointer<_DataBlob>,
);

typedef _LocalFreeNative = IntPtr Function(IntPtr);
typedef _LocalFreeDart = int Function(int);
