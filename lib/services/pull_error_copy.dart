import 'package:kmxzs/services/flv_extractor.dart';

/// 把拉流失败原文收成用户可见提示，避免把抖音等平台的失败误判成快手风控。
abstract final class PullErrorCopy {
  static String userFacing(
    String raw, {
    LivePlatform platform = LivePlatform.unknown,
  }) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '拉流提取失败，请检查链接与网络';

    final visible = visibleLines(trimmed);
    final lower = trimmed.toLowerCase();
    final kuaishou = platform == LivePlatform.kuaishou ||
        trimmed.contains('快手房间') ||
        trimmed.contains('已触发快手风控') ||
        trimmed.contains('livedetail.result');

    if (kuaishou) {
      if (lower.contains('result=2') ||
          trimmed.contains('操作频繁') ||
          trimmed.contains('操作过于频繁') ||
          trimmed.contains('操作太快') ||
          trimmed.contains('已触发快手风控') ||
          trimmed.contains('已风控')) {
        return '操作过于频繁，请关闭代理后等几分钟再试';
      }
      if (lower.contains('400002') ||
          trimmed.contains('缺少 web_st') ||
          trimmed.contains('请先登录快手账号')) {
        return '请先登录快手账号后再试';
      }
      if (visible.isNotEmpty) return visible;
    }

    if (visible.isNotEmpty) return visible;

    if (lower.contains('timeout') ||
        lower.contains('timed out') ||
        trimmed.contains('连接')) {
      return '网络连接失败。若开了代理，请先关闭或将目标域名设为直连';
    }
    return '拉流失败，请检查直播间链接与网络后重试';
  }

  /// 去掉调试笔记，只保留给用户看的前几行。
  static String visibleLines(String raw) {
    final kept = <String>[];
    for (final line in raw.split('\n')) {
      final t = line.trim();
      if (t.isEmpty) {
        if (kept.isNotEmpty) break;
        continue;
      }
      if (_isDebugNote(t)) break;
      kept.add(t);
      if (kept.length >= 3) break;
    }
    return kept.join('\n');
  }

  static bool _isDebugNote(String line) {
    final l = line.toLowerCase();
    return l.startsWith('来源:') ||
        l.startsWith('来源：') ||
        l.startsWith('已获取') ||
        l.startsWith('获取 cookie') ||
        l.startsWith('页面兜底') ||
        l.startsWith('房间=') ||
        l.startsWith('cookie:') ||
        l.contains('ttwid') ||
        l.contains('status_code') ||
        l.contains('live_status=') ||
        l.contains('pc页失败') ||
        l.contains('livedetail');
  }
}
