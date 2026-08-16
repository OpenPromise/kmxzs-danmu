import 'package:flutter_test/flutter_test.dart';
import 'package:kmxzs/main.dart';

void main() {
  testWidgets('app builds home without login', (tester) async {
    await tester.pumpWidget(const KmxzsApp());
    expect(find.text('OBS 安装路径'), findsOneWidget);
  });
}
