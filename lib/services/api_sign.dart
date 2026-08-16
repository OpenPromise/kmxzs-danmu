import 'dart:convert';

import 'package:crypto/crypto.dart';

/// 客户端请求 HMAC 签名（与服务端 KMXZS_API_SECRET 成对）。
abstract final class ApiSign {
  static String canonicalBody(Map<String, dynamic> body) {
    const skip = {
      'sign',
      'timestamp',
      'nonce',
      'deviceId',
      'device_id',
      // 阶段3：legacyDeviceId 仅用于服务端设备指纹迁移，不参与签名
      'legacyDeviceId',
      'legacy_device_id',
    };
    final keys = body.keys.map((k) => k.toString()).where((k) => !skip.contains(k)).toList()
      ..sort();
    final parts = <String>[];
    for (final k in keys) {
      final v = body[k];
      if (v == null) continue;
      parts.add('$k=$v');
    }
    return parts.join('&');
  }

  static String sign({
    required String secret,
    required String path,
    required int timestamp,
    required String nonce,
    required String deviceId,
    required Map<String, dynamic> body,
  }) {
    final msg =
        '$timestamp\n$nonce\n$deviceId\n$path\n${canonicalBody(body)}';
    final dig = Hmac(sha256, utf8.encode(secret)).convert(utf8.encode(msg));
    return dig.toString();
  }
}
