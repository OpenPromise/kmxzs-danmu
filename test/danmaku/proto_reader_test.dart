import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kmxzs/services/danmaku/proto_reader.dart';

void main() {
  group('PbWriter/PbMessage 往返', () {
    test('varint + 字符串 + 嵌套', () {
      final inner = PbWriter();
      inner.stringField(1, '昵称');
      inner.varintField(2, 300); // 超过 127 验证多字节 varint

      final outer = PbWriter();
      outer.varintField(1, 200);
      outer.bytesField(3, inner.takeBytes());
      outer.stringField(5, 'hello');

      final msg = PbMessage(outer.takeBytes());
      expect(msg.intValue(1), 200);
      expect(msg.string(5), 'hello');
      final nested = msg.nested(3);
      expect(nested, isNotNull);
      expect(nested!.string(1), '昵称');
      expect(nested.intValue(2), 300);
    });

    test('repeated 字段收集全部', () {
      final w = PbWriter();
      w.bytesField(1, Uint8List.fromList([1, 2]));
      w.bytesField(1, Uint8List.fromList([3, 4]));
      w.bytesField(1, Uint8List.fromList([5]));
      final msg = PbMessage(w.takeBytes());
      expect(msg.bytesList(1).length, 3);
      expect(msg.bytesList(1)[2], Uint8List.fromList([5]));
    });

    test('未知定长字段跳过不炸', () {
      // field 4 wire type 1（8 字节定长）+ 正常字符串字段
      final raw = <int>[
        0x21, // field 4, wire 1
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x12, 0x02, 0x68, 0x69, // field 2, wire 2, "hi"
      ];
      final msg = PbMessage(raw);
      expect(msg.string(2), 'hi');
    });
  });
}
