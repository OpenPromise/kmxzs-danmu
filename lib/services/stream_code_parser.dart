/// 解析 / 清洗推流码，供 OBS rtmp_custom 使用。
class StreamCodeParser {
  StreamCodeParser._();

  /// 去掉扫描/共享内存带来的脏字符
  static String sanitize(String raw) {
    var s = raw.trim();
    final buf = StringBuffer();
    for (final cu in s.codeUnits) {
      if (cu < 0x20) break;
      buf.writeCharCode(cu);
    }
    s = buf.toString().trim();
    s = s.replaceAll('"', '').replaceAll("'", '');
    while (s.endsWith(r'\')) {
      s = s.substring(0, s.length - 1).trim();
    }
    return s;
  }

  /// 从 rtmp URL / server 字段提取主机名（不含端口）
  static String? hostOf(String raw) {
    final code = sanitize(raw);
    final lower = code.toLowerCase();
    if (!lower.startsWith('rtmp://') && !lower.startsWith('rtmps://')) {
      return null;
    }
    final schemeEnd = code.indexOf('://') + 3;
    final pathStart = code.indexOf('/', schemeEnd);
    final hostPort =
        pathStart < 0 ? code.substring(schemeEnd) : code.substring(schemeEnd, pathStart);
    final colon = hostPort.indexOf(':');
    return colon < 0 ? hostPort : hostPort.substring(0, colon);
  }

  /// 是否私网 / 本地 / 代理假 IP（OBS 通常无法直连）
  static bool isPrivateHost(String? host) {
    if (host == null || host.isEmpty) return false;
    final h = host.toLowerCase();
    if (h == 'localhost') return true;
    if (h == '0.0.0.0') return true;

    final parts = h.split('.');
    if (parts.length == 4 && parts.every((p) => int.tryParse(p) != null)) {
      final a = int.parse(parts[0]);
      final b = int.parse(parts[1]);
      if (a == 10) return true;
      if (a == 127) return true;
      if (a == 192 && b == 168) return true;
      if (a == 172 && b >= 16 && b <= 31) return true;
      // Clash Meta fake-ip 常用段
      if (a == 198 && b == 18) return true;
      if (a == 169 && b == 254) return true;
      return false;
    }
    // 非纯 IP 的域名一般可公网解析
    return false;
  }

  static bool isPrivateRtmpUrl(String raw) => isPrivateHost(hostOf(raw));

  static final _ipv4 = RegExp(r'^\d+\.\d+\.\d+\.\d+$');

  static bool isIpv4(String? host) =>
      host != null && _ipv4.hasMatch(host);

  /// 把 rtmp URL / server 里的主机名替换成指定 IP（保留端口与路径）
  static String replaceHost(String raw, String newHost) {
    final code = sanitize(raw);
    final lower = code.toLowerCase();
    if (!lower.startsWith('rtmp://') && !lower.startsWith('rtmps://')) {
      return code;
    }
    final schemeEnd = code.indexOf('://') + 3;
    final pathStart = code.indexOf('/', schemeEnd);
    final hostPort =
        pathStart < 0 ? code.substring(schemeEnd) : code.substring(schemeEnd, pathStart);
    final colon = hostPort.indexOf(':');
    final port = colon < 0 ? '' : hostPort.substring(colon);
    final prefix = code.substring(0, schemeEnd);
    final suffix = pathStart < 0 ? '' : code.substring(pathStart);
    return '$prefix$newHost$port$suffix';
  }

  /// 从扫描样本里挑一个公网 IPv4（排除内网 / fake-ip）
  static String? publicIpv4FromSamples(Iterable<String> samples) {
    final ips = <String>{};
    for (final s in samples) {
      final h = hostOf(s);
      if (h != null && isIpv4(h) && !isPrivateHost(h)) ips.add(h);
    }
    return ips.isEmpty ? null : ips.first;
  }

  /// 拆成 OBS 的 server + key
  static ({String server, String key}) split(String raw) {
    final code = sanitize(raw);
    if (code.contains('|')) {
      final parts = code.split('|');
      return (
        server: sanitize(parts[0]),
        key: sanitize(parts.sublist(1).join('|')),
      );
    }

    final lower = code.toLowerCase();
    if (lower.startsWith('rtmp://') || lower.startsWith('rtmps://')) {
      // rtmp://host/app/streamKey?... → server=rtmp://host/app , key=streamKey?...
      final schemeEnd = code.indexOf('://') + 3;
      final pathStart = code.indexOf('/', schemeEnd);
      if (pathStart < 0) {
        return (server: code, key: '');
      }
      final second = code.indexOf('/', pathStart + 1);
      if (second < 0) {
        return (server: code, key: '');
      }
      return (
        server: code.substring(0, second),
        key: sanitize(code.substring(second + 1)),
      );
    }

    return (server: code, key: '');
  }

  /// 候选评分：越高越适合直接给 OBS 推流
  static int scorePushUrl(String raw) {
    final code = sanitize(raw);
    final lower = code.toLowerCase();
    if (!lower.startsWith('rtmp://') && !lower.startsWith('rtmps://')) {
      return -1000;
    }
    if (code.length < 20 || !code.contains('/')) return -500;

    var score = 0;
    final host = hostOf(code);
    if (host == null) return -500;

    if (isPrivateHost(host)) {
      score -= 200;
    } else if (RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(host)) {
      score += 20; // 公网 IP
    } else {
      score += 100; // 域名最优
    }

    if (lower.contains('gifshow') ||
        lower.contains('kuaishou') ||
        lower.contains('ksapisrv') ||
        lower.contains('yximgs')) {
      score += 40;
    }
    if (lower.contains('channelid=')) score += 30;
    if (lower.contains('?')) score += 10;
    // 拉流/预览常见噪声
    if (lower.contains('/pull') || lower.contains('flv') || lower.contains('m3u8')) {
      score -= 40;
    }
    return score;
  }
}
