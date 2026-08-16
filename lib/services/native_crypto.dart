import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// [E] package:kmxzs/services/native_crypto.dart
/// [E] crypto_encrypt / crypto_decrypt / crypto_sign / crypto_free
class NativeCrypto {
  NativeCrypto._();
  static final NativeCrypto instance = NativeCrypto._();

  DynamicLibrary? _lib;
  _CryptoFn? _encrypt;
  _CryptoFn? _decrypt;
  _SignFn? _sign;
  _FreeFn? _free;

  bool get available => _lib != null;

  void init([String dllName = 'hook.dll']) {
    if (_lib != null) return;
    try {
      _lib = DynamicLibrary.open(dllName);
      _encrypt =
          _lib!.lookupFunction<_CryptoNative, _CryptoFn>('crypto_encrypt');
      _decrypt =
          _lib!.lookupFunction<_CryptoNative, _CryptoFn>('crypto_decrypt');
      _sign = _lib!.lookupFunction<_SignNative, _SignFn>('crypto_sign');
      _free = _lib!.lookupFunction<_FreeNative, _FreeFn>('crypto_free');
    } catch (_) {
      _lib = null;
    }
  }

  Uint8List? encrypt(Uint8List input) => _run(_encrypt, input);
  Uint8List? decrypt(Uint8List input) => _run(_decrypt, input);

  String? sign(String payload) {
    if (_sign == null) return null;
    final inPtr = payload.toNativeUtf8();
    final outLen = calloc<IntPtr>();
    try {
      final out = _sign!(inPtr.cast(), payload.length, outLen);
      if (out == nullptr) return null;
      final bytes = out.cast<Uint8>().asTypedList(outLen.value);
      final s = String.fromCharCodes(bytes);
      _free?.call(out.cast());
      return s;
    } finally {
      malloc.free(inPtr);
      calloc.free(outLen);
    }
  }

  Uint8List? _run(_CryptoFn? fn, Uint8List input) {
    if (fn == null) return null;
    final inPtr = calloc<Uint8>(input.length);
    final outLen = calloc<IntPtr>();
    try {
      inPtr.asTypedList(input.length).setAll(0, input);
      final out = fn(inPtr.cast(), input.length, outLen);
      if (out == nullptr) return null;
      final result =
          Uint8List.fromList(out.cast<Uint8>().asTypedList(outLen.value));
      _free?.call(out.cast());
      return result;
    } finally {
      calloc.free(inPtr);
      calloc.free(outLen);
    }
  }
}

typedef _CryptoNative = Pointer<Void> Function(
    Pointer<Void>, IntPtr, Pointer<IntPtr>);
typedef _CryptoFn = Pointer<Void> Function(
    Pointer<Void>, int, Pointer<IntPtr>);
typedef _SignNative = Pointer<Void> Function(
    Pointer<Void>, IntPtr, Pointer<IntPtr>);
typedef _SignFn = Pointer<Void> Function(Pointer<Void>, int, Pointer<IntPtr>);
typedef _FreeNative = Void Function(Pointer<Void>);
typedef _FreeFn = void Function(Pointer<Void>);
