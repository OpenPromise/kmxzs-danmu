import 'package:flutter/material.dart';

/// [E] package:kmxzs/pages/message_dialog.dart
/// [E] MessageDialog
/// [E] UI: 选择一条留言查看对话 / 回复内容... / 该留言已结束
class MessageDialog extends StatelessWidget {
  const MessageDialog({super.key, this.messages = const []});

  final List<String> messages;

  static Future<void> show(BuildContext context, {List<String> messages = const []}) {
    return showDialog(
      context: context,
      builder: (_) => MessageDialog(messages: messages),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('留言'),
      content: SizedBox(
        width: 420,
        height: 280,
        child: messages.isEmpty
            ? const Text('选择一条留言查看对话')
            : ListView.builder(
                itemCount: messages.length,
                itemBuilder: (_, i) => ListTile(title: Text(messages[i])),
              ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('关闭')),
      ],
    );
  }
}
