import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kmxzs/pages/login_page.dart';
import 'package:kmxzs/services/api.dart';
import 'package:kmxzs/services/auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('login page renders without saved card', (tester) async {
    SharedPreferences.setMockInitialValues({});
    // localMock 走内存分支，不触发注册表/网络等真实 I/O，可在 widget 测试中稳定渲染
    final api = Api(localMock: true);
    final auth = Auth(api);
    await tester.pumpWidget(
      MaterialApp(home: LoginPage(api: api, auth: auth)),
    );
    await tester.pumpAndSettle();
    // 未登录且无已保存卡密时进入登录页（主页需要授权）
    expect(find.text('输入卡密开始使用'), findsOneWidget);
  });
}
