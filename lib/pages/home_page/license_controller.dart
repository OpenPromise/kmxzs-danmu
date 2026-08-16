part of '../home_page.dart';

/// 在线授权轮询：initState 启动 3 分钟周期，过期/掉线强制回登录页。
mixin _LicenseController on _HomePageBase {
  bool get _showExpiryBanner {
    final h = widget.auth.current?.remainingHours;
    return h != null && h > 0 && h < 24;
  }

  String get _expiryHoursLabel {
    final h = widget.auth.current?.remainingHours;
    if (h == null) return '不足 24 小时';
    return '$h 小时';
  }

  /// 在线验权：过期/掉线强制回登录页。并发调用会共用同一次 /me。
  Future<bool> _ensureLicense({bool silent = false}) {
    final existing = _licenseInflight;
    if (existing != null) return existing;

    final future = () async {
      try {
        await widget.auth.refreshProfile();
        if (!widget.auth.isLicensed) {
          await _forceRelogin('账号已过期，请充值后续费');
          return false;
        }
        if (mounted) setState(() {});
        return true;
      } catch (e) {
        // 静默轮询失败只留 debug 日志，避免每 3 分钟在 UI 上刷屏；
        // 但掉线时仍然强制回登录页，保证用户能感知并重新登录。
        debugPrint('[license] 授权校验失败: $e');
        if (!silent) {
          _appendLog('授权校验失败: $e');
        }
        await _forceRelogin('授权校验失败，请重新登录');
        return false;
      } finally {
        _licenseInflight = null;
      }
    }();

    _licenseInflight = future;
    return future;
  }

  Future<void> _forceRelogin(String reason) async {
    _licenseTimer?.cancel();
    await widget.auth.logout();
    if (!mounted) return;
    _toast(reason);
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => LoginPage(api: widget.api, auth: widget.auth),
      ),
      (_) => false,
    );
  }
}
