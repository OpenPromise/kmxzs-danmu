/// 直播间弹幕消息：各平台原始数据归一化后的单条消息。
library;

/// 弹幕类型：普通聊天 / 礼物 / 醒目留言（SC）/ 进场 / 系统提示。
enum DanmakuKind { chat, gift, superChat, enter, system, unknown }

class DanmakuMessage {
  const DanmakuMessage({
    required this.platform,
    required this.user,
    required this.content,
    required this.timestamp,
    this.kind = DanmakuKind.chat,
    this.giftName,
    this.giftCount,
  });

  /// 来源平台标识：`bilibili` / `douyin` / `kuaishou` / ...
  final String platform;

  /// 发送者昵称（礼物为送礼人，进场为进入者）。
  final String user;

  /// 弹幕内容；礼物/进场类为友好提示文本。
  final String content;

  final DateTime timestamp;

  final DanmakuKind kind;

  final String? giftName;
  final int? giftCount;

  /// 抖音和快手目前只展示文字弹幕，礼物消息不进入应用列表或 OBS。
  bool get hiddenFromDisplay =>
      kind == DanmakuKind.gift &&
      (platform == 'douyin' || platform == 'kuaishou');

  String get platformLabel {
    switch (platform) {
      case 'bilibili':
        return 'B站';
      case 'douyin':
        return '抖音';
      case 'kuaishou':
        return '快手';
      case 'tiktok':
        return 'TikTok';
      case 'huya':
        return '虎牙';
      case 'douyu':
        return '斗鱼';
      case 'youtube':
        return 'YouTube';
      case 'xiaohongshu':
        return '小红书';
      default:
        return platform;
    }
  }

  /// 应用内列表/日志展示文本。
  String get displayText {
    final base = user.isEmpty ? content : '$user：$content';
    switch (kind) {
      case DanmakuKind.gift:
        return '$user 送出 $giftName×$giftCount';
      case DanmakuKind.superChat:
        return '醒目留言 $user：$content';
      case DanmakuKind.enter:
        return '$user 进入直播间';
      case DanmakuKind.system:
        return content;
      case DanmakuKind.chat:
      case DanmakuKind.unknown:
        return base;
    }
  }

  /// 序列化给本地弹幕桥（OBS 浏览器源）使用。
  Map<String, Object?> toJson() => {
        'platform': platform,
        'user': user,
        'content': content,
        'ts': timestamp.millisecondsSinceEpoch,
        'kind': kind.name,
        if (giftName != null) 'giftName': giftName,
        if (giftCount != null) 'giftCount': giftCount,
      };

  factory DanmakuMessage.fromJson(Map<String, Object?> json) =>
      DanmakuMessage(
        platform: '${json['platform'] ?? ''}',
        user: '${json['user'] ?? ''}',
        content: '${json['content'] ?? ''}',
        timestamp:
            DateTime.fromMillisecondsSinceEpoch((json['ts'] as num?)?.toInt() ?? 0),
        kind: DanmakuKind.values.asNameMap()['${json['kind']}'] ??
            DanmakuKind.unknown,
        giftName: json['giftName'] as String?,
        giftCount: (json['giftCount'] as num?)?.toInt(),
      );
}
