import 'package:flutter/material.dart';
import '../services/web/aprs_shortcuts.dart';

class AprsShortcutsDialog extends StatefulWidget {
  const AprsShortcutsDialog({super.key});
  @override
  State<AprsShortcutsDialog> createState() => _AprsShortcutsDialogState();
}

class _AprsShortcutsDialogState extends State<AprsShortcutsDialog> {
  late final TextEditingController _favorites, _templates;
  String? _error;
  @override
  void initState() {
    super.initState();
    final value = AprsShortcuts.current;
    _favorites = TextEditingController(text: value.favorites.join('\n'));
    _templates = TextEditingController(
      text: value.templates.map((e) => '${e.name}: ${e.text}').join('\n'),
    );
  }

  @override
  void dispose() {
    _favorites.dispose();
    _templates.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    String text(String zhText, String en) => zh ? zhText : en;
    return AlertDialog(
      title: Text(
        text('常用呼号与消息模板', 'Favorite callsigns and message templates'),
      ),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                text(
                  '保存于电脑并提供给已登录的手机。选取只填写草稿，发送前还需预览确认。',
                  'Saved on this host for signed-in phones. Selection only fills a draft; preview and confirmation are required to send.',
                ),
              ),
              TextField(
                controller: _favorites,
                minLines: 3,
                maxLines: 5,
                maxLength: 220,
                decoration: InputDecoration(
                  labelText: text(
                    '常用呼号（每行一个，最多 20 个）',
                    'Favorites (one per line, maximum 20)',
                  ),
                ),
              ),
              TextField(
                controller: _templates,
                minLines: 4,
                maxLines: 7,
                maxLength: 1600,
                decoration: InputDecoration(
                  labelText: text(
                    '模板（每行：名称: 消息，最多 16 条）',
                    'Templates (Name: message, maximum 16)',
                  ),
                  hintText: 'CQ: CQ via remote APRS',
                ),
              ),
              Text(
                text(
                  '名称最多 24 字；消息限 67 个可打印 ASCII 字符，不能含 { | ~。模板本身会在已登录手机上显示，请只保存要共享的文字。',
                  'Names: up to 24 characters. Messages: 67 printable ASCII characters without { | ~. Templates are visible to signed-in phones; save only text you intend to share.',
                ),
              ),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(text('取消', 'Cancel')),
        ),
        FilledButton(
          onPressed: () {
            try {
              AprsShortcuts.parse(_favorites.text, _templates.text).save();
              Navigator.of(context).pop();
            } on FormatException catch (e) {
              setState(
                () => _error = zh ? '请检查呼号、模板格式、数量和 ASCII 字符限制。' : e.message,
              );
            }
          },
          child: Text(text('保存', 'Save')),
        ),
      ],
    );
  }
}
