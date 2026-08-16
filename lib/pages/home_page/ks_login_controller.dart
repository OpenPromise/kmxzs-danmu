part of '../home_page.dart';

/// 快手网页登录态：Cookie 自动保存/清除，拉流失败时引导重新登录。
mixin _KuaishouController on _HomePageBase {
  bool get _ksLoggedIn =>
      FlvExtractor.hasKuaishouLoginCookie(_ksCookieCtrl.text);

  Future<void> _loginKuaishouAccount({bool fromPullFail = false}) async {
    final cookie = await KsWebLoginPage.open(context);
    if (cookie == null || cookie.trim().isEmpty) {
      if (fromPullFail) _appendLog('已取消快手登录');
      return;
    }
    final cleaned = FlvExtractor.sanitizeCookieHeader(cookie);
    _ksCookieCtrl.text = cleaned;
    await _persist();
    _appendLog('快手账号登录成功，Cookie 已自动保存（${cleaned.length} 字符）');
    if (mounted) {
      _toast('快手登录成功');
      setState(() {});
    }
  }

  Future<void> _clearKuaishouCookie() async {
    _ksCookieCtrl.clear();
    await _persist();
    if (mounted) {
      setState(() {});
      _toast('已退出快手网页登录态');
    }
  }

  Future<void> _maybePromptKuaishouLogin(String failMsg) async {
    final need = failMsg.contains('Cookie') ||
        failMsg.contains('风控') ||
        failMsg.contains('result=2') ||
        failMsg.contains('操作太快');
    if (!need || !mounted) return;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_ksLoggedIn ? '快手需要重新登录' : '需要登录快手账号'),
        content: const Text(
          '快手网页拉流需要登录态。点击「去登录」将打开官方页面，'
          '你完成登录后软件会自动保存 Cookie，无需手动复制。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('稍后'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('去登录'),
          ),
        ],
      ),
    );
    if (go == true && mounted) {
      await _loginKuaishouAccount(fromPullFail: true);
    }
  }
}
