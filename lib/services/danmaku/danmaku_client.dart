import '../flv_extractor.dart';
import 'bilibili_danmaku_client.dart';
import 'danmaku_message.dart';

/// 弹幕客户端抽象：连接直播间弹幕通道并产出归一化消息流。
abstract class DanmakuClient {
  String get platform;

  String get roomId;

  /// 界面展示用平台名（如「B站」）。
  String get platformLabel;

  /// 归一化弹幕流（单播，由实现方保证只在一个 Zone 内派发）。
  Stream<DanmakuMessage> get messages;

  /// 建立连接；失败抛异常。连接后消息异步到达 [messages]。
  Future<void> connect();

  /// 断开并释放资源；可重复创建新实例。
  Future<void> dispose();
}

/// 按平台创建弹幕客户端；暂不支持的平台抛 [UnsupportedError]。
class DanmakuClientFactory {
  DanmakuClientFactory._();

  static bool supports(LivePlatform platform) {
    switch (platform) {
      case LivePlatform.bilibili:
        return true;
      case LivePlatform.kuaishou:
      case LivePlatform.douyin:
      case LivePlatform.xiaohongshu:
      case LivePlatform.youtube:
      case LivePlatform.tiktok:
      case LivePlatform.huya:
      case LivePlatform.douyu:
      case LivePlatform.unknown:
        return false;
    }
  }

  static DanmakuClient create({
    required LivePlatform platform,
    required String roomId,
  }) {
    switch (platform) {
      case LivePlatform.bilibili:
        return BilibiliDanmakuClient(roomId: roomId);
      case LivePlatform.kuaishou:
      case LivePlatform.douyin:
      case LivePlatform.xiaohongshu:
      case LivePlatform.youtube:
      case LivePlatform.tiktok:
      case LivePlatform.huya:
      case LivePlatform.douyu:
      case LivePlatform.unknown:
        throw UnsupportedError('平台暂不支持弹幕: $platform');
    }
  }
}
