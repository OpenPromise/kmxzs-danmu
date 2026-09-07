import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// 商业化客户端配置：服务端地址不出现在 UI。
///
/// 优先级（高→低）：
/// 1. 可执行文件同目录 `kmxzs.config.json`（私有部署运维用，用户无感知）
/// 2. 编译参数 `--dart-define=KMXZS_API_BASE=...`
/// 3. [defaultApiBase]
///
/// API 签名密钥仅允许编译期注入（不要写进 config.json，避免被拷走）。
/// 证书指纹与更新公钥同样仅允许编译期注入。
class AppConfig {
  AppConfig._();

  /// 发行默认地址。上线请用 dart-define 或旁路 config 写成 `https://服务器IP:18443`。
  ///
  /// 阶段3：默认走 HTTPS（Caddy 反代 + IP 自签证书），客户端做证书绑定。
  static const defaultApiBase = String.fromEnvironment(
    'KMXZS_API_BASE',
    defaultValue: 'https://127.0.0.1:18443',
  );

  /// 与服务端 `KMXZS_API_SECRET` 相同；生产 Release 必须配置。
  static const apiSecret = String.fromEnvironment(
    'KMXZS_API_SECRET',
    defaultValue: '',
  );

  /// 服务器自签证书的 SHA-256 指纹（hex 或 base64，由
  /// `server/scripts/export-cert-fingerprint.sh` 导出）。未配置（开发调试）时
  /// 允许连接但打印告警；配置后不匹配的证书一律拒绝。
  static const certSha256 = String.fromEnvironment(
    'KMXZS_CERT_SHA256',
    defaultValue: '',
  );

  /// 更新安装包 Ed25519 公钥（base64，来自服务器 `/data/release_signing.pub`）。
  /// 未配置时更新安装会拒绝执行（防投毒）。
  static const updatePubKey = String.fromEnvironment(
    'KMXZS_UPDATE_PUBKEY',
    defaultValue: '',
  );

  static const productName = '快马小助手';
  static const publisher = '桦中科技';
  static const supportHint = '如遇登录问题，请联系发卡方处理';

  /// 是否向用户开放抖音随机轮播。
  static const randomDouyinFeatureEnabled = true;

  static String? _resolvedBase;
  static bool _loaded = false;

  static String get apiBaseUrl {
    assert(_loaded, 'AppConfig.load() must be called before apiBaseUrl');
    return _resolvedBase ?? defaultApiBase;
  }

  static bool get hasApiSecret => apiSecret.trim().isNotEmpty;

  static bool get hasCertPin => certSha256.trim().isNotEmpty;

  static Future<void> load() async {
    if (_loaded) return;
    _resolvedBase = await _readSidecarConfig() ?? defaultApiBase;
    _loaded = true;
  }

  /// 读取 exe 旁的 kmxzs.config.json，例如：{"apiBase":"https://1.2.3.4:18443"}。
  /// 老配置可能是 `http://IP:18088`，升级后自动规范化到 HTTPS 入口，避免新版
  /// 客户端走明文过渡口被拒（过渡口只放行 /config、/files/*、/health）。
  static Future<String?> _readSidecarConfig() async {
    try {
      final exe = Platform.resolvedExecutable;
      final dir = File(exe).parent.path;
      final file = File('$dir${Platform.pathSeparator}kmxzs.config.json');
      if (!await file.exists()) return null;
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map) return null;
      final base = '${raw['apiBase'] ?? raw['api_base'] ?? ''}'.trim();
      if (base.isEmpty) return null;
      return _normalizeHttps(base);
    } catch (e) {
      // 旁路配置损坏/不可读按没有处理，走编译期默认地址
      debugPrint('[config] 读取旁路配置失败: $e');
      return null;
    }
  }

  /// 把旁路配置的 http 地址规范化到 HTTPS 新入口（端口 18088→18443）。
  /// 若运维已写成 https 自定义端口则原样保留。
  static String _normalizeHttps(String raw) {
    var s = raw.replaceAll(RegExp(r'/+$'), '');
    Uri? uri;
    try {
      uri = Uri.parse(s);
    } catch (_) {
      // 非法地址按原字符串返回，交给调用方在连接阶段容错
      uri = null;
    }
    if (uri == null || !uri.hasScheme) return s;
    var scheme = uri.scheme.toLowerCase();
    var port = uri.hasPort ? uri.port : null;
    if (scheme != 'https') {
      scheme = 'https';
      // 老过渡口 18088 → 新 HTTPS 口 18443；其它端口保留用户意图
      if (port == 18088 || port == null) port = 18443;
    }
    final host = uri.host;
    final hostPort = port == null ? '' : ':$port';
    return '$scheme://$host$hostPort';
  }
}
