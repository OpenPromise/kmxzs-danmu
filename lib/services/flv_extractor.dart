import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import 'douyin_abogus.dart';

part 'extractors/bilibili_flv_extractor.dart';
part 'extractors/douyin_flv_extractor.dart';
part 'extractors/douyu_flv_extractor.dart';
part 'extractors/huya_flv_extractor.dart';
part 'extractors/kuaishou_flv_extractor.dart';
part 'extractors/tiktok_flv_extractor.dart';
part 'extractors/xiaohongshu_flv_extractor.dart';
part 'extractors/youtube_flv_extractor.dart';

const _ua =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Safari/537.36';
const _ksUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

/// 单个平台的直播拉流地址提取器。
abstract class PlatformExtractor {
  PlatformExtractor(
    Dio dio, {
    this.kuaishouCookie,
    this.tiktokCookie,
  }) : _dio = dio;

  final Dio _dio;
  String? kuaishouCookie;
  String? tiktokCookie;

  LivePlatform get platform;

  Future<FlvExtractResult> extract(String input);
}

/// 兼容入口：识别平台后将请求委派给独立的平台 extractor。
class FlvExtractor {
  FlvExtractor({Dio? dio, this.kuaishouCookie, this.tiktokCookie})
      : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 15),
                receiveTimeout: const Duration(seconds: 15),
                followRedirects: true,
                maxRedirects: 5,
                validateStatus: (s) => s != null && s < 500,
                headers: const {
                  'User-Agent': _ua,
                  'Accept': 'text/html,application/json,*/*',
                  'Accept-Language': 'zh-CN,zh;q=0.9',
                },
              ),
            );

  static const browserUa = _ua;

  /// 只放行断流测试工具的回环地址，避免把任意 URL 当直播间页解析。
  static bool isAutoStopTestUrl(String input) {
    final uri = Uri.tryParse(input.trim());
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return false;
    }
    final host = uri.host.toLowerCase();
    final loopback = host == '127.0.0.1' || host == 'localhost' || host == '::1';
    return loopback && uri.path == '/auto-stop-test-live-stream.flv';
  }

  final Dio _dio;
  String? kuaishouCookie;
  String? tiktokCookie;

  Future<FlvExtractResult> extract(String input) async {
    final text = input.trim();
    if (text.isEmpty) {
      return FlvExtractResult.fail('请输入直播间链接或房间号');
    }

    if (isAutoStopTestUrl(text)) {
      return FlvExtractResult.ok(
        platform: LivePlatform.unknown,
        roomId: 'auto-stop-test',
        flvUrls: [text],
        hlsUrls: const [],
        allUrls: [text],
        note: '本地自动关播断流测试源',
      );
    }

    final platform = detectPlatform(text);
    try {
      switch (platform) {
        case LivePlatform.kuaishou:
          return await _extractorFor(platform).extract(text);
        case LivePlatform.douyin:
          return await _extractorFor(platform).extract(text);
        case LivePlatform.bilibili:
          return await _extractorFor(platform).extract(text);
        case LivePlatform.xiaohongshu:
          return await _extractorFor(platform).extract(text);
        case LivePlatform.youtube:
          return await _extractorFor(platform).extract(text);
        case LivePlatform.tiktok:
          return await _extractorFor(platform).extract(text);
        case LivePlatform.huya:
          return await _extractorFor(platform).extract(text);
        case LivePlatform.douyu:
          return await _extractorFor(platform).extract(text);
        case LivePlatform.unknown:
          if (RegExp(r'^[A-Za-z0-9_\-]+$').hasMatch(text)) {
            return await _extractorFor(LivePlatform.kuaishou).extract(text);
          }
          if (RegExp(r'^\d+$').hasMatch(text)) {
            final bili =
                await _extractorFor(LivePlatform.bilibili).extract(text);
            if (bili.ok) return bili;
            return _extractorFor(LivePlatform.douyin).extract(text);
          }
          return FlvExtractResult.fail(
            '无法识别平台，请粘贴完整链接（抖音/快手/B站/小红书/YouTube/TikTok）',
          );
      }
    } catch (e) {
      return FlvExtractResult.fail('提取失败: $e');
    }
  }

  PlatformExtractor _extractorFor(LivePlatform platform) {
    return switch (platform) {
      LivePlatform.kuaishou =>
        KuaishouFlvExtractor(_dio, cookie: kuaishouCookie),
      LivePlatform.douyin => DouyinFlvExtractor(_dio),
      LivePlatform.bilibili => BilibiliFlvExtractor(_dio),
      LivePlatform.xiaohongshu => XiaohongshuFlvExtractor(_dio),
      LivePlatform.youtube => YoutubeFlvExtractor(_dio),
      LivePlatform.tiktok => TiktokFlvExtractor(_dio, cookie: tiktokCookie),
      LivePlatform.huya => HuyaFlvExtractor(_dio),
      LivePlatform.douyu => DouyuFlvExtractor(_dio),
      LivePlatform.unknown => throw ArgumentError('未知直播平台'),
    };
  }

  /// 房间号（如 WOT-360-CN）或快手域名链接，走内置浏览器取流。
  static bool looksLikeKuaishou(String text) {
    final t = text.trim();
    if (t.isEmpty) return false;
    final u = t.toLowerCase();
    if (u.contains('kuaishou') ||
        u.contains('gifshow') ||
        u.contains('chenzhongtech')) {
      return true;
    }
    return RegExp(r'^[A-Za-z0-9_\-]+$').hasMatch(t) &&
        !RegExp(r'^\d+$').hasMatch(t);
  }

  FlvExtractResult packPlayUrls({
    required LivePlatform platform,
    required String roomId,
    required List<String> urls,
    String? note,
  }) {
    final flv = <String>[];
    final hls = <String>[];
    for (final raw in urls) {
      final u = _cleanUrl(raw);
      final low = u.toLowerCase();
      if (!low.startsWith('http')) continue;
      if (low.contains('m3u8')) {
        hls.add(u);
      } else if (_looksPlayableFlv(u) ||
          low.contains('.flv') ||
          low.contains('pull-flv')) {
        flv.add(u);
      }
    }
    final flvU = _rankFlv(_uniq(flv.where(_looksPlayableFlv)));
    final hlsU = _uniq(hls.where((u) => u.toLowerCase().contains('m3u8')));
    if (flvU.isEmpty && hlsU.isEmpty) {
      return FlvExtractResult.fail(
        '未拿到可播放地址',
        platform: platform,
        roomId: roomId,
      );
    }
    return FlvExtractResult.ok(
      platform: platform,
      roomId: roomId,
      flvUrls: flvU,
      hlsUrls: hlsU,
      allUrls: [...flvU, ...hlsU],
      note: note,
    );
  }

  LivePlatform detectPlatform(String text) {
    final u = text.toLowerCase();
    if (u.contains('kuaishou') ||
        u.contains('gifshow') ||
        u.contains('chenzhongtech') ||
        u.contains('v.kuaishou')) {
      return LivePlatform.kuaishou;
    }
    if (u.contains('tiktok.com') ||
        u.contains('tiktokv.com') ||
        u.contains('vt.tiktok') ||
        u.contains('vm.tiktok') ||
        (u.startsWith('@') && !u.contains('douyin'))) {
      return LivePlatform.tiktok;
    }
    if (u.contains('douyin') || u.contains('iesdouyin')) {
      return LivePlatform.douyin;
    }
    if (u.contains('xiaohongshu.com') ||
        u.contains('xhslink.com') ||
        u.contains('xhs.cn') ||
        u.contains('xiaohongshu')) {
      return LivePlatform.xiaohongshu;
    }
    if (u.contains('bilibili') ||
        u.contains('b23.tv') ||
        u.contains('bili.tv') ||
        u.contains('live.bilibili')) {
      return LivePlatform.bilibili;
    }
    if (u.contains('youtube.com') ||
        u.contains('youtu.be') ||
        u.contains('youtube.com/live')) {
      return LivePlatform.youtube;
    }
    if (u.contains('huya.com')) return LivePlatform.huya;
    if (u.contains('douyu.com')) return LivePlatform.douyu;
    return LivePlatform.unknown;
  }

  static bool hasKuaishouLoginCookie(String? raw) =>
      KuaishouFlvExtractor.hasKuaishouLoginCookie(raw);

  static String sanitizeCookieHeader(String? raw) =>
      KuaishouFlvExtractor.sanitizeCookieHeader(raw);

  static String? ksLiveStreamChunk(String state) =>
      KuaishouFlvExtractor.ksLiveStreamChunk(state);

  static String ksJsObjectToJson(String raw) =>
      KuaishouFlvExtractor.ksJsObjectToJson(raw);

  static ksParseInitialStateHtml(String body) =>
      KuaishouFlvExtractor.ksParseInitialStateHtml(body);
}

Map<String, dynamic>? _asMap(dynamic data) {
  if (data is Map<String, dynamic>) return data;
  if (data is Map) return Map<String, dynamic>.from(data);
  if (data is String) {
    try {
      final j = jsonDecode(data);
      if (j is Map) return Map<String, dynamic>.from(j);
    } catch (_) {
      // 字符串不是合法 JSON 时按无数据返回，属正常回退
    }
  }
  return null;
}

String? _ttSliceJsonObject(String body, int start) {
  var depth = 0;
  var inStr = false;
  var escape = false;
  for (var i = start; i < body.length; i++) {
    final ch = body[i];
    if (inStr) {
      if (escape) {
        escape = false;
      } else if (ch == '\\') {
        escape = true;
      } else if (ch == '"') {
        inStr = false;
      }
      continue;
    }
    if (ch == '"') {
      inStr = true;
    } else if (ch == '{') {
      depth++;
    } else if (ch == '}') {
      depth--;
      if (depth == 0) return body.substring(start, i + 1);
    }
  }
  return null;
}

Future<List<String>> _ytDlpGetUrls(String url) async {
  final candidates = <List<String>>[
    ['yt-dlp', '-g', '-f', 'b/best', '--no-playlist', url],
    ['yt-dlp.exe', '-g', '-f', 'b/best', '--no-playlist', url],
    ['python', '-m', 'yt_dlp', '-g', '-f', 'b/best', '--no-playlist', url],
    ['py', '-3', '-m', 'yt_dlp', '-g', '-f', 'b/best', '--no-playlist', url],
  ];
  for (final cmd in candidates) {
    try {
      final r = await Process.run(
        cmd.first,
        cmd.sublist(1),
        runInShell: true,
      ).timeout(const Duration(seconds: 45));
      if (r.exitCode != 0) continue;
      final out = '${r.stdout}';
      final urls = <String>[];
      for (final line in out.split(RegExp(r'\r?\n'))) {
        final t = line.trim();
        if (t.startsWith('http')) urls.add(t);
      }
      if (urls.isNotEmpty) return urls;
    } catch (_) {
      // 子进程输出解析失败按无候选处理，正常回退
    }
  }
  return const [];
}

String _cleanUrl(String raw) {
  var u = raw.trim();
  u = u.replaceAll(r'\/', '/');
  u = u.replaceAll(r'\u002F', '/');
  u = u.replaceAll(r'\u002f', '/');
  u = u.replaceAll(r'\u0026', '&');
  u = u.replaceAll(r'\\u0026', '&');
  u = u.replaceAll('&amp;', '&');
  // YouTube googlevideo 路径里常有逗号（met/xxx,/mh/..），绝不能按逗号截断
  if (u.startsWith('http://') || u.startsWith('https://')) {
    // 只去掉尾部 JSON/引号残片，保留 URL 内部逗号
    u = u.split('"').first.split("'").first;
    while (u.endsWith('\\') ||
        u.endsWith(']') ||
        u.endsWith(')') ||
        u.endsWith('}') ||
        u.endsWith(';') ||
        u.endsWith(',')) {
      u = u.substring(0, u.length - 1);
    }
    return u.trim();
  }
  // 非 URL 的旧逻辑（页面残片）
  u = u.split('"').first.split("'").first.split('}').first.split(',').first;
  while (u.endsWith('\\') || u.endsWith(']') || u.endsWith(')')) {
    u = u.substring(0, u.length - 1);
  }
  return u.trim();
}

bool _looksPlayableFlv(String u) {
  final s = u.toLowerCase();
  if (!s.startsWith('http')) return false;
  if (s.contains('only_audio=1')) return false;
  if (s.contains('gifshow.com/fw/live') || s.endsWith('/undefined')) {
    return false;
  }
  if (!(s.contains('.flv') ||
      s.contains('pull-flv') ||
      s.contains('/flv/') ||
      s.contains('filetype=flv') ||
      s.contains('streamtype=flv') ||
      (s.contains('tiktokcdn') && s.contains('flv')))) {
    return false;
  }
  // 太短基本是截断垃圾
  if (u.length < 40) return false;
  return true;
}

/// 清晰度排序：原画/FULL_HD 优先；避开 HEVC/AV1（OBS 兼容性）
List<String> _rankFlv(Iterable<String> urls) {
  final list = urls.toList();
  int score(String u) {
    final s = u.toLowerCase();
    var base = 60;
    if (s.contains('origin') || s.contains('or4') || s.contains('uhd')) {
      base = 100;
    } else if (s.contains('full_hd') ||
        s.contains('hd1') ||
        s.contains('_hd')) {
      base = 80;
    } else if (s.contains('sd1') || s.contains('_sd')) {
      base = 40;
    } else if (s.contains('ld1')) {
      base = 20;
    }
    // B站 hevc / av1 部分机器 OBS 打不开
    if (s.contains('hevc') ||
        s.contains('h265') ||
        s.contains('av1') ||
        s.contains('minihevc')) {
      base -= 40;
    }
    if (s.contains('avc') || s.contains('2500') || s.contains('10000')) {
      base += 5;
    }
    // gotcha 线路比运营商节点更稳；cn-xxx-cu 在 OBS 里常立刻 ended
    if (s.contains('gotcha')) {
      base += 18;
    }
    if (RegExp(r'cn-[a-z0-9]+-(cu|ct|cm)-').hasMatch(s)) {
      base -= 12;
    }
    if (s.contains('xhscdn')) {
      if (s.startsWith('https://')) base += 8;
      if (s.contains('live-source-play-hw') && !s.contains('bak')) base += 10;
      if (s.contains('-bak-')) base -= 6;
    }
    return base;
  }

  list.sort((a, b) {
    final c = score(b).compareTo(score(a));
    if (c != 0) return c;
    return b.length.compareTo(a.length);
  });
  return list;
}

List<String> _uniq(Iterable<String> urls) {
  final seen = <String>{};
  final out = <String>[];
  for (var u in urls) {
    u = _cleanUrl(u);
    if (u.length < 20) continue;
    if (seen.add(u)) out.add(u);
  }
  return out;
}

enum LivePlatform {
  kuaishou,
  douyin,
  bilibili,
  xiaohongshu,
  youtube,
  tiktok,
  huya,
  douyu,
  unknown,
}

class _DyAwemeProbe {
  final bool isVideo;
  final String? author;
  final String? liveWebRid;

  _DyAwemeProbe({
    required this.isVideo,
    this.author,
    this.liveWebRid,
  });
}

class FlvExtractResult {
  final bool ok;
  final String message;
  final LivePlatform platform;
  final String? roomId;
  final List<String> flvUrls;
  final List<String> hlsUrls;
  final List<String> allUrls;
  final String? note;

  FlvExtractResult.ok({
    required this.platform,
    this.roomId,
    required this.flvUrls,
    required this.hlsUrls,
    required this.allUrls,
    this.note,
  })  : ok = true,
        message = '提取成功';

  FlvExtractResult.fail(
    this.message, {
    this.platform = LivePlatform.unknown,
    this.roomId,
  })  : ok = false,
        flvUrls = const [],
        hlsUrls = const [],
        allUrls = const [],
        note = null;

  String bestUrl() {
    if (flvUrls.isNotEmpty) return flvUrls.first;
    if (hlsUrls.isNotEmpty) return hlsUrls.first;
    if (allUrls.isNotEmpty) return allUrls.first;
    return '';
  }

  /// OBS 试播顺序：FLV 优先，再 HLS；已去重。
  List<String> playCandidates({int max = 6}) {
    final seen = <String>{};
    final out = <String>[];
    for (final u in [...flvUrls, ...hlsUrls, ...allUrls]) {
      if (u.trim().isEmpty || !seen.add(u)) continue;
      out.add(u);
      if (out.length >= max) break;
    }
    return out;
  }

  String summary() {
    if (!ok) return message;
    final buf = StringBuffer()
      ..writeln('平台: $platform')
      ..writeln(roomId == null ? '' : '房间: $roomId');
    if (note != null && note!.isNotEmpty) buf.writeln(note);
    if (flvUrls.isNotEmpty) {
      buf.writeln('FLV（优先第一条给 OBS）:');
      for (final u in flvUrls.take(5)) {
        buf.writeln(u);
      }
    }
    if (hlsUrls.isNotEmpty) {
      buf.writeln('HLS:');
      for (final u in hlsUrls.take(3)) {
        buf.writeln(u);
      }
    }
    return buf.toString().trim();
  }
}
