import 'package:kmxzs/models/api_models.dart';
import 'package:kmxzs/services/api.dart';
import 'package:kmxzs/services/prefs_keys.dart';
import 'package:kmxzs/services/secure_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

class Auth {
  Auth(this.api);
  final Api api;

  Authentication? current;

  bool get isLoggedIn =>
      current != null &&
      current!.token.isNotEmpty &&
      (current!.expires == null || current!.expires!.isAfter(DateTime.now()));

  /// 有有效会话且剩余时长 > 0（主功能门禁用）。
  bool get isLicensed {
    if (!isLoggedIn) return false;
    final h = current!.remainingHours;
    if (h == null) return false;
    return h > 0;
  }

  Future<String?> getSavedCard() async {
    final sp = await SharedPreferences.getInstance();
    if (sp.getBool(PrefsKeys.rememberCard) != true) return null;
    // DPAPI 加密存储；内部会迁移旧明文数据
    return SecureStore.read(PrefsKeys.savedCard);
  }

  Future<void> saveCard(String card, {required bool remember}) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(PrefsKeys.rememberCard, remember);
    if (remember) {
      await SecureStore.write(PrefsKeys.savedCard, card);
    } else {
      await SecureStore.remove(PrefsKeys.savedCard);
    }
  }

  Future<Authentication> login(String card, {bool remember = true}) async {
    final auth = await api.login(card);
    current = auth;
    api.setToken(auth.token);
    await saveCard(card, remember: remember);
    // 必须在线拉档案；失败则登录失败（避免只靠 login 回包绕过）
    await refreshProfile();
    if (!isLicensed) {
      await logout();
      throw ApiError(401, '账号已过期或未授权');
    }
    return current!;
  }

  Future<AccountProfile> refreshProfile() async {
    final profile = await api.loadMe();
    if (current != null) {
      current = current!.mergeProfile(profile);
    }
    return profile;
  }

  Future<void> applyProfile(AccountProfile? profile) async {
    if (profile == null || current == null) return;
    current = current!.mergeProfile(profile);
  }

  Future<void> logout() async {
    current = null;
    api.setToken(null);
  }
}
