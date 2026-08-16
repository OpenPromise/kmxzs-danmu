import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:kmxzs/config/app_config.dart';
import 'package:kmxzs/services/http_client_factory.dart';
import 'package:path_provider/path_provider.dart';

/// 下载安装包并拉起 Inno 静默安装。
///
/// 阶段3：下载完成后必须先校验 SHA-256 与 Ed25519 签名，任一不过就删除文件
/// 并抛错，绝不执行安装（防投毒）。安装包公钥由打包时 `KMXZS_UPDATE_PUBKEY`
/// 注入（base64），来自服务器 `/data/release_signing.pub`。
class AppUpdater {
  AppUpdater({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 20),
                receiveTimeout: const Duration(minutes: 10),
                followRedirects: true,
              ),
            )..httpClientAdapter = HttpClientFactory.dioAdapter();

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

  /// 下载后防投毒校验：SHA-256 必须匹配服务端下发的哈希，Ed25519 签名必须能被
  /// 内置公钥验证。任一失败会删除文件并抛错，绝不执行安装。
  Future<void> verifyPackage(
    File file, {
    String? sha256,
    String? signature,
  }) async {
    final pubKeyB64 = AppConfig.updatePubKey.trim();
    if (pubKeyB64.isEmpty) {
      if (kReleaseMode) {
        throw StateError('安装包校验公钥未配置（KMXZS_UPDATE_PUBKEY），已停止安装');
      }
      debugPrint('[updater] KMXZS_UPDATE_PUBKEY 未配置，开发模式跳过安装包验签');
      return;
    }
    final expectedSha = (sha256 ?? '').trim().toLowerCase();
    final sigB64 = (signature ?? '').trim();
    if (expectedSha.isEmpty || sigB64.isEmpty) {
      throw StateError('服务端未下发安装包哈希/签名，已停止安装');
    }

    final bytes = await file.readAsBytes();
    final actualSha = crypto.sha256.convert(bytes).toString().toLowerCase();
    if (actualSha != expectedSha) {
      await _deleteQuiet(file);
      throw StateError('安装包哈希校验失败，已取消安装');
    }

    final pubKey = SimplePublicKey(
      base64Decode(pubKeyB64),
      type: KeyPairType.ed25519,
    );
    final sig = Signature(base64Decode(sigB64), publicKey: pubKey);
    final verified = await Ed25519().verify(bytes, signature: sig);
    if (!verified) {
      await _deleteQuiet(file);
      throw StateError('安装包签名校验失败，已取消安装');
    }
  }

  /// 启动静默安装后退出当前进程；安装程序会关闭本窗口并拉起新版本。
  ///
  /// 修复：Process.start 失败或安装器立刻非零退出时抛错，让用户看到提示，
  /// 而不是应用直接消失。安装器正常运行超过观察窗才 exit(0) 交给它接管。
  Future<void> applySilent(File installer) async {
    Process proc;
    try {
      proc = await Process.start(
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
    } catch (e) {
      throw StateError('启动安装程序失败：$e');
    }
    try {
      final code = await proc.exitCode.timeout(
        const Duration(milliseconds: 1500),
      );
      // 安装器在极短时间内退出：无论成功与否都不确定安装完成，提示用户手动安装
      if (code != 0) {
        throw StateError('安装程序异常退出（错误码 $code），请手动运行安装包');
      }
      throw StateError('安装程序过早结束，未确认安装完成，请手动运行安装包');
    } on TimeoutException {
      // 安装器仍在正常运行：让出进程，交给安装器接管
      exit(0);
    }
  }

  Future<void> _deleteQuiet(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (e) {
      // 校验失败已抛错，清理失败不影响主流程，仅留日志
      debugPrint('[updater] 清理下载文件失败: $e');
    }
  }
}
