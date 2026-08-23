import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kmxzs/services/danmaku/bilibili_danmaku_client.dart';
import 'package:kmxzs/services/danmaku/danmaku_message.dart';

void main() {
  group('B站二进制封包', () {
    test('buildPacket 头部字段正确', () {
      final body = utf8.encode('{"cmd":"DANMU_MSG"}');
      final packet = BilibiliDanmakuClient.buildPacket(
        op: BilibiliDanmakuClient.opNotify,
        version: 0,
        body: body,
      );
      final header = BilibiliDanmakuClient.parseHeader(packet);
      expect(header.total, 16 + body.length);
      expect(header.headerLen, 16);
      expect(header.version, 0);
      expect(header.op, BilibiliDanmakuClient.opNotify);
      expect(header.seq, 1);
    });

    test('认证包携带 protover=2 与真实房间号', () {
      final packet = BilibiliDanmakuClient.buildAuthPacket(21452505, 'token123');
      final header = BilibiliDanmakuClient.parseHeader(packet);
      expect(header.op, BilibiliDanmakuClient.opAuth);
      final map = jsonDecode(utf8.decode(packet.sublist(header.headerLen)));
      expect(map['roomid'], 21452505);
      expect(map['protover'], 2);
      expect(map['platform'], 'web');
      expect(map['key'], 'token123');
    });

    test('心跳包只有 16 字节头部', () {
      final packet = BilibiliDanmakuClient.buildHeartbeatPacket();
      expect(packet.length, 16);
      expect(
        BilibiliDanmakuClient.parseHeader(packet).op,
        BilibiliDanmakuClient.opHeartbeat,
      );
    });
  });

  group('拆包与 zlib 解压', () {
    test('zlib 压缩的多包能完整拆回', () {
      final inner = BilibiliDanmakuClient.buildPacket(
        op: BilibiliDanmakuClient.opNotify,
        version: 0,
        body: utf8.encode('{"cmd":"DANMU_MSG"}'),
      );
      final two = [...inner, ...inner];
      final compressed = ZLibEncoder().convert(two);
      final frames = BilibiliDanmakuClient.inflatePayload(
        version: BilibiliDanmakuClient.protoZlib,
        body: compressed,
      );
      expect(frames.length, 2);
      for (final f in frames) {
        expect(
          BilibiliDanmakuClient.parseHeader(f).op,
          BilibiliDanmakuClient.opNotify,
        );
      }
    });

    test('brotli 版本暂不解析，返回空列表', () {
      final frames = BilibiliDanmakuClient.inflatePayload(
        version: BilibiliDanmakuClient.protoBrotli,
        body: [1, 2, 3],
      );
      expect(frames, isEmpty);
    });

    test('普通版本包原样返回', () {
      final frames = BilibiliDanmakuClient.inflatePayload(
        version: BilibiliDanmakuClient.protoPlain,
        body: utf8.encode('{"cmd":"DANMU_MSG"}'),
      );
      expect(frames.length, 1);
    });
  });

  group('消息解析', () {
    test('DANMU_MSG 提取昵称与内容', () {
      final msg = BilibiliDanmakuClient.parseMessage({
        'cmd': 'DANMU_MSG',
        'info': [
          0,
          '主播好棒',
          [123, '小明', 0],
        ],
      });
      expect(msg, isNotNull);
      expect(msg!.platform, 'bilibili');
      expect(msg.user, '小明');
      expect(msg.content, '主播好棒');
      expect(msg.kind, DanmakuKind.chat);
    });

    test('JSON 字符串形式也能解析', () {
      final msg = BilibiliDanmakuClient.parseMessage(
        '{"cmd":"DANMU_MSG","info":[0,"你好",[1,"昵称",0]]}',
      );
      expect(msg, isNotNull);
      expect(msg!.user, '昵称');
      expect(msg.content, '你好');
    });

    test('SEND_GIFT 提取礼物与数量', () {
      final msg = BilibiliDanmakuClient.parseMessage({
        'cmd': 'SEND_GIFT',
        'data': {'uname': '土豪', 'giftName': '小电视', 'num': 5},
      });
      expect(msg, isNotNull);
      expect(msg!.kind, DanmakuKind.gift);
      expect(msg.user, '土豪');
      expect(msg.giftName, '小电视');
      expect(msg.giftCount, 5);
    });

    test('SUPER_CHAT_MESSAGE 提取醒目留言', () {
      final msg = BilibiliDanmakuClient.parseMessage({
        'cmd': 'SUPER_CHAT_MESSAGE',
        'data': {
          'user_info': {'uname': '老板'},
          'message': '注意听讲',
        },
      });
      expect(msg, isNotNull);
      expect(msg!.kind, DanmakuKind.superChat);
      expect(msg.user, '老板');
      expect(msg.content, '注意听讲');
    });

    test('INTERACT_WORD 标记进场', () {
      final msg = BilibiliDanmakuClient.parseMessage({
        'cmd': 'INTERACT_WORD',
        'data': {'uname': '路人甲'},
      });
      expect(msg, isNotNull);
      expect(msg!.kind, DanmakuKind.enter);
      expect(msg.user, '路人甲');
    });

    test('未知命令返回 null', () {
      expect(BilibiliDanmakuClient.parseMessage({'cmd': 'WATCHED_CHANGE'}), isNull);
      expect(BilibiliDanmakuClient.parseMessage('不是 JSON'), isNull);
    });
  });
}
