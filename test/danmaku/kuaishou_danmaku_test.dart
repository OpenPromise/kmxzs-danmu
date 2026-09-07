import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kmxzs/services/danmaku/danmaku_message.dart';
import 'package:kmxzs/services/danmaku/kuaishou_danmaku_client.dart';
import 'package:kmxzs/services/danmaku/proto_reader.dart';

void main() {
  group('快手进房与心跳包', () {
    test('进房包结构正确', () {
      final packet = KuaishouDanmakuClient.buildEnterRoomPacket(
        'tok123',
        'stream456',
        pageId: 'page_123',
      );
      final outer = PbMessage(packet);
      expect(outer.intValue(1), 200); // CS_ENTER_ROOM
      expect(outer.intValue(2), 1); // compression NONE
      final payload = outer.nested(3);
      expect(payload, isNotNull);
      expect(payload!.string(1), 'tok123');
      expect(payload.string(2), 'stream456');
      expect(payload.string(7), 'page_123');
    });

    test('心跳包为 CS_HEARTBEAT(1) 并携带时间戳', () {
      final packet =
          KuaishouDanmakuClient.buildHeartbeatPacket(timestamp: 123456789);
      final outer = PbMessage(packet);
      expect(outer.intValue(1), 1);
      expect(outer.intValue(2), 1);
      expect(outer.nested(3)?.intValue(1), 123456789);
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

  test('真实 WebSocket 流程会发送进房包并等待服务端确认', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final received = Completer<List<int>>();
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen((data) {
        if (data is! List<int>) return;
        final outer = PbMessage(data);
        if (outer.intValue(1) != KuaishouDanmakuClient.csEnterRoom) return;
        if (!received.isCompleted) received.complete(data);
        final ack = PbWriter()
          ..varintField(1, KuaishouDanmakuClient.scEnterRoomAck)
          ..varintField(2, KuaishouDanmakuClient.compressionNone)
          ..bytesField(3, const [0x08, 0x01]);
        socket.add(ack.takeBytes());
      });
    });
    final client = KuaishouDanmakuClient(
      roomId: '3x-test',
      wsUrl: 'ws://127.0.0.1:${server.port}',
      token: 'token-test',
      liveStreamId: 'stream-test',
    );
    try {
      await client.connect();
      final packet = PbMessage(await received.future);
      final enter = packet.nested(3)!;
      expect(enter.string(1), 'token-test');
      expect(enter.string(2), 'stream-test');
      expect(enter.string(7), isNotEmpty);
    } finally {
      await client.dispose();
      await server.close(force: true);
    }
  });
}
