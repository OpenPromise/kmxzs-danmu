/// [E] ApiResult / ApiError / Authentication.fromJson
class ApiResult<T> {
  final int code;
  final String message;
  final T? data;

  const ApiResult({required this.code, required this.message, this.data});

  bool get ok => code == 0 || code == 200;

  factory ApiResult.fromJson(
    Map<String, dynamic> json,
    T Function(dynamic)? parse,
  ) {
    return ApiResult(
      code: json['code'] is int
          ? json['code'] as int
          : int.tryParse('${json['code']}') ?? -1,
      message: '${json['message'] ?? json['msg'] ?? ''}',
      data: parse == null ? null : parse(json['data']),
    );
  }
}

class ApiError implements Exception {
  final int code;
  final String message;
  ApiError(this.code, this.message);
  @override
  String toString() => 'ApiError($code): $message';
}

class Authentication {
  final String token;
  final DateTime? expires;
  final String? card;
  final int? remainingHours;
  final String? deviceId;
  final int? deviceCount;
  final int? maxDevices;
  final Map<String, dynamic> raw;

  Authentication({
    required this.token,
    this.expires,
    this.card,
    this.remainingHours,
    this.deviceId,
    this.deviceCount,
    this.maxDevices,
    this.raw = const {},
  });

  factory Authentication.fromJson(Map<String, dynamic> json) {
    DateTime? exp;
    final e = json['expires'] ?? json['expire'];
    if (e is int) {
      exp = DateTime.fromMillisecondsSinceEpoch(e > 1000000000000 ? e : e * 1000);
    } else if (e is String) {
      exp = DateTime.tryParse(e);
    }
    return Authentication(
      token: '${json['token'] ?? ''}',
      expires: exp,
      card: json['card']?.toString(),
      remainingHours: json['remainingHours'] is int
          ? json['remainingHours'] as int
          : int.tryParse('${json['remainingHours'] ?? ''}'),
      deviceId: json['deviceId']?.toString() ?? json['device_id']?.toString(),
      deviceCount: json['deviceCount'] is int
          ? json['deviceCount'] as int
          : int.tryParse('${json['deviceCount'] ?? ''}'),
      maxDevices: json['maxDevices'] is int
          ? json['maxDevices'] as int
          : int.tryParse('${json['maxDevices'] ?? ''}'),
      raw: json,
    );
  }

  Authentication mergeProfile(AccountProfile p) => Authentication(
        token: token,
        expires: p.expires ?? expires,
        card: p.card ?? card,
        remainingHours: p.remainingHours ?? remainingHours,
        deviceId: p.deviceId ?? deviceId,
        deviceCount: p.deviceCount ?? deviceCount,
        maxDevices: p.maxDevices ?? maxDevices,
        raw: {...raw, ...p.raw},
      );

  String get expiresLabel {
    if (expires == null) return '未知';
    final local = expires!.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  String get remainingLabel {
    final h = remainingHours;
    if (h == null) return '未知';
    if (h <= 0) return '已过期';
    if (h < 24) return '$h 小时';
    final d = h ~/ 24;
    final rem = h % 24;
    return rem == 0 ? '$d 天' : '$d 天 $rem 小时';
  }
}

class AccountProfile {
  final String? card;
  final DateTime? expires;
  final int? remainingHours;
  final String? deviceId;
  final int? deviceCount;
  final int? maxDevices;
  final Map<String, dynamic> raw;

  AccountProfile({
    this.card,
    this.expires,
    this.remainingHours,
    this.deviceId,
    this.deviceCount,
    this.maxDevices,
    this.raw = const {},
  });

  factory AccountProfile.fromJson(Map<String, dynamic> json) {
    DateTime? exp;
    final e = json['expires'] ?? json['expire'];
    if (e is int) {
      exp = DateTime.fromMillisecondsSinceEpoch(e > 1000000000000 ? e : e * 1000);
    } else if (e is String) {
      exp = DateTime.tryParse(e);
    }
    return AccountProfile(
      card: json['card']?.toString(),
      expires: exp,
      remainingHours: json['remainingHours'] is int
          ? json['remainingHours'] as int
          : int.tryParse('${json['remainingHours'] ?? ''}'),
      deviceId: json['deviceId']?.toString() ?? json['device_id']?.toString(),
      deviceCount: json['deviceCount'] is int
          ? json['deviceCount'] as int
          : int.tryParse('${json['deviceCount'] ?? ''}'),
      maxDevices: json['maxDevices'] is int
          ? json['maxDevices'] as int
          : int.tryParse('${json['maxDevices'] ?? ''}'),
      raw: json,
    );
  }
}

class DeviceInfo {
  final String deviceId;
  final String? name;

  DeviceInfo({required this.deviceId, this.name});

  factory DeviceInfo.fromJson(Map<String, dynamic> json) => DeviceInfo(
        deviceId:
            '${json['deviceId'] ?? json['device_id'] ?? json['id'] ?? ''}',
        name: json['name']?.toString(),
      );
}

class AppRemoteConfig {
  final String? notice;
  final String? version;
  final String? minVersion;
  final String? download;
  final bool forceUpdate;
  final String? serverVersion;
  final int? downloadSize;
  final Map<String, dynamic> raw;

  AppRemoteConfig({
    this.notice,
    this.version,
    this.minVersion,
    this.download,
    this.forceUpdate = false,
    this.serverVersion,
    this.downloadSize,
    this.raw = const {},
  });

  factory AppRemoteConfig.fromJson(Map<String, dynamic> json) =>
      AppRemoteConfig(
        notice: json['notice']?.toString(),
        version: json['version']?.toString(),
        minVersion: json['minVersion']?.toString() ??
            json['min_version']?.toString(),
        download: json['download']?.toString(),
        forceUpdate: json['force'] == true || json['force'] == 1,
        serverVersion: json['serverVersion']?.toString(),
        downloadSize: int.tryParse('${json['downloadSize'] ?? json['download_size'] ?? ''}'),
        raw: json,
      );
}
