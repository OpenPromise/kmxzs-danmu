part of '../home_page.dart';

/// 快手网页登录态：拉流失败时引导登录，成功后自动保存 Cookie。
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
    _appendLog('快手账号登录成功');
    if (mounted) {
      _toast('快手登录成功');
      setState(() {});
    }
  }

  Future<void> _maybePromptKuaishouLogin(String failMsg) async {
    final rateLimit = failMsg.contains('已触发快手风控') ||
        failMsg.contains('livedetail.result=2') ||
        failMsg.contains('操作太快') ||
        failMsg.contains('操作频繁');
    // 已登录直播站（有 web_st）时，风控不是登录态失效：不弹重新登录，
    // 明确提示关 TUN/系统代理、等 5–10 分钟再试即可。
    if (rateLimit && _ksLoggedIn) {
      _appendLog('快手已登录，但操作过于频繁。请关闭代理，等几分钟再试，无需重新登录。');
      _toast('操作过于频繁，请关闭代理后等几分钟再试');
      return;
    }
    final need = failMsg.contains('Cookie') ||
        failMsg.contains('请先登录') ||
        failMsg.contains('登录快手') ||
        failMsg.contains('未登录') ||
        rateLimit;
    if (!need || !mounted) return;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('需要登录快手账号'),
        content: const Text(
          '拉快手直播需要先登录快手账号。'
          '点「去登录」将打开官方页面，登录完成后软件会自动记住。',
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
