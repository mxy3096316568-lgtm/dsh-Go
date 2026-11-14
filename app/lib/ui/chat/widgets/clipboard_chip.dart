// 输入框上方的一条小条: 刚复制的东西可以一键粘上, 或者存进知识库。
//
// 只出现在聊天的输入框上方, 而且只对"刚复制、值得用"的内容出现(见 ClipboardWatch);
// 两个动作都由人点, 不会自动发送。
import 'package:flutter/material.dart';

import '../../../state/clipboard_watch.dart';
import '../../common/brief_notice.dart';
import '../../kb/kb_index.dart';

class ClipboardChip extends StatelessWidget {
  const ClipboardChip({super.key, required this.onPaste});

  /// 把这段文字放进输入框(由聊天页提供, 它拿着真正的 controller)。
  final void Function(String text) onPaste;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String?>(
      valueListenable: ClipboardWatch.fresh,
      builder: (context, text, _) {
        if (text == null || text.isEmpty) return const SizedBox.shrink();
        final theme = Theme.of(context);
        final oneLine = text.replaceAll(RegExp(r'\s+'), ' ');
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
          child: DecoratedBox(
            decoration: ShapeDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 2, 4, 2),
              child: Row(
                children: [
                  Icon(Icons.content_paste, size: 15, color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      oneLine,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                  TextButton(
                    key: const ValueKey('clip-paste'),
                    onPressed: () {
                      onPaste(text);
                      ClipboardWatch.consume();
                    },
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, 34),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                    ),
                    child: const Text('粘贴'),
                  ),
                  TextButton(
                    key: const ValueKey('clip-kb'),
                    onPressed: () async {
                      final ok = await KbIndex().putNote(title: '剪贴板', text: text);
                      ClipboardWatch.consume();
                      if (!context.mounted) return;
                      showBriefNotice(context, ok ? '已存进知识库：笔记/' : '没存进去：知识库目录写不了');
                    },
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, 34),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                    ),
                    child: const Text('存进知识库'),
                  ),
                  IconButton(
                    key: const ValueKey('clip-dismiss'),
                    tooltip: '不用',
                    onPressed: ClipboardWatch.dismiss,
                    icon: const Icon(Icons.close, size: 16),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
