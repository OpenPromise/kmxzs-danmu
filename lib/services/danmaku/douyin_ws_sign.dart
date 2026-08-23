import 'dart:math';

import 'package:crypto/crypto.dart';

/// 抖音网页端 WebSocket 握手签名（webmssdk.js 紧凑签名，2025+ 版本）。
///
/// 输入 `X-MS-STUB`（由固定参数字段拼成的 MD5 hex），输出 16 字符 signature：
/// 10 字节载荷（计数器/环境码/行为码/摘要字节/随机数/校验和）经 RC4 加密后，
/// 加 2 字节头部，用自定义字母表 base64（无填充）编码。
class DouyinWsSigner {
  DouyinWsSigner({Random? random}) : _random = random ?? Random.secure();

  final Random _random;
  int _counter = 0;

  static const _alphabet =
      'Dkdpgh4ZKsQB80/Mfvw36XI1R25+WUAlEi7NLboqYTOPuzmFjJnryx9HVGcaStCe';

  static const _websocketModeFlag = 0x40;
  static const _environmentCode = 1;
  static const _userBehaviorCode = 14;

  /// 生成下一个 16 字符签名（每次调用序号自增）。
  String sign(String xMsStub) {
    final stubBytes = _hexDecode(xMsStub);
    final stubDigest = md5.convert(stubBytes).bytes;
    final emptyDigest = md5.convert(md5.convert(const []).bytes).bytes;

    final counter = (_counter = (_counter + 1) & 0x3F);
    final flagRandom = _nextByte(excludeFF: false);
    final payloadRandom = _nextByte(excludeFF: true);
    final keyRandom = _nextByte(excludeFF: true);

    final payload = <int>[
      counter,
      0,
      _environmentCode,
      _userBehaviorCode,
      emptyDigest[14],
      emptyDigest[15],
      stubDigest[14],
      stubDigest[15],
      payloadRandom,
      0, // 校验和占位
    ];
    for (var i = 0; i < payload.length - 1; i++) {
      payload[payload.length - 1] ^= payload[i];
    }

    final encrypted = _rc4(payload, [keyRandom]);
    var flags = _websocketModeFlag;
    if (flagRandom & 1 == 1) flags |= 0x10;
    return _encodeCustomBase64([flags, keyRandom, ...encrypted]);
  }

  /// 显式状态签名，用于与 JS/Go 参考实现做确定性对齐测试。
  static String signWithValues(
    String xMsStub, {
    required int counter,
    required bool randomFlag,
    required int payloadRandom,
    required int keyRandom,
  }) {
    final stubBytes = _hexDecode(xMsStub);
    final stubDigest = md5.convert(stubBytes).bytes;
    final emptyDigest = md5.convert(md5.convert(const []).bytes).bytes;

    final payload = <int>[
      counter & 0x3F,
      0,
      _environmentCode,
      _userBehaviorCode,
      emptyDigest[14],
      emptyDigest[15],
      stubDigest[14],
      stubDigest[15],
      payloadRandom,
      0,
    ];
    for (var i = 0; i < payload.length - 1; i++) {
      payload[payload.length - 1] ^= payload[i];
    }

    final encrypted = _rc4(payload, [keyRandom]);
    var flags = _websocketModeFlag;
    if (randomFlag) flags |= 0x10;
    return _encodeCustomBase64([flags, keyRandom, ...encrypted]);
  }

  static String _encodeCustomBase64(List<int> data) {
    final out = StringBuffer();
    for (var i = 0; i < data.length; i += 3) {
      final b0 = data[i];
      final b1 = i + 1 < data.length ? data[i + 1] : 0;
      final b2 = i + 2 < data.length ? data[i + 2] : 0;
      final n = (b0 << 16) | (b1 << 8) | b2;
      out.write(_alphabet[(n >> 18) & 0x3F]);
      out.write(_alphabet[(n >> 12) & 0x3F]);
      if (i + 1 < data.length) out.write(_alphabet[(n >> 6) & 0x3F]);
      if (i + 2 < data.length) out.write(_alphabet[n & 0x3F]);
    }
    return out.toString();
  }

  static List<int> _rc4(List<int> data, List<int> key) {
    final s = List<int>.generate(256, (i) => i);
    var j = 0;
    for (var i = 0; i < 256; i++) {
      j = (j + s[i] + key[i % key.length]) & 0xFF;
      final t = s[i];
      s[i] = s[j];
      s[j] = t;
    }
    var i = 0;
    j = 0;
    final out = List<int>.filled(data.length, 0);
    for (var k = 0; k < data.length; k++) {
      i = (i + 1) & 0xFF;
      j = (j + s[i]) & 0xFF;
      final t = s[i];
      s[i] = s[j];
      s[j] = t;
      out[k] = data[k] ^ s[(s[i] + s[j]) & 0xFF];
    }
    return out;
  }

  static List<int> _hexDecode(String hex) {
    final s = hex.trim();
    final out = <int>[];
    for (var i = 0; i + 1 < s.length; i += 2) {
      out.add(int.parse(s.substring(i, i + 2), radix: 16));
    }
    return out;
  }

  int _nextByte({required bool excludeFF}) {
    while (true) {
      final v = _random.nextInt(256);
      if (!excludeFF || v != 0xFF) return v;
    }
  }
}
