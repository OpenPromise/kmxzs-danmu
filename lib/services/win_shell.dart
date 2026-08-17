import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Windows Shell 启动与权限。
///
/// Dart 的 [Process.start] 走 CreateProcess，无法拉起清单为
/// `requireAdministrator` 的 exe（会报「请求的操作需要提升」）。
/// ShellExecute 会按清单处理：普通程序直接开，需要管理员的会弹 UAC。
abstract final class WinShell {
  static const _swShownormal = 1;
  static const _successThreshold = 32;
  static const _tokenQuery = 0x0008;
  static const _tokenElevation = 20;

  static bool open(
    String path, {
    String? workingDirectory,
    List<String> args = const [],
    String verb = 'open',
  }) {
    if (!Platform.isWindows) return false;
    final shell32 = DynamicLibrary.open('shell32.dll');
    final shellExecute = shell32.lookupFunction<
        IntPtr Function(
          IntPtr,
          Pointer<Utf16>,
          Pointer<Utf16>,
          Pointer<Utf16>,
          Pointer<Utf16>,
          Int32,
        ),
        int Function(
          int,
          Pointer<Utf16>,
          Pointer<Utf16>,
          Pointer<Utf16>,
          Pointer<Utf16>,
          int,
        )>('ShellExecuteW');

    final op = verb.toNativeUtf16();
    final file = path.toNativeUtf16();
    final params = args.join(' ').toNativeUtf16();
    final dir = (workingDirectory ?? '').toNativeUtf16();
    try {
      final rc = shellExecute(0, op, file, params, dir, _swShownormal);
      return rc > _successThreshold;
    } finally {
      calloc.free(op);
      calloc.free(file);
      calloc.free(params);
      calloc.free(dir);
    }
  }

  /// 当前进程是否已提权。伴侣是管理员时，只有同样权限才能把快捷键打进去。
  static bool get isElevated {
    if (!Platform.isWindows) return false;
    final k32 = DynamicLibrary.open('kernel32.dll');
    final adv = DynamicLibrary.open('advapi32.dll');
    final getCurrentProcess =
        k32.lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
      'GetCurrentProcess',
    );
    final openProcessToken = adv.lookupFunction<
        Int32 Function(Pointer<Void>, Uint32, Pointer<Pointer<Void>>),
        int Function(
            Pointer<Void>, int, Pointer<Pointer<Void>>)>('OpenProcessToken');
    final getTokenInformation = adv.lookupFunction<
        Int32 Function(Pointer<Void>, Int32, Pointer<_TokenElevation>, Uint32,
            Pointer<Uint32>),
        int Function(Pointer<Void>, int, Pointer<_TokenElevation>, int,
            Pointer<Uint32>)>('GetTokenInformation');
    final closeHandle = k32.lookupFunction<Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)>('CloseHandle');

    final tokenOut = calloc<Pointer<Void>>();
    final elev = calloc<_TokenElevation>();
    final retLen = calloc<Uint32>();
    try {
      if (openProcessToken(getCurrentProcess(), _tokenQuery, tokenOut) == 0) {
        return false;
      }
      final token = tokenOut.value;
      final ok = getTokenInformation(
            token,
            _tokenElevation,
            elev,
            sizeOf<_TokenElevation>(),
            retLen,
          ) !=
          0;
      closeHandle(token);
      return ok && elev.ref.tokenIsElevated != 0;
    } finally {
      calloc.free(tokenOut);
      calloc.free(elev);
      calloc.free(retLen);
    }
  }

  /// 以管理员重新打开当前 exe（弹出 UAC）。成功后调用方应退出本进程。
  static bool relaunchElevated({List<String> args = const []}) {
    final exe = Platform.resolvedExecutable;
    return open(
      exe,
      workingDirectory: File(exe).parent.path,
      args: args,
      verb: 'runas',
    );
  }
}

final class _TokenElevation extends Struct {
  @Uint32()
  external int tokenIsElevated;
}
