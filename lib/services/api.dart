import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:kmxzs/config/app_config.dart';
import 'package:kmxzs/models/api_models.dart';
import 'package:kmxzs/services/api_sign.dart';
import 'package:kmxzs/services/device_fingerprint.dart';
import 'package:kmxzs/services/http_client_factory.dart';
import 'package:uuid/uuid.dart';

/// 卡密 API 客户端。服务地址由 [AppConfig] 注入，不在 UI 暴露。
class Api {
  Api({
    Dio? dio,
    String? baseUrl,
    bool localMock = false,
  })  : localMock = localMock && kDebugMode,
        _dio = dio ??
            Dio(
              BaseOptions(
                baseUrl: baseUrl ?? AppConfig.defaultApiBase,
                connectTimeout: const Duration(seconds: 15),
                receiveTimeout: const Duration(seconds: 20),
                headers: {
                  'User-Agent': 'zbxzs/1.0.4+5',
                  'Accept': 'application/json',
                },
              ),
            )..httpClientAdapter = HttpClientFactory.dioAdapter();

  /// @nodoc 兼容旧引用；实际默认见 AppConfig
  static const defaultBaseUrl = 'http://127.0.0.1:18088';

  /// 仅 Debug 可用；Release 强制关闭，防止补丁绕过。
  final bool localMock;
  final Dio _dio;
  static const apiRoot = '/api/user/1009/flutter/1.0.2';
  String? token;
  final Set<String> _localUnboundDevices = {};

  String get origin {
    return _dio.options.baseUrl.replaceAll(RegExp(r'/+$'), '');
  }

  /// 始终拉取当前最高版本安装包，避免 1.0.0 → 1.0.1 → 1.0.2 逐级升级。
  String latestInstallerUrl(String version) {
    final v = Uri.encodeQueryComponent(version);
    return '$origin/files/latest.exe?v=$v';
  }

  int _clockOffsetMs = 0;
  DateTime? _clockSyncedAt;

  String get baseUrl => _dio.options.baseUrl;

  void setBaseUrl(String url) {
    final trimmed = url.trim().replaceAll(RegExp(r'/+$'), '');
    if (trimmed.isEmpty) return;
    _dio.options.baseUrl = trimmed;
  }

  void setToken(String? t) => token = t;

  Options _auth([Options? o]) {
    final opt = o ?? Options();
    final headers = Map<String, dynamic>.from(opt.headers ?? {});
    if (token != null && token!.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
      headers['token'] = token;
    }
    return opt.copyWith(headers: headers);
  }

  Never _throwFromDio(DioException e) {
    final data = e.response?.data;
    if (data is Map) {
      final map = Map<String, dynamic>.from(data);
      final detail = map['detail'];
      if (detail is Map) {
        final d = Map<String, dynamic>.from(detail);
        final msg = '${d['message'] ?? d['msg'] ?? e.message}';
        final code = d['code'] is int
            ? d['code'] as int
            : int.tryParse('${d['code']}') ?? (e.response?.statusCode ?? -1);
        throw ApiError(code, msg.isEmpty ? '请求失败' : msg);
      }
      final msg = '${map['message'] ?? map['msg'] ?? e.message}';
      final code = map['code'] is int
          ? map['code'] as int
          : int.tryParse('${map['code']}') ?? (e.response?.statusCode ?? -1);
      throw ApiError(code, msg.isEmpty ? '请求失败' : msg);
    }
    throw ApiError(
      e.response?.statusCode ?? -1,
      e.message ?? '无法连接服务器，请检查网络后重试',
    );
  }

  int get _signedNowMs =>
      DateTime.now().millisecondsSinceEpoch + _clockOffsetMs;

  /// 用 /health 的 serverTimeMs 校准本机时钟偏移，签名不再依赖绝对准确的系统时间。
  Future<void> syncServerClock({bool force = false}) async {
    if (localMock) return;
    if (!force &&
        _clockSyncedAt != null &&
        DateTime.now().difference(_clockSyncedAt!) <
            const Duration(minutes: 10)) {
      return;
    }
    try {
      final t0 = DateTime.now().millisecondsSinceEpoch;
      final health = await pingHealth();
      final t1 = DateTime.now().millisecondsSinceEpoch;
      final raw = health['serverTimeMs'];
      final serverMs = raw is int
          ? raw
          : raw is num
              ? raw.toInt()
              : int.tryParse('$raw');
      if (serverMs == null) return;
      final localMid = (t0 + t1) ~/ 2;
      _clockOffsetMs = serverMs - localMid;
      _clockSyncedAt = DateTime.now();
    } catch (e) {
      // 校准失败时仍用本机时间；服务端 5 分钟窗口兜底，仅留 debug 日志
      debugPrint('[api] 时钟校准失败: $e');
    }
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body, {
    bool retriedAfterClockSync = false,
  }) async {
    final secret = AppConfig.apiSecret.trim();
    if (secret.isNotEmpty) {
      await syncServerClock();
    }

    final deviceId = await _deviceId();
    final timestamp = _signedNowMs;
    final nonce = const Uuid().v4();
    final fullPath = '$apiRoot$path';
    final payload = <String, dynamic>{
      ...body,
      'deviceId': deviceId,
      // 携带旧指纹供服务端做一次静默迁移（同机老账号不触发设备数上限）
      'legacyDeviceId': await DeviceFingerprint.legacyId(),
      'timestamp': timestamp,
      'nonce': nonce,
    };

    if (secret.isNotEmpty) {
      payload['sign'] = ApiSign.sign(
        secret: secret,
        path: fullPath,
        timestamp: timestamp,
        nonce: nonce,
        deviceId: deviceId,
        body: body,
      );
    }

    try {
      final resp = await _dio.post(
        fullPath,
        data: payload,
        options: _auth(),
      );
      final data = resp.data;
      if (data is Map<String, dynamic>) return data;
      if (data is Map) return Map<String, dynamic>.from(data);
      throw ApiError(-1, '网络请求失败');
    } on DioException catch (e) {
      try {
        _throwFromDio(e);
      } on ApiError catch (err) {
        final skew = err.message.contains('校准系统时间') ||
            err.message.contains('请求已过期');
        if (secret.isNotEmpty && skew && !retriedAfterClockSync) {
          await syncServerClock(force: true);
          return _post(path, body, retriedAfterClockSync: true);
        }
        rethrow;
      }
    }
  }

  Future<String> deviceId() => _deviceId();

  Future<String> _deviceId() async {
    return DeviceFingerprint.currentId();
  }

  Future<Authentication> login(String card) async {
    if (localMock) {
      if (card.isEmpty) {
        throw ApiError(401, '卡密无效');
      }
      final expires = DateTime.now().add(const Duration(days: 3650));
      return Authentication(
        token: 'local-${const Uuid().v4()}',
        expires: expires,
        card: card,
        remainingHours: 3650 * 24,
        deviceId: await _deviceId(),
        deviceCount: 1,
        maxDevices: 1,
        raw: {
          'mode': 'local',
          'card': card,
          'expires': expires.toIso8601String(),
        },
      );
    }
    final json = await _post('/login', {'card': card, 'kami': card});
    final result = ApiResult.fromJson(json, (d) => d);
    if (!result.ok) {
      throw ApiError(
        result.code,
        result.message.isEmpty ? '登录失败' : result.message,
      );
    }
    final data = result.data;
    if (data is Map) {
      return Authentication.fromJson(Map<String, dynamic>.from(data));
    }
    return Authentication.fromJson(json);
  }

  Future<AccountProfile> loadMe() async {
    if (localMock) {
      return AccountProfile(
        card: 'LOCAL',
        expires: DateTime.now().add(const Duration(days: 3650)),
        remainingHours: 3650 * 24,
        deviceId: await _deviceId(),
        deviceCount: 1,
        maxDevices: 1,
      );
    }
    final json = await _post('/me', {});
    final result = ApiResult.fromJson(json, (d) => d);
    if (!result.ok) {
      throw ApiError(result.code, result.message.isEmpty ? '获取账号失败' : result.message);
    }
    final data = result.data;
    if (data is Map) {
      return AccountProfile.fromJson(Map<String, dynamic>.from(data));
    }
    return AccountProfile.fromJson(json);
  }

  Future<AppRemoteConfig> loadConfig() async {
    if (localMock) {
      return AppRemoteConfig(
        notice: '',
        version: '1.0.0',
        raw: const {'mode': 'local'},
      );
    }
    final json = await _post('/config', {});
    final result = ApiResult.fromJson(json, (d) => d);
    final data = result.data;
    if (data is Map) {
      return AppRemoteConfig.fromJson(Map<String, dynamic>.from(data));
    }
    return AppRemoteConfig.fromJson(json);
  }

  /// 探测授权服务是否可达。
  Future<Map<String, dynamic>> pingHealth() async {
    if (localMock) {
      return {'ok': true, 'service': 'local-mock', 'version': 'local'};
    }
    try {
      final res = await _dio.get('/health');
      final data = res.data;
      if (data is Map) return Map<String, dynamic>.from(data);
      return {'ok': true};
    } on DioException catch (e) {
      throw ApiError(
        e.response?.statusCode ?? -1,
        e.message ?? '无法连接服务器，请检查网络后重试',
      );
    }
  }

  Future<String> loadNotice() async {
    final cfg = await loadConfig();
    return cfg.notice ?? '';
  }

  Future<List<DeviceInfo>> loadDevices() async {
    if (localMock) {
      final id = await _deviceId();
      if (_localUnboundDevices.contains(id)) return const [];
      return [DeviceInfo(deviceId: id, name: Platform.localHostname)];
    }
    final json = await _post('/device/list', {});
    final result = ApiResult.fromJson(json, (d) => d);
    final data = result.data;
    if (data is List) {
      return data
          .whereType<Map>()
          .map((e) => DeviceInfo.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    }
    return const [];
  }

  Future<AccountProfile?> unbindDevice(String deviceId) async {
    if (localMock) {
      _localUnboundDevices.add(deviceId);
      return null;
    }
    final json = await _post('/device/unbind', {'deviceId': deviceId});
    final result = ApiResult.fromJson(json, (d) => d);
    if (!result.ok) {
      throw ApiError(
        result.code,
        result.message.isEmpty ? '解绑失败' : result.message,
      );
    }
    final data = result.data;
    if (data is Map) {
      return AccountProfile.fromJson(Map<String, dynamic>.from(data));
    }
    return null;
  }

  Future<AccountProfile?> kamiTopup(String kami) async {
    if (localMock) {
      if (kami.trim().isEmpty) throw ApiError(400, '充值卡密不能为空');
      return null;
    }
    final json = await _post('/topup', {'kami': kami, 'card': kami});
    final result = ApiResult.fromJson(json, (d) => d);
    if (!result.ok) {
      throw ApiError(
        result.code,
        result.message.isEmpty ? '充值失败' : result.message,
      );
    }
    final data = result.data;
    if (data is Map) {
      return AccountProfile.fromJson(Map<String, dynamic>.from(data));
    }
    return null;
  }

  Future<void> reportKwailiveAccount(Map<String, dynamic> account) async {
    if (localMock) return;
    await _post('/kwailive/account', account);
  }
}
