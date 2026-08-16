import 'package:flutter/material.dart';
import 'package:kmxzs/app_version.dart';
import 'package:kmxzs/config/app_config.dart';

class AppAbout {
  AppAbout._();

  static const windowTitle =
      '${AppConfig.productName} · ${AppConfig.publisher}';

  static const publisherLine = '开发商：${AppConfig.publisher}';

  static const copyright = '© 2026 ${AppConfig.publisher}';

  static const versionLine =
      '${AppConfig.publisher}  ·  v${AppVersion.name}';

  static Future<void> show(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text(AppConfig.productName),
          content: const Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(publisherLine),
              SizedBox(height: 6),
              Text('版本：v${AppVersion.name}'),
              SizedBox(height: 12),
              Text(
                copyright,
                style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
  }
}
