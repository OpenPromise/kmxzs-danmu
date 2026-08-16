/// 抖音 Web API `a_bogus` 签名（移植自 DouyinLiveRecorder ab_sign.py）。
library;

import 'dart:convert';
import 'dart:math';

class DouyinABogus {
  DouyinABogus({this.fixedStartMs});

  /// 仅用于单元测试对齐；正式调用保持 null。
  final int? fixedStartMs;

  static const _uaDefault =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Safari/537.36';

  static const _windowEnv =
      '1920|1080|1920|1040|0|30|0|0|1872|92|1920|1040|1857|92|1|24|Win32';

  String sign(String urlSearchParams, {String userAgent = _uaDefault}) {
    return _resultEncrypt(
          _generateRandomStr() +
              _generateRc4BbStr(urlSearchParams, userAgent, _windowEnv),
          's4',
        ) +
        '=';
  }

  String _rc4Encrypt(String plaintext, String key) {
    final s = List<int>.generate(256, (i) => i);
    var j = 0;
    for (var i = 0; i < 256; i++) {
      j = (j + s[i] + key.codeUnitAt(i % key.length)) % 256;
      final tmp = s[i];
      s[i] = s[j];
      s[j] = tmp;
    }
    var i = 0;
    j = 0;
    final out = StringBuffer();
    for (var k = 0; k < plaintext.length; k++) {
      i = (i + 1) % 256;
      j = (j + s[i]) % 256;
      final tmp = s[i];
      s[i] = s[j];
      s[j] = tmp;
      final t = (s[i] + s[j]) % 256;
      out.writeCharCode(s[t] ^ plaintext.codeUnitAt(k));
    }
    return out.toString();
  }

  int _leftRotate(int x, int n) {
    n %= 32;
    return ((x << n) | (x >> (32 - n))) & 0xFFFFFFFF;
  }

  int _getTj(int j) {
    if (j < 16) return 2043430169;
    return 2055708042;
  }

  int _ffj(int j, int x, int y, int z) {
    if (j < 16) return (x ^ y ^ z) & 0xFFFFFFFF;
    return ((x & y) | (x & z) | (y & z)) & 0xFFFFFFFF;
  }

  int _ggj(int j, int x, int y, int z) {
    if (j < 16) return (x ^ y ^ z) & 0xFFFFFFFF;
    return ((x & y) | (~x & z)) & 0xFFFFFFFF;
  }

  List<int> _sm3Sum(dynamic data) {
    final sm3 = _SM3(this);
    return sm3.sum(data);
  }

  String _resultEncrypt(String longStr, String num) {
    const tables = {
      's0': 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=',
      's1': 'Dkdpgh4ZKsQB80/Mfvw36XI1R25+WUAlEi7NLboqYTOPuzmFjJnryx9HVGcaStCe=',
      's2': 'Dkdpgh4ZKsQB80/Mfvw36XI1R25-WUAlEi7NLboqYTOPuzmFjJnryx9HVGcaStCe=',
      's3': 'ckdp1h4ZKsUB80/Mfvw36XIgR25+WQAlEi7NLboqYTOPuzmFjJnryx9HVGDaStCe',
      's4': 'Dkdpgh2ZmsQB80/MfvV36XI1R45-WUAlEixNLwoqYTOPuzKFjJnry79HbGcaStCe',
    };
    const masks = [16515072, 258048, 4032, 63];
    const shifts = [18, 12, 6, 0];
    final encodingTable = tables[num]!;
    final result = StringBuffer();
    var roundNum = 0;
    var longInt = _getLongInt(roundNum, longStr);
    final totalChars = (longStr.length / 3 * 4).ceil();
    for (var i = 0; i < totalChars; i++) {
      if (i ~/ 4 != roundNum) {
        roundNum += 1;
        longInt = _getLongInt(roundNum, longStr);
      }
      final index = i % 4;
      final charIndex = (longInt & masks[index]) >> shifts[index];
      result.write(encodingTable[charIndex]);
    }
    return result.toString();
  }

  int _getLongInt(int roundNum, String longStr) {
    final base = roundNum * 3;
    final c1 = base < longStr.length ? longStr.codeUnitAt(base) : 0;
    final c2 = base + 1 < longStr.length ? longStr.codeUnitAt(base + 1) : 0;
    final c3 = base + 2 < longStr.length ? longStr.codeUnitAt(base + 2) : 0;
    return (c1 << 16) | (c2 << 8) | c3;
  }

  List<int> _generRandom(int randomNum, List<int> option) {
    final byte1 = randomNum & 255;
    final byte2 = (randomNum >> 8) & 255;
    return [
      (byte1 & 170) | (option[0] & 85),
      (byte1 & 85) | (option[0] & 170),
      (byte2 & 170) | (option[1] & 85),
      (byte2 & 85) | (option[1] & 170),
    ];
  }

  String _generateRandomStr() {
    const randomValues = [0.123456789, 0.987654321, 0.555555555];
    final bytes = <int>[
      ..._generRandom((randomValues[0] * 10000).toInt(), [3, 45]),
      ..._generRandom((randomValues[1] * 10000).toInt(), [1, 0]),
      ..._generRandom((randomValues[2] * 10000).toInt(), [1, 5]),
    ];
    return String.fromCharCodes(bytes);
  }

  String _generateRc4BbStr(
    String urlSearchParams,
    String userAgent,
    String windowEnvStr, {
    String suffix = 'cus',
    List<int> arguments = const [0, 1, 14],
  }) {
    final urlSearchParamsList =
        _sm3Sum(_sm3Sum(urlSearchParams + suffix));
    final cus = _sm3Sum(_sm3Sum(suffix));
    final uaKey = String.fromCharCodes(const [0, 1, 14]);
    final ua = _sm3Sum(
      _resultEncrypt(_rc4Encrypt(userAgent, uaKey), 's3'),
    );

    final startTime =
        fixedStartMs ?? DateTime.now().millisecondsSinceEpoch;
    final endTime = startTime + 100;

    final b = <int, dynamic>{
      8: 3,
      10: endTime,
      15: {
        'aid': 6383,
        'pageId': 110624,
      },
      16: startTime,
      18: 44,
    };

    List<int> splitToBytes(int num) => [
          (num >> 24) & 255,
          (num >> 16) & 255,
          (num >> 8) & 255,
          num & 255,
        ];

    final startTimeBytes = splitToBytes(b[16] as int);
    b[20] = startTimeBytes[0];
    b[21] = startTimeBytes[1];
    b[22] = startTimeBytes[2];
    b[23] = startTimeBytes[3];
    b[24] = ((b[16] as int) / 256 / 256 / 256 / 256).toInt() & 255;
    b[25] = ((b[16] as int) / 256 / 256 / 256 / 256 / 256).toInt() & 255;

    final arg0Bytes = splitToBytes(arguments[0]);
    b[26] = arg0Bytes[0];
    b[27] = arg0Bytes[1];
    b[28] = arg0Bytes[2];
    b[29] = arg0Bytes[3];

    b[30] = (arguments[1] ~/ 256) & 255;
    b[31] = (arguments[1] % 256) & 255;

    final arg1Bytes = splitToBytes(arguments[1]);
    b[32] = arg1Bytes[0];
    b[33] = arg1Bytes[1];

    final arg2Bytes = splitToBytes(arguments[2]);
    b[34] = arg2Bytes[0];
    b[35] = arg2Bytes[1];
    b[36] = arg2Bytes[2];
    b[37] = arg2Bytes[3];

    b[38] = urlSearchParamsList[21];
    b[39] = urlSearchParamsList[22];
    b[40] = cus[21];
    b[41] = cus[22];
    b[42] = ua[23];
    b[43] = ua[24];

    final endTimeBytes = splitToBytes(b[10] as int);
    b[44] = endTimeBytes[0];
    b[45] = endTimeBytes[1];
    b[46] = endTimeBytes[2];
    b[47] = endTimeBytes[3];
    b[48] = b[8];
    b[49] = ((b[10] as int) / 256 / 256 / 256 / 256).toInt() & 255;
    b[50] = ((b[10] as int) / 256 / 256 / 256 / 256 / 256).toInt() & 255;

    final pageId = (b[15] as Map)['pageId'] as int;
    final aid = (b[15] as Map)['aid'] as int;
    b[51] = pageId;
    final pageIdBytes = splitToBytes(pageId);
    b[52] = pageIdBytes[0];
    b[53] = pageIdBytes[1];
    b[54] = pageIdBytes[2];
    b[55] = pageIdBytes[3];

    b[56] = aid;
    b[57] = aid & 255;
    b[58] = (aid >> 8) & 255;
    b[59] = (aid >> 16) & 255;
    b[60] = (aid >> 24) & 255;

    final windowEnvList = windowEnvStr.codeUnits;
    b[64] = windowEnvList.length;
    b[65] = (b[64] as int) & 255;
    b[66] = ((b[64] as int) >> 8) & 255;
    b[69] = 0;
    b[70] = 0;
    b[71] = 0;

    b[72] = (b[18] as int) ^
        (b[20] as int) ^
        (b[26] as int) ^
        (b[30] as int) ^
        (b[38] as int) ^
        (b[40] as int) ^
        (b[42] as int) ^
        (b[21] as int) ^
        (b[27] as int) ^
        (b[31] as int) ^
        (b[35] as int) ^
        (b[39] as int) ^
        (b[41] as int) ^
        (b[43] as int) ^
        (b[22] as int) ^
        (b[28] as int) ^
        (b[32] as int) ^
        (b[36] as int) ^
        (b[23] as int) ^
        (b[29] as int) ^
        (b[33] as int) ^
        (b[37] as int) ^
        (b[44] as int) ^
        (b[45] as int) ^
        (b[46] as int) ^
        (b[47] as int) ^
        (b[48] as int) ^
        (b[49] as int) ^
        (b[50] as int) ^
        (b[24] as int) ^
        (b[25] as int) ^
        (b[52] as int) ^
        (b[53] as int) ^
        (b[54] as int) ^
        (b[55] as int) ^
        (b[57] as int) ^
        (b[58] as int) ^
        (b[59] as int) ^
        (b[60] as int) ^
        (b[65] as int) ^
        (b[66] as int) ^
        (b[70] as int) ^
        (b[71] as int);

    final bb = <int>[
      b[18] as int,
      b[20] as int,
      b[52] as int,
      b[26] as int,
      b[30] as int,
      b[34] as int,
      b[58] as int,
      b[38] as int,
      b[40] as int,
      b[53] as int,
      b[42] as int,
      b[21] as int,
      b[27] as int,
      b[54] as int,
      b[55] as int,
      b[31] as int,
      b[35] as int,
      b[57] as int,
      b[39] as int,
      b[41] as int,
      b[43] as int,
      b[22] as int,
      b[28] as int,
      b[32] as int,
      b[60] as int,
      b[36] as int,
      b[23] as int,
      b[29] as int,
      b[33] as int,
      b[37] as int,
      b[44] as int,
      b[45] as int,
      b[59] as int,
      b[46] as int,
      b[47] as int,
      b[48] as int,
      b[49] as int,
      b[50] as int,
      b[24] as int,
      b[25] as int,
      b[65] as int,
      b[66] as int,
      b[70] as int,
      b[71] as int,
      ...windowEnvList,
      b[72] as int,
    ];

    return _rc4Encrypt(String.fromCharCodes(bb), String.fromCharCode(121));
  }
}

class _SM3 {
  _SM3(this._parent);

  final DouyinABogus _parent;
  late List<int> reg;
  List<int> chunk = [];
  int size = 0;

  void reset() {
    reg = [
      1937774191,
      1226093241,
      388252375,
      3666478592,
      2842636476,
      372324522,
      3817729613,
      2969243214,
    ];
    chunk = [];
    size = 0;
  }

  void write(dynamic data) {
    final List<int> a;
    if (data is String) {
      a = List<int>.from(utf8.encode(data));
    } else if (data is List<int>) {
      a = List<int>.from(data);
    } else {
      throw ArgumentError('unsupported sm3 input');
    }
    size += a.length;
    var f = 64 - chunk.length;
    if (a.length < f) {
      chunk.addAll(a);
    } else {
      chunk.addAll(a.sublist(0, f));
      while (chunk.length >= 64) {
        _compress(List<int>.from(chunk));
        if (f < a.length) {
          chunk = List<int>.from(a.sublist(f, min(f + 64, a.length)));
        } else {
          chunk = <int>[];
        }
        f += 64;
      }
    }
  }

  void _fill() {
    final bitLength = 8 * size;
    var paddingPos = chunk.length;
    chunk.add(0x80);
    paddingPos = (paddingPos + 1) % 64;
    if (64 - paddingPos < 8) {
      paddingPos -= 64;
    }
    while (paddingPos < 56) {
      chunk.add(0);
      paddingPos += 1;
    }
    final highBits = bitLength ~/ 4294967296;
    for (var i = 0; i < 4; i++) {
      chunk.add((highBits >> (8 * (3 - i))) & 0xFF);
    }
    for (var i = 0; i < 4; i++) {
      chunk.add((bitLength >> (8 * (3 - i))) & 0xFF);
    }
  }

  void _compress(List<int> data) {
    if (data.length < 64) {
      throw StateError('compress error: not enough data');
    }
    final w = List<int>.filled(132, 0);
    for (var t = 0; t < 16; t++) {
      w[t] = ((data[4 * t] << 24) |
              (data[4 * t + 1] << 16) |
              (data[4 * t + 2] << 8) |
              data[4 * t + 3]) &
          0xFFFFFFFF;
    }
    for (var j = 16; j < 68; j++) {
      var a = w[j - 16] ^ w[j - 9] ^ _parent._leftRotate(w[j - 3], 15);
      a = a ^ _parent._leftRotate(a, 15) ^ _parent._leftRotate(a, 23);
      w[j] = (a ^
              _parent._leftRotate(w[j - 13], 7) ^
              w[j - 6]) &
          0xFFFFFFFF;
    }
    for (var j = 0; j < 64; j++) {
      w[j + 68] = (w[j] ^ w[j + 4]) & 0xFFFFFFFF;
    }

    var a = reg[0];
    var b = reg[1];
    var c = reg[2];
    var d = reg[3];
    var e = reg[4];
    var f = reg[5];
    var g = reg[6];
    var h = reg[7];

    for (var j = 0; j < 64; j++) {
      final ss1 = _parent._leftRotate(
        (_parent._leftRotate(a, 12) +
                e +
                _parent._leftRotate(_parent._getTj(j), j)) &
            0xFFFFFFFF,
        7,
      );
      final ss2 = ss1 ^ _parent._leftRotate(a, 12);
      final tt1 =
          (_parent._ffj(j, a, b, c) + d + ss2 + w[j + 68]) & 0xFFFFFFFF;
      final tt2 = (_parent._ggj(j, e, f, g) + h + ss1 + w[j]) & 0xFFFFFFFF;
      d = c;
      c = _parent._leftRotate(b, 9);
      b = a;
      a = tt1;
      h = g;
      g = _parent._leftRotate(f, 19);
      f = e;
      e = (tt2 ^
              _parent._leftRotate(tt2, 9) ^
              _parent._leftRotate(tt2, 17)) &
          0xFFFFFFFF;
    }

    reg[0] ^= a;
    reg[1] ^= b;
    reg[2] ^= c;
    reg[3] ^= d;
    reg[4] ^= e;
    reg[5] ^= f;
    reg[6] ^= g;
    reg[7] ^= h;
  }

  List<int> sum(dynamic data) {
    reset();
    write(data);
    _fill();
    for (var f = 0; f < chunk.length; f += 64) {
      _compress(chunk.sublist(f, f + 64));
    }
    final result = <int>[];
    for (var i = 0; i < 8; i++) {
      final c = reg[i];
      result.add((c >> 24) & 0xFF);
      result.add((c >> 16) & 0xFF);
      result.add((c >> 8) & 0xFF);
      result.add(c & 0xFF);
    }
    reset();
    return result;
  }
}
