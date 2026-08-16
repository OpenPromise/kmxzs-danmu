import 'package:flutter/material.dart';
import 'package:kmxzs/config/app_config.dart';
import 'package:kmxzs/widgets/about.dart';
import 'package:window_manager/window_manager.dart';

class AppTitleBar extends StatelessWidget {
  const AppTitleBar({super.key, this.title = AppConfig.productName});

  final String title;

  @override
  Widget build(BuildContext context) {
    return DragToMoveArea(
      child: SizedBox(
        height: 40,
        child: Row(
          children: [
            const SizedBox(width: 12),
            Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(width: 8),
            const Text(
              '·',
              style: TextStyle(color: Color(0xFF94A3B8), fontSize: 14),
            ),
            const SizedBox(width: 8),
            const Text(
              AppConfig.publisher,
              style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
            ),
            const Spacer(),
            _TitleBarButton(
              icon: Icons.info_outline,
              onTap: () => AppAbout.show(context),
            ),
            _TitleBarButton(
              icon: Icons.remove,
              onTap: () => windowManager.minimize(),
            ),
            _TitleBarButton(
              icon: Icons.close,
              onTap: () => windowManager.close(),
              hoverColor: Colors.redAccent,
            ),
          ],
        ),
      ),
    );
  }
}

class _TitleBarButton extends StatelessWidget {
  const _TitleBarButton({
    required this.icon,
    required this.onTap,
    this.hoverColor,
  });

  final IconData icon;
  final VoidCallback onTap;
  final Color? hoverColor;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      hoverColor: hoverColor?.withValues(alpha: 0.2),
      child: SizedBox(width: 46, height: 40, child: Icon(icon, size: 18)),
    );
  }
}
