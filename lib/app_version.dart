/// 与 pubspec.yaml version 的 name 段保持一致。
class AppVersion {
  static const String name = '1.0.14';
  static const String build = '15';
  static const String display = '$name+$build';

  /// 将 1.2.3 转为可比较整数。
  static int toNumber(String v) {
    final parts =
        v.split(RegExp(r'[^0-9]+')).where((e) => e.isNotEmpty).toList();
    var n = 0;
    for (final p in parts.take(3)) {
      n = n * 1000 + (int.tryParse(p) ?? 0);
    }
    return n;
  }

  static bool isOlderThan(String remote) =>
      toNumber(name) < toNumber(remote);
}
