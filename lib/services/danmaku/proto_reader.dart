/// 极简 protobuf wire 格式读写（无第三方依赖）。
///
/// 只按字段号收集 varint / length-delimited，忽略 64-bit/32-bit 定长字段，
/// 对平台 schema 变化有容忍度：字段号取不到就返回 null，不影响其它字段。
library;

import 'dart:convert';
import 'dart:typed_data';

/// 顺序读取 protobuf 字段。
class PbReader {
  PbReader(List<int> data) : _data = data;

  final List<int> _data;
  int _pos = 0;

  bool get isDone => _pos >= _data.length;

  /// 读取下一个字段：(字段号, wireType, 值)。
  /// wire 0 → int；wire 2 → Uint8List；wire 1/5 → null（跳过定长字段）。
  /// wire 3/4 是旧式 protobuf group，递归跳过其内容，避免未知字段
  /// 让整帧解析失败。抖音 Webcast schema 变化时偶尔会携带这类字段。
  (int, int, Object?) readField() {
    final tag = _readVarint();
    final field = tag >> 3;
    final wire = tag & 0x07;
    if (field == 0) {
      throw const FormatException('protobuf 字段号无效');
    }
    switch (wire) {
      case 0:
        return (field, wire, _readVarint());
      case 1:
        _skipBytes(8);
        return (field, wire, null);
      case 2:
        final len = _readVarint();
        if (_pos + len > _data.length) {
          throw const FormatException('protobuf length-delimited 越界');
        }
        final bytes = Uint8List.fromList(_data.sublist(_pos, _pos + len));
        _pos += len;
        return (field, wire, bytes);
      case 5:
        _skipBytes(4);
        return (field, wire, null);
      case 3:
        _skipGroup(field);
        return (field, wire, null);
      case 4:
        throw const FormatException('protobuf group 结束标记无匹配开始');
      default:
        throw FormatException('不支持的 protobuf wire type: $wire');
    }
  }

  /// 跳过一个 start-group 及其嵌套字段。
  ///
  /// group 已经是 protobuf 的旧语法，但部分直播协议仍会在未知扩展字段
  /// 中携带它。这里只跳过，不把 group 内容暴露给上层字段访问器。
  void _skipGroup(int startField) {
    while (!isDone) {
      final tag = _readVarint();
      final field = tag >> 3;
      final wire = tag & 0x07;
      if (field == 0) {
        throw const FormatException('protobuf group 内字段号无效');
      }
      if (wire == 4) {
        if (field != startField) {
          throw FormatException(
            'protobuf group 结束字段不匹配: $field != $startField',
          );
        }
        return;
      }
      switch (wire) {
        case 0:
          _readVarint();
          break;
        case 1:
          _skipBytes(8);
          break;
        case 2:
          final len = _readVarint();
          _skipBytes(len);
          break;
        case 3:
          _skipGroup(field);
          break;
        case 5:
          _skipBytes(4);
          break;
        default:
          throw FormatException('不支持的 protobuf group wire type: $wire');
      }
    }
    throw const FormatException('protobuf group 未结束');
  }

  void _skipBytes(int count) {
    if (count < 0 || _pos + count > _data.length) {
      throw const FormatException('protobuf 定长字段越界');
    }
    _pos += count;
  }

  int _readVarint() {
    var result = 0;
    var shift = 0;
    while (_pos < _data.length) {
      final b = _data[_pos++];
      result |= (b & 0x7F) << shift;
      if ((b & 0x80) == 0) return result;
      shift += 7;
      if (shift >= 64) {
        throw const FormatException('protobuf varint 过长');
      }
    }
    throw const FormatException('protobuf varint 未结束');
  }
}

/// 一次解析后的消息：按字段号保留全部值（repeated 会收集多个）。
class PbMessage {
  PbMessage(List<int> data) {
    final reader = PbReader(data);
    while (!reader.isDone) {
      final (field, _, value) = reader.readField();
      if (value != null) {
        _values.putIfAbsent(field, () => []).add(value);
      }
    }
  }

  final Map<int, List<Object>> _values = {};

  bool get isEmpty => _values.isEmpty;

  int? intValue(int field) {
    for (final v in _values[field] ?? const <Object>[]) {
      if (v is int) return v;
    }
    return null;
  }

  Uint8List? bytes(int field) {
    final list = _values[field];
    if (list == null || list.isEmpty) return null;
    for (final v in list.reversed) {
      if (v is Uint8List) return v;
    }
    return null;
  }

  List<Uint8List> bytesList(int field) {
    final out = <Uint8List>[];
    for (final v in _values[field] ?? const <Object>[]) {
      if (v is Uint8List) out.add(v);
    }
    return out;
  }

  String? string(int field) {
    final b = bytes(field);
    return b == null ? null : utf8.decode(b, allowMalformed: true);
  }

  PbMessage? nested(int field) {
    final b = bytes(field);
    return b == null ? null : PbMessage(b);
  }

  List<PbMessage> nestedList(int field) =>
      bytesList(field).map(PbMessage.new).toList();

  /// 原始字段列表（诊断用）：(字段号, wireType, int 或 Uint8List)。
  List<(int, int, Object?)> rawFields() {
    final out = <(int, int, Object?)>[];
    _values.forEach((field, values) {
      for (final v in values) {
        out.add((field, v is int ? 0 : 2, v));
      }
    });
    return out;
  }
}

/// 顺序写出 protobuf 字段。
class PbWriter {
  final List<int> _out = [];

  void varintField(int field, int value) {
    _tag(field, 0);
    _varint(value);
  }

  void bytesField(int field, List<int> value) {
    _tag(field, 2);
    _varint(value.length);
    _out.addAll(value);
  }

  void stringField(int field, String value) =>
      bytesField(field, utf8.encode(value));

  List<int> takeBytes() => List.unmodifiable(_out);

  void _tag(int field, int wire) => _varint((field << 3) | wire);

  void _varint(int value) {
    var v = value;
    while (true) {
      final b = v & 0x7F;
      v >>>= 7;
      if (v == 0) {
        _out.add(b);
        return;
      }
      _out.add(b | 0x80);
    }
  }
}
