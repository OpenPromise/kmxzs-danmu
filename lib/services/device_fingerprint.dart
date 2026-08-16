import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

/// 设备指纹：用 Windows 机器唯一标识 MachineGuid 与现有主机信息做哈希，比
/// 旧的 `win-主机名-CPU数` 更稳定（改主机名不换指纹）。保留旧指纹作为
/// [legacyId]，供登录时携带，服务端对老账号做一次静默迁移。
abstract final class DeviceFingerprint {
  /// 旧版指纹：老客户端一直用它绑定设备（服务端已存有这些记录）。
  static Future<String> legacyId() async {
    return 'win-${Platform.localHostname}-${Platform.numberOfProcessors}';
  }

  /// 从注册表读取 Windows MachineGuid。
  /// `HKLM\SOFTWARE\Microsoft\Cryptography\MachineGuid`
  static Future<String?> machineGuid() async {
    if (!Platform.isWindows) return null;
    try {
      final result = await Process.run('reg', [
        'query',
        r'HKLM\SOFTWARE\Microsoft\Cryptography',
        '/v',
        'MachineGuid',
      ]);
      if (result.exitCode != 0) return null;
      final out = '${result.stdout}';
      final m = RegExp(
        r'MachineGuid\s+REG_SZ\s+(\{[0-9A-Fa-f-]+\}|\S+)',
      ).firstMatch(out);
      return m?.group(1)?.trim();
    } catch (e) {
      // 读不到 MachineGuid 时回退旧指纹，不阻断登录
      debugPrint('[fingerprint] 读取 MachineGuid 失败: $e');
      return null;
    }
  }

  /// 当前（新）指纹：MachineGuid 与主机信息哈希，读不到时回退旧指纹。
  static Future<String> currentId() async {
    final guid = await machineGuid();
    if (guid == null || guid.isEmpty) return legacyId();
    final host = Platform.localHostname;
    final cpus = Platform.numberOfProcessors;
    final digest = sha256.convert(utf8.encode('$guid|$host|$cpus'));
    return 'win-${digest.toString().substring(0, 32)}';
  }
}
