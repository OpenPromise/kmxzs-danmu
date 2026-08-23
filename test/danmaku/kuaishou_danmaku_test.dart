import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kmxzs/services/danmaku/danmaku_message.dart';
import 'package:kmxzs/services/danmaku/kuaishou_danmaku_client.dart';
import 'package:kmxzs/services/danmaku/proto_reader.dart';

void main() {
  group('快手进房与心跳包', () {
    test('进房包结构正确', () {
      final packet = KuaishouDanmakuClient.buildEnterRoomPacket('tok123', 'pid456');
      final outer = PbMessage(packet);
      expect(outer.intValue(1), 200); // CS_ENTER_ROOM
      expect(outer.intValue(2), 1); // compression NONE
      final enter = outer.nested(3);
      expect(enter, isNotNull);
      expect(enter!.intValue(1), 200);
      final payload = enter.nested(3);
      expect(payload, isNotNull);
      expect(payload!.string(1), 'tok123');
      expect(payload.string(2), 'pid456');
    });

    test('心跳包为 CS_PING(4)', () {
      final packet = KuaishouDanmakuClient.buildHeartbeatPacket();
      final outer = PbMessage(packet);
      expect(outer.intValue(1), 4);
      expect(outer.intValue(2), 1);
    });
  });

  group('快手 SC_FEED_PUSH 解析', () {
    List<int> buildFeed({
      List<(String, String)> comments = const [],
      List<(String, int, int)> gifts = const [],
    }) {
      final feed = PbWriter();
      for (final (name, content) in comments) {
        final user = PbWriter();
        user.stringField(2, name);
        final comment = PbWriter();
        comment.bytesField(2, user.takeBytes());
        comment.stringField(3, content);
        feed.bytesField(5, comment.takeBytes());
      }
      for (final (name, giftId, batch) in gifts) {
        final user = PbWriter();
        user.stringField(2, name);
        final gift = PbWriter();
        gift.bytesField(2, user.takeBytes());
        gift.varintField(4, giftId);
        gift.varintField(7, batch);
        gift.varintField(17, 1); // danmakuDisplay
        feed.bytesField(9, gift.takeBytes());
      }
      return feed.takeBytes();
    }

    test('弹幕与礼物同时解析', () {
      final raw = buildFeed(
        comments: [('张三', '第一'), ('李四', '第二')],
        gifts: [('土豪', 1001, 2)],
      );
      final msgs = KuaishouDanmakuClient.parseFeedPayload(raw);
      expect(msgs.length, 3);
      expect(msgs[0].user, '张三');
      expect(msgs[0].content, '第一');
      expect(msgs[1].user, '李四');
      expect(msgs[1].content, '第二');
      expect(msgs[2].kind, DanmakuKind.gift);
      expect(msgs[2].user, '土豪');
      expect(msgs[2].giftName, '礼物#1001');
      expect(msgs[2].giftCount, 2);
    });

    test('GZIP 压缩载荷可解压', () {
      final raw = buildFeed(comments: [('压缩哥', 'gzip 内容')]);
      final compressed = gzip.encode(raw);
      final msgs = KuaishouDanmakuClient.parseFeedPayload(
        compressed,
        compressed: true,
      );
      expect(msgs.single.content, 'gzip 内容');
    });

    test('danmakuDisplay=0 的礼物不显示', () {
      final user = PbWriter();
      user.stringField(2, '不显示');
      final gift = PbWriter();
      gift.bytesField(2, user.takeBytes());
      gift.varintField(4, 9);
      gift.varintField(17, 0);
      final feed = PbWriter();
      feed.bytesField(9, gift.takeBytes());
      final msgs = KuaishouDanmakuClient.parseFeedPayload(feed.takeBytes());
      expect(msgs, isEmpty);
    });
  });
}
