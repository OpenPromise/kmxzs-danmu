import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kmxzs/services/danmaku/danmaku_message.dart';
import 'package:kmxzs/services/danmaku/douyin_danmaku_client.dart';
import 'package:kmxzs/services/danmaku/douyin_ws_sign.dart';
import 'package:kmxzs/services/danmaku/proto_reader.dart';

void main() {
  group('Douyin 心跳与签名', () {
    test('心跳帧为 3A 02 68 62', () {
      expect(
          DouyinDanmakuClient.buildHeartbeatFrame(), [0x3A, 0x02, 0x68, 0x62]);
    });

    test('X-MS-STUB 为固定参数拼接的 MD5', () {
      final stub = DouyinDanmakuClient.xmsStub('1234567890123456', '');
      final expectJoined = [
        'live_id=1',
        'aid=6383',
        'version_code=180800',
        'webcast_sdk_version=1.0.15',
        'room_id=1234567890123456',
        'sub_room_id=',
        'sub_channel_id=',
        'did_rule=3',
        'user_unique_id=',
        'device_platform=web',
        'device_type=',
        'ac=',
        'identity=audience',
      ].join(',');
      expect(stub, md5.convert(utf8.encode(expectJoined)).toString());
      expect(stub.length, 32);
    });

    test('签名固定输入输出稳定且来自自定义字母表', () {
      const alphabet =
          'Dkdpgh4ZKsQB80/Mfvw36XI1R25+WUAlEi7NLboqYTOPuzmFjJnryx9HVGcaStCe';
      final stub = DouyinDanmakuClient.xmsStub('1234567890123456', '');
      final s1 = DouyinWsSigner.signWithValues(
        stub,
        counter: 1,
        randomFlag: true,
        payloadRandom: 10,
        keyRandom: 20,
      );
      final s2 = DouyinWsSigner.signWithValues(
        stub,
        counter: 1,
        randomFlag: true,
        payloadRandom: 10,
        keyRandom: 20,
      );
      expect(s1, s2);
      expect(s1.length, 16);
      expect(s1.split('').every(alphabet.contains), isTrue);
    });

    test('与 Go 参考实现的确定性向量一致', () {
      // 来自 jwwsjlm/douyinLive internal/webcastsign/native_test.go
      const stub = '704f436b2558b0d7a1c7e758527dd8f1';
      expect(
        DouyinWsSigner.signWithValues(
          stub,
          counter: 1,
          randomFlag: true,
          payloadRandom: 63,
          keyRandom: 63,
        ),
        '6pt0VC0aRZDP7n07',
      );
      expect(
        DouyinWsSigner.signWithValues(
          stub,
          counter: 0,
          randomFlag: false,
          payloadRandom: 0,
          keyRandom: 6,
        ),
        'fD+evFuzasjOC8Uu',
      );
    });
  });

  group('Douyin 弹幕连接准备', () {
    test('12 位 web_rid 会先解析真实房间号，坏 protobuf 会转 POST 重试', () async {
      final adapter = _DouyinPrepareAdapter();
      final dio = Dio()..httpClientAdapter = adapter;

      final prepared = await DouyinDanmakuClient.prepareConnection(
        roomId: '533906493441',
        cookie: '',
        dio: dio,
      );

      expect(prepared.cookie, 'ttwid=fresh-cookie');
      expect(prepared.roomId, '7461234567890123456');
      expect(prepared.userUniqueId, '7682119715171092018');
      expect(prepared.cursor, 'cursor-ok');
      expect(
        prepared.internalExt,
        'internal_src:dim|wss_push_did:7000000000000000001|seq:1',
      );
      expect(prepared.heartbeatDuration, 15);
      expect(prepared.pushServer, 'push.example.com');
      expect(
        adapter.requests.map((request) => request.method),
        ['GET', 'GET', 'GET', 'POST'],
      );
      final fetchRequests = adapter.requests.skip(1);
      expect(
        fetchRequests.every(
          (request) => request.headers['Cookie'] == 'ttwid=fresh-cookie',
        ),
        isTrue,
      );
      final imRequests = adapter.requests.skip(2);
      expect(
        imRequests.every(
          (request) =>
              request.uri.queryParameters['room_id'] == '7461234567890123456' &&
              request.uri.queryParameters['user_unique_id'] ==
                  '7682119715171092018',
        ),
        isTrue,
      );
    });

    test('从 internal_ext 提取 wss_push_did', () {
      expect(
        DouyinDanmakuClient.userUniqueIdFromInternalExt(
          'internal_src:dim|wss_push_room_id:1|'
          'wss_push_did:7682116540599125504|seq:1',
        ),
        '7682116540599125504',
      );
      expect(DouyinDanmakuClient.userUniqueIdFromInternalExt(''), isEmpty);
    });
  });

  group('Douyin 弹幕帧解析', () {
    test('WebcastChatMessage 提取昵称与内容（标准布局）', () {
      final message = PbWriter();
      message.stringField(1, 'WebcastChatMessage');
      final user = PbWriter();
      user.stringField(3, '小明');
      final chat = PbWriter();
      chat.bytesField(2, user.takeBytes());
      chat.stringField(3, '主播好棒');
      message.bytesField(2, chat.takeBytes());
      final resp = PbWriter();
      resp.bytesField(1, message.takeBytes());

      final msgs =
          DouyinDanmakuClient.decodeResponse(PbMessage(resp.takeBytes()));
      expect(msgs.length, 1);
      expect(msgs.first.user, '小明');
      expect(msgs.first.content, '主播好棒');
      expect(msgs.first.platform, 'douyin');
    });

    test('gzip 压缩的 PushFrame 载荷完整走通', () {
      final message = PbWriter();
      message.stringField(1, 'WebcastChatMessage');
      final user = PbWriter();
      user.stringField(3, '路人');
      final chat = PbWriter();
      chat.bytesField(2, user.takeBytes());
      chat.stringField(3, '你好呀');
      message.bytesField(2, chat.takeBytes());
      final resp = PbWriter();
      resp.bytesField(1, message.takeBytes());
      final frame = PbWriter();
      frame.bytesField(8, gzip.encode(resp.takeBytes()));

      final pb = PbMessage(frame.takeBytes());
      final payload = pb.bytes(8)!;
      final decoded = gzip.decode(payload);
      final msgs = DouyinDanmakuClient.decodeResponse(PbMessage(decoded));
      expect(msgs.single.content, '你好呀');
    });

    test('只有含业务 method 的帧才算业务推送', () {
      final heartbeatResponse = PbWriter();
      final heartbeatFrame = PbWriter()
        ..stringField(7, 'hb')
        ..bytesField(8, gzip.encode(heartbeatResponse.takeBytes()));
      expect(
        DouyinDanmakuClient.inspectFrame(heartbeatFrame.takeBytes()).methods,
        isEmpty,
      );

      final message = PbWriter()
        ..stringField(1, 'WebcastRoomStatsMessage')
        ..bytesField(2, const [0x08, 0x01]);
      final response = PbWriter()..bytesField(1, message.takeBytes());
      final businessFrame = PbWriter()
        ..bytesField(8, gzip.encode(response.takeBytes()));
      expect(
        DouyinDanmakuClient.inspectFrame(businessFrame.takeBytes()).methods,
        ['WebcastRoomStatsMessage'],
      );
    });

    test('当前标准布局 user=2/content=3 正常解析', () {
      final user = PbWriter();
      user.stringField(3, '小明'); // 标准 User.nickname=3
      final chat = PbWriter();
      chat.bytesField(2, user.takeBytes());
      chat.stringField(3, '你好呀');
      final message = PbWriter();
      message.stringField(1, 'WebcastChatMessage');
      message.bytesField(2, chat.takeBytes());
      final resp = PbWriter();
      resp.bytesField(1, message.takeBytes());

      final msgs =
          DouyinDanmakuClient.decodeResponse(PbMessage(resp.takeBytes()));
      expect(msgs.single.user, '小明');
      expect(msgs.single.content, '你好呀');
    });

    test('字段 1 为 Common 时不会误当用户（真实抓包布局）', () {
      final common = PbWriter();
      common.stringField(1, 'WebcastChatMessage');
      final user = PbWriter();
      user.varintField(1, 12345);
      user.stringField(3, '真实昵称');
      final chat = PbWriter();
      chat.bytesField(1, common.takeBytes());
      chat.bytesField(2, user.takeBytes());
      chat.stringField(3, '真实弹幕内容');
      final message = PbWriter();
      message.stringField(1, 'WebcastChatMessage');
      message.bytesField(2, chat.takeBytes());
      final resp = PbWriter();
      resp.bytesField(1, message.takeBytes());

      final msgs =
          DouyinDanmakuClient.decodeResponse(PbMessage(resp.takeBytes()));
      expect(msgs.length, 1);
      expect(msgs.single.user, '真实昵称');
      expect(msgs.single.content, '真实弹幕内容');
    });

    test('响应中包含未知 group 时仍能解析弹幕', () {
      final user = PbWriter();
      user.stringField(3, '带扩展字段的用户');
      final chat = PbWriter();
      chat.bytesField(2, user.takeBytes());
      chat.stringField(3, 'group 之后仍可见');
      final messageWithChat = PbWriter();
      messageWithChat.stringField(1, 'WebcastChatMessage');
      messageWithChat.bytesField(2, chat.takeBytes());
      // 未知 field 6 start-group，内部字段结束后再放正常 Message。
      final groupAndMessage = <int>[
        0x33, // field 6, start-group
        0x38, 0x01, // field 7, varint
        0x34, // field 6, end-group
        ...messageWithChat.takeBytes(),
      ];
      final framed = <int>[
        0x0A,
        groupAndMessage.length,
        ...groupAndMessage,
      ];
      final msgs = DouyinDanmakuClient.decodeResponse(PbMessage(framed));
      expect(msgs.single.user, '带扩展字段的用户');
      expect(msgs.single.content, 'group 之后仍可见');
    });

    test('WebcastGiftMessage 提取礼物', () {
      final user = PbWriter();
      user.stringField(1, '土豪');
      final giftStruct = PbWriter();
      giftStruct.stringField(16, '火箭');
      final gift = PbWriter();
      gift.bytesField(7, user.takeBytes());
      gift.varintField(5, 3);
      gift.bytesField(15, giftStruct.takeBytes());
      final message = PbWriter();
      message.stringField(1, 'WebcastGiftMessage');
      message.bytesField(2, gift.takeBytes());
      final resp = PbWriter();
      resp.bytesField(1, message.takeBytes());

      final msgs =
          DouyinDanmakuClient.decodeResponse(PbMessage(resp.takeBytes()));
      expect(msgs.single.kind, DanmakuKind.gift);
      expect(msgs.single.user, '土豪');
      expect(msgs.single.giftName, '火箭');
      expect(msgs.single.giftCount, 3);
    });
  });
}

class _DouyinPrepareAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (options.uri.path == '/') {
      return ResponseBody.fromString(
        '<html></html>',
        200,
        headers: {
          'content-type': ['text/html; charset=utf-8'],
          'set-cookie': ['ttwid=fresh-cookie; Path=/; HttpOnly'],
        },
      );
    }
    if (options.uri.path == '/533906493441') {
      return ResponseBody.fromString(
        r'''<script>window.__STATE__="{\"room\":{\"id_str\":\"7461234567890123456\",\"status\":2},\"user_unique_id\":\"7682119715171092018\"}"</script>''',
        200,
        headers: {
          'content-type': ['text/html; charset=utf-8'],
        },
      );
    }
    if (options.uri.path == '/webcast/im/fetch/') {
      if (options.method == 'GET') {
        // field 4 / wire 1 却只有 2 字节，模拟风控或截断响应。
        return ResponseBody.fromBytes(
          [0x21, 0x01, 0x02],
          200,
          headers: {
            'content-type': ['application/octet-stream'],
          },
        );
      }
      final response = PbWriter()
        ..stringField(2, 'cursor-ok')
        ..stringField(
          5,
          'internal_src:dim|wss_push_did:7000000000000000001|seq:1',
        )
        ..varintField(8, 15)
        ..stringField(10, 'push.example.com');
      return ResponseBody.fromBytes(
        response.takeBytes(),
        200,
        headers: {
          'content-type': ['application/octet-stream'],
        },
      );
    }
    return ResponseBody.fromString('not found', 404);
  }

  @override
  void close({bool force = false}) {}
}
