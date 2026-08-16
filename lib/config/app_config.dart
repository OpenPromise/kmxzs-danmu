import 'dart:convert';
import 'dart:io';

/// 商业化客户端配置：服务端地址不出现在 UI。
///
/// 优先级（高→低）：
/// 1. 可执行文件同目录 `kmxzs.config.json`（私有部署运维用，用户无感知）
/// 2. 编译参数 `--dart-define=KMXZS_API_BASE=...`
/// 3. [defaultApiBase]
///
/// API 签名密钥仅允许编译期注入（不要写进 config.json，避免被拷走）。
class AppConfig {
  AppConfig._();

  /// 发行默认地址。上线请用 dart-define 或旁路 config 写成 `http://服务器IP:端口`。
  static const defaultApiBase = String.fromEnvironment(
    'KMXZS_API_BASE',
    defaultValue: 'http://127.0.0.1:18088',
  );

  /// 与服务端 `KMXZS_API_SECRET` 相同；生产 Release 必须配置。
  static const apiSecret = String.fromEnvironment(
    'KMXZS_API_SECRET',
    defaultValue: '',
  );

  static const productName = '快马小助手';
  static const publisher = '桦中科技';
  static const supportHint = '如遇登录问题，请联系发卡方处理';

  static String? _resolvedBase;
  static bool _loaded = false;

  static String get apiBaseUrl {
    assert(_loaded, 'AppConfig.load() must be called before apiBaseUrl');
    return _resolvedBase ?? defaultApiBase;
  }

  static bool get hasApiSecret => apiSecret.trim().isNotEmpty;

  static Future<void> load() async {
    if (_loaded) return;
    _resolvedBase = await _readSidecarConfig() ?? defaultApiBase;
    _loaded = true;
  }

  /// 读取 exe 旁的 kmxzs.config.json，例如：{"apiBase":"http://1.2.3.4:18088"}
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
      return base.replaceAll(RegExp(r'/+$'), '');
    } catch (_) {
      return null;
    }
  }
}
