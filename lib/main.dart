import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:kmxzs/config/app_config.dart';
import 'package:kmxzs/pages/home_page.dart';
import 'package:kmxzs/widgets/about.dart';
import 'package:kmxzs/pages/login_page.dart';
import 'package:kmxzs/services/api.dart';
import 'package:kmxzs/services/auth.dart';
import 'package:kmxzs/services/guard.dart';
import 'package:kmxzs/services/native_crypto.dart';
import 'package:window_manager/window_manager.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // desktop_webview_window：独立窗口标题栏进程入口
  if (runWebViewTitleBarWidget(args)) {
    return;
  }

  await windowManager.ensureInitialized();
  const opts = WindowOptions(
    size: Size(560, 680),
    minimumSize: Size(480, 560),
    center: true,
    title: AppAbout.windowTitle,
    titleBarStyle: TitleBarStyle.hidden,
  );
  await windowManager.waitUntilReadyToShow(opts, () async {
    await windowManager.setAsFrameless();
    await windowManager.show();
    await windowManager.focus();
  });

  NativeCrypto.instance.init('hook.dll');
  Guard.instance.initStreamCodeShm();
  Guard.instance.initKmxzsConfigShm();

  await AppConfig.load();
  runApp(const KmxzsApp());
}

class KmxzsApp extends StatelessWidget {
  const KmxzsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppAbout.windowTitle,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2F6FED)),
        useMaterial3: true,
      ),
      home: const _Bootstrap(),
    );
  }
}

class _Bootstrap extends StatefulWidget {
  const _Bootstrap();

  @override
  State<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<_Bootstrap> {
  Widget? _home;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    if (kReleaseMode && !AppConfig.hasApiSecret) {
      if (!mounted) return;
      setState(() {
        _home = const Scaffold(
          body: Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                '发行包未配置授权密钥（KMXZS_API_SECRET）。\n'
                '请使用官方打包命令重新编译，勿直接分发未注入密钥的构建。',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        );
      });
      return;
    }

    final api = Api(baseUrl: AppConfig.apiBaseUrl);
    final auth = Auth(api);

    final saved = await auth.getSavedCard();
    if (saved != null && saved.isNotEmpty) {
      try {
        // login 内会强制在线校验档案；失败或未授权都回登录页
        await auth.login(saved, remember: true);
        if (!auth.isLicensed) {
          await auth.logout();
          throw StateError('unlicensed');
        }
        if (!mounted) return;
        setState(() {
          _home = HomePage(api: api, auth: auth);
        });
        return;
      } catch (_) {
        // 自动登录失败 → 登录页
      }
    }
    if (!mounted) return;
    setState(() {
      _home = LoginPage(api: api, auth: auth);
    });
  }

  @override
  Widget build(BuildContext context) {
    return _home ??
        const Scaffold(
          body: Center(child: CircularProgressIndicator()),
        );
  }
}
