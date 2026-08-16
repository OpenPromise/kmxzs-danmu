import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:kmxzs/config/app_config.dart';

/// 证书绑定：对服务器自签证书做 SHA-256 指纹校验。
///
/// 指纹来自 `server/scripts/export-cert-fingerprint.sh`，打包时通过
/// `KMXZS_CERT_SHA256` 注入（hex 或 base64 均可）。未配置时（开发调试）放行并
/// 打印告警；配置后不匹配的证书一律拒绝连接。
abstract final class CertPinner {
  static bool accept(X509Certificate cert, String host, int port) {
    final pin = AppConfig.certSha256.trim().toLowerCase().replaceAll(':', '');
    if (pin.isEmpty) {
      debugPrint('[tls] KMXZS_CERT_SHA256 未配置，开发调试模式跳过证书绑定: $host');
      return true;
    }
    final dig = sha256.convert(cert.der);
    final hex = dig.toString().toLowerCase();
    final b64 = base64Encode(dig.bytes);
    final ok = hex == pin || b64 == pin || b64.replaceAll('=', '') == pin;
    if (!ok) {
      debugPrint(
        '[tls] 证书指纹不匹配，已拒绝连接: $host（subject=${cert.subject}）',
      );
    } else {
      debugPrint('[tls] 证书绑定校验通过: $host');
    }
    return ok;
  }
}
