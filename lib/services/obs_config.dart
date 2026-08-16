import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// 确保 OBS WebSocket 配置已开启（写入 %APPDATA%\obs-studio）。
class OBSConfig {
  String get appData =>
      Platform.environment['APPDATA'] ??
      p.join(Platform.environment['USERPROFILE']!, 'AppData', 'Roaming');

  String get newPath => p.join(appData, 'obs-studio');
  String get oldPath => p.join(appData, 'obs-studio');

  String get globalIni => p.join(newPath, 'global.ini');
  String get wsConfig =>
      p.join(newPath, 'plugin_config', 'obs-websocket', 'config.json');

  Future<Map<String, String>> readIni(String path) async {
    final f = File(path);
    if (!await f.exists()) return {};
    final map = <String, String>{};
    var section = '';
    for (final raw in await f.readAsLines()) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#') || line.startsWith(';')) continue;
      if (line.startsWith('[') && line.endsWith(']')) {
        section = line.substring(1, line.length - 1);
        continue;
      }
      final i = line.indexOf('=');
      if (i < 0) continue;
      final k = line.substring(0, i).trim();
      final v = line.substring(i + 1).trim();
      map['$section.$k'] = v;
    }
    return map;
  }

  Future<void> writeIni(String path, Map<String, String> values) async {
    final existing = await readIni(path);
    existing.addAll(values);
    final sections = <String, Map<String, String>>{};
    for (final e in existing.entries) {
      final parts = e.key.split('.');
      final sec = parts.length > 1 ? parts.first : '';
      final key = parts.length > 1 ? parts.sublist(1).join('.') : parts.first;
      sections.putIfAbsent(sec, () => {})[key] = e.value;
    }
    final buf = StringBuffer();
    for (final sec in sections.entries) {
      if (sec.key.isNotEmpty) buf.writeln('[${sec.key}]');
      for (final kv in sec.value.entries) {
        buf.writeln('${kv.key}=${kv.value}');
      }
      buf.writeln();
    }
    await File(path).parent.create(recursive: true);
    await File(path).writeAsString(buf.toString());
  }

  Future<OBSConfigFixResult> handleNew() async => handleCommon();

  Future<OBSConfigFixResult> handleOld() async => handleCommon();

  /// 始终强制写开 WebSocket（文件已存在也可能是 ServerEnabled=false）。
  /// [needRestart]：若改前未启用/有密码，OBS 需重启才能生效。
  Future<OBSConfigFixResult> handleCommon() async {
    final changes = <String>[];
    var needRestart = false;
    try {
      final ws = File(wsConfig);
      await ws.parent.create(recursive: true);

      Map<String, dynamic> json = {};
      if (await ws.exists()) {
        try {
          final raw = jsonDecode(await ws.readAsString());
          if (raw is Map) json = Map<String, dynamic>.from(raw);
        } catch (_) {}
      }

      final wasEnabled = json['server_enabled'] == true ||
          json['ServerEnabled'] == true;
      final hadAuth = json['auth_required'] == true ||
          json['AuthRequired'] == true ||
          ((json['server_password'] ?? json['ServerPassword'] ?? '')
              .toString()
              .isNotEmpty);
      final wrongPort = (json['server_port'] ?? json['ServerPort'] ?? 4455) != 4455;
      needRestart = !wasEnabled || hadAuth || wrongPort;

      // OBS 28+ 用 snake_case；旧配置可能是 PascalCase —— 两边都写
      json['ServerEnabled'] = true;
      json['ServerPort'] = 4455;
      json['AuthRequired'] = false;
      json['AlertsEnabled'] = false;
      json['server_enabled'] = true;
      json['server_port'] = 4455;
      json['auth_required'] = false;
      json['alerts_enabled'] = false;
      json['server_password'] = '';
      json['ServerPassword'] = '';
      json['first_load'] = false;

      await ws.writeAsString(const JsonEncoder.withIndent('  ').convert(json));
      changes.add('启用 WebSocket · 端口 4455 · 关闭身份验证');
      if (needRestart) changes.add('需重启 OBS 生效');
      return OBSConfigFixResult(
        ok: true,
        changes: changes,
        needRestart: needRestart,
      );
    } catch (e) {
      return OBSConfigFixResult(
        ok: false,
        changes: changes,
        error: '$e',
        needRestart: needRestart,
      );
    }
  }

  Future<void> killObsIfRunning() async {
    await Process.run('taskkill', ['/IM', 'obs64.exe', '/F']);
    await Future.delayed(const Duration(milliseconds: 800));
  }

  Future<bool> isObsProcessRunning() async {
    final r = await Process.run('tasklist', ['/FI', 'IMAGENAME eq obs64.exe', '/NH']);
    final out = '${r.stdout}'.toLowerCase();
    return out.contains('obs64.exe');
  }

  /// 探测本机 4455 是否已在监听（OBS WebSocket 就绪）。
  Future<bool> isWebsocketPortOpen({
    String host = '127.0.0.1',
    int port = 4455,
  }) async {
    try {
      final s = await Socket.connect(
        host,
        port,
        timeout: const Duration(milliseconds: 600),
      );
      await s.close();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 等到端口开放或超时。
  Future<bool> waitWebsocketPort({
    Duration timeout = const Duration(seconds: 60),
    void Function(String msg)? onProgress,
  }) async {
    final sw = Stopwatch()..start();
    var n = 0;
    while (sw.elapsed < timeout) {
      n++;
      if (await isWebsocketPortOpen()) {
        onProgress?.call('4455 已监听 (第 $n 次探测)');
        return true;
      }
      if (n == 1 || n % 5 == 0) {
        onProgress?.call('等待 OBS WebSocket 4455... ($n)');
      }
      await Future.delayed(const Duration(milliseconds: 800));
    }
    return false;
  }
}

class OBSConfigFixResult {
  final bool ok;
  final List<String> changes;
  final String? error;
  final bool needRestart;
  OBSConfigFixResult({
    required this.ok,
    this.changes = const [],
    this.error,
    this.needRestart = false,
  });
}
