import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

/// 下载安装包并拉起 Inno 静默安装。
class AppUpdater {
  AppUpdater({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 20),
                receiveTimeout: const Duration(minutes: 10),
                followRedirects: true,
              ),
            );

  final Dio _dio;

  Future<File> download({
    required String url,
    required String version,
    int? expectedSize,
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}${Platform.pathSeparator}zbxzs-setup-$version.exe');
    if (await file.exists()) {
      await file.delete();
    }
    await _dio.download(
      url,
      file.path,
      cancelToken: cancelToken,
      onReceiveProgress: onProgress,
      options: Options(
        responseType: ResponseType.bytes,
        headers: const {'Accept': '*/*'},
      ),
    );
    if (!await file.exists()) {
      throw StateError('安装包下载失败');
    }
    final len = await file.length();
    if (len < 1024) {
      throw StateError('安装包过小，下载可能不完整');
    }
    if (expectedSize != null && expectedSize > 1024 && len != expectedSize) {
      throw StateError('安装包大小校验失败');
    }
    final raf = await file.open();
    try {
      final magic = await raf.read(2);
      if (magic.length < 2 || magic[0] != 0x4D || magic[1] != 0x5A) {
        throw StateError('不是有效的安装包');
      }
    } finally {
      await raf.close();
    }
    return file;
  }

  /// 启动静默安装后退出当前进程；安装程序会关闭本窗口并拉起新版本。
  Future<void> applySilent(File installer) async {
    await Process.start(
      installer.path,
      const [
        '/VERYSILENT',
        '/NORESTART',
        '/SUPPRESSMSGBOXES',
        '/FORCECLOSEAPPLICATIONS',
      ],
      mode: ProcessStartMode.detached,
      workingDirectory: installer.parent.path,
    );
    await Future<void>.delayed(const Duration(milliseconds: 500));
    exit(0);
  }
}
