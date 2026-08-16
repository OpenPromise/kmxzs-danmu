import 'package:flutter/material.dart';
import 'package:kmxzs/config/app_config.dart';
import 'package:kmxzs/models/api_models.dart';
import 'package:kmxzs/pages/home_page.dart';
import 'package:kmxzs/services/api.dart';
import 'package:kmxzs/services/auth.dart';
import 'package:kmxzs/widgets/about.dart';
import 'package:kmxzs/widgets/title_bar.dart';
import 'package:kmxzs/widgets/update_prompt.dart';

/// 商业化登录页：不暴露服务端地址。
class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.api, required this.auth});

  final Api api;
  final Auth auth;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _cardCtrl = TextEditingController();
  bool _remember = true;
  bool _busy = false;
  String? _notice;
  String? _error;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _cardCtrl.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final saved = await widget.auth.getSavedCard();
    if (saved != null) {
      _cardCtrl.text = saved;
      _remember = true;
    }

    try {
      await widget.api.pingHealth();
    } catch (_) {
      // 连通失败不挡登录页，登录时再提示
    }

    try {
      final cfg = await widget.api.loadConfig();
      _notice = cfg.notice;
      if (mounted) {
        await UpdatePrompt.showIfNeeded(context, widget.api, cfg);
      }
    } catch (_) {}
    if (mounted) setState(() {});
  }

  Future<void> _login() async {
    final card = _cardCtrl.text.trim();
    if (card.isEmpty) {
      setState(() => _error = '请输入卡密');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.auth.login(card, remember: _remember);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => HomePage(api: widget.api, auth: widget.auth),
        ),
      );
    } catch (e) {
      setState(() => _error = _friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _friendlyError(Object e) {
    if (e is ApiError) {
      if (e.code == -1 || e.message.contains('连接') || e.message.contains('超时')) {
        return '无法连接服务器，请检查网络后重试';
      }
      return e.message;
    }
    final s = '$e';
    if (s.contains('Socket') || s.contains('连接') || s.contains('timeout')) {
      return '无法连接服务器，请检查网络后重试';
    }
    return s;
  }

  Future<void> _showDeviceManager() async {
    final card = _cardCtrl.text.trim();
    if (card.isEmpty) {
      setState(() => _error = '请先输入卡密');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // 设备管理需要有效会话：先静默登录再拉列表
      await widget.auth.login(card, remember: _remember);
      final devices = await widget.api.loadDevices();
      if (!mounted) return;
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('已绑定设备'),
          content: SizedBox(
            width: 420,
            height: 280,
            child: devices.isEmpty
                ? const Text('暂无已绑定设备')
                : ListView.builder(
                    itemCount: devices.length,
                    itemBuilder: (_, i) {
                      final d = devices[i];
                      return ListTile(
                        title: Text(d.name ?? d.deviceId),
                        subtitle: Text(d.deviceId),
                        trailing: TextButton(
                          onPressed: () async {
                            final ok = await showDialog<bool>(
                              context: ctx,
                              builder: (_) => AlertDialog(
                                title: const Text('确认解绑'),
                                content: const Text(
                                  '解绑将扣除 12 小时使用时长，是否继续？',
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(ctx, false),
                                    child: const Text('取消'),
                                  ),
                                  TextButton(
                                    onPressed: () => Navigator.pop(ctx, true),
                                    child: const Text('解绑'),
                                  ),
                                ],
                              ),
                            );
                            if (ok == true) {
                              await widget.api.unbindDevice(d.deviceId);
                              if (ctx.mounted) Navigator.pop(ctx);
                            }
                          },
                          child: const Text('解绑'),
                        ),
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    } catch (e) {
      setState(() => _error = _friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: Column(
        children: [
          const AppTitleBar(),
          if (_notice != null && _notice!.isNotEmpty)
            MaterialBanner(
              content: Text(
                _notice!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              actions: [
                TextButton(
                  onPressed: () => setState(() => _notice = null),
                  child: const Text('知道了'),
                ),
              ],
            ),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 380),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        AppConfig.productName,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w700,
                          color: cs.primary,
                          letterSpacing: 1.2,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '开发商：${AppConfig.publisher}',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '输入卡密开始使用',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 14,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 28),
                      TextField(
                        controller: _cardCtrl,
                        decoration: const InputDecoration(
                          labelText: '卡密',
                          hintText: '请输入您的卡密',
                          border: OutlineInputBorder(),
                        ),
                        onSubmitted: (_) => _login(),
                      ),
                      const SizedBox(height: 8),
                      CheckboxListTile(
                        value: _remember,
                        onChanged: (v) =>
                            setState(() => _remember = v ?? true),
                        title: const Text('记住卡密'),
                        controlAffinity: ListTileControlAffinity.leading,
                        contentPadding: EdgeInsets.zero,
                      ),
                      if (_error != null) ...[
                        Text(
                          _error!,
                          style: const TextStyle(color: Colors.redAccent),
                        ),
                        const SizedBox(height: 8),
                      ],
                      FilledButton(
                        onPressed: _busy ? null : _login,
                        child: Text(_busy ? '正在登录…' : '登录'),
                      ),
                      TextButton(
                        onPressed: _busy ? null : _showDeviceManager,
                        child: const Text('管理已绑设备'),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        AppConfig.supportHint,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        AppAbout.versionLine,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 11,
                          color: Color(0xFF94A3B8),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
