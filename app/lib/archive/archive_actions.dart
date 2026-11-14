// 存档的两个动作：按分类导出成一个 zip，或先预览再导入。
//
// 导出会写进 /sdcard/Download/DSH-Go/，能拷到别的手机；导入读文件选择器给的 zip，
// 写之前自己先留一份备份。

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../ui/common/brief_notice.dart';
import 'home_archive.dart';

String _humanBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

String _conflictLabel(ArchiveConflict conflict) => switch (conflict) {
  ArchiveConflict.overwrite => '覆盖',
  ArchiveConflict.skip => '跳过',
  ArchiveConflict.keepBoth => '保留两份',
};

String _conflictNote(ArchiveConflict conflict) => switch (conflict) {
  ArchiveConflict.overwrite => '本机同名文件会被包里的替换',
  ArchiveConflict.skip => '本机已有的文件不动，只补新的',
  ArchiveConflict.keepBoth => '包里的改名成「名字 (1)」，两个都留',
};

/// 勾选分类。返回选中的 id，取消返回 null。
Future<Set<String>?> _pickCategories(BuildContext context, List<ArchiveCategorySize> sizes) async {
  final selected = <String>{
    for (final size in sizes)
      if (HomeArchive.categoryOf(size.id)?.defaultOn ?? true) size.id,
  };
  return showDialog<Set<String>>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        var total = 0;
        final tiles = <Widget>[];
        for (final size in sizes) {
          if (selected.contains(size.id)) total += size.bytes;
          final note = HomeArchive.categoryOf(size.id)?.note ?? '';
          tiles.add(
            CheckboxListTile(
              key: ValueKey('archive-cat-${size.id}'),
              value: selected.contains(size.id),
              onChanged: (on) => setState(() {
                if (on ?? false) {
                  selected.add(size.id);
                } else {
                  selected.remove(size.id);
                }
              }),
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(size.label, style: const TextStyle(fontSize: 14)),
              subtitle: Text(
                '${_humanBytes(size.bytes)} · ${size.files} 个文件${note.isEmpty ? '' : ' · $note'}',
                style: const TextStyle(fontSize: 11),
              ),
            ),
          );
        }
        return AlertDialog(
          title: const Text('导出哪些'),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: tiles),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
            FilledButton(
              onPressed: selected.isEmpty ? null : () => Navigator.of(context).pop(selected),
              child: Text('导出 ${_humanBytes(total)}'),
            ),
          ],
        );
      },
    ),
  );
}

Future<void> exportArchive(BuildContext context) async {
  final fs = await HomeArchive.local();
  if (!context.mounted) return;
  if (fs == null) {
    showBriefNotice(context, '本机运行时还没装好，没有可导出内容');
    return;
  }
  final sizes = fs.measure();
  final picked = await _pickCategories(context, sizes);
  if (picked == null || picked.isEmpty || !context.mounted) return;
  try {
    final file = await fs.export(ids: picked);
    if (context.mounted) showBriefNotice(context, '已导出到 ${file.path}');
  } catch (error) {
    if (context.mounted) showBriefNotice(context, '导出失败：$error');
  }
}

Future<void> importArchive(BuildContext context) async {
  final fs = await HomeArchive.local();
  if (!context.mounted) return;
  if (fs == null) {
    showBriefNotice(context, '本机运行时还没装好，没有可恢复的位置');
    return;
  }
  final picked = await FilePicker.pickFiles();
  final path = picked.isEmpty ? null : picked.first.path;
  if (path == null || !context.mounted) return;
  final ArchivePreview preview;
  try {
    preview = await fs.previewImport(File(path));
  } catch (error) {
    if (context.mounted) showBriefNotice(context, '这个文件不是 DSH Go 的存档：$error');
    return;
  }
  if (!context.mounted) return;

  var conflict = ArchiveConflict.overwrite;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        final lines = <String>[];
        final at = preview.createdAt;
        if (at != null) {
          final d = '${at.year}-${at.month.toString().padLeft(2, '0')}-${at.day.toString().padLeft(2, '0')}';
          final t = '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
          lines.add('导出时间：$d $t');
        }
        if (!preview.hasManifest) lines.add('这个包没有清单（旧版本导出的），只能整包覆盖');
        if (preview.schemaVersion > HomeArchive.schemaVersion) lines.add('这个包比当前 App 新，可能有读不出来的内容');
        lines.add('新增 ${preview.newFiles} 个文件，覆盖 ${preview.replaceFiles} 个');
        if (preview.categories.isNotEmpty) {
          lines.add('包含：${preview.categories.map((c) => '${c.label}(${c.files})').join('、')}');
        }
        if (preview.presence['dav'] == true) lines.add('云盘：包里有地址和账号，密码要自己重新填');
        if (preview.presence['proxy'] == true) lines.add('代理：订阅地址含 token，不在包里，要自己重新导入');

        final options = <Widget>[];
        for (final option in ArchiveConflict.values) {
          final on = conflict == option;
          options.add(
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => setState(() => conflict = option),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(on ? Icons.radio_button_checked : Icons.radio_button_unchecked, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_conflictLabel(option), style: const TextStyle(fontSize: 13)),
                          Text(_conflictNote(option), style: const TextStyle(fontSize: 11)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }

        return AlertDialog(
          title: const Text('导入这份存档？'),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(File(path).uri.pathSegments.last, style: const TextStyle(fontSize: 13)),
                  const SizedBox(height: 8),
                  for (final line in lines)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(line, style: const TextStyle(fontSize: 12)),
                    ),
                  const SizedBox(height: 12),
                  const Text('同名文件怎么处理', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                  ...options,
                  const SizedBox(height: 4),
                  const Text('导入前会自动把现状备份到 下载/DSH-Go/', style: TextStyle(fontSize: 11)),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('导入')),
          ],
        );
      },
    ),
  );
  if (ok != true || !context.mounted) return;
  try {
    final result = await fs.import(File(path), conflict: conflict);
    if (!context.mounted) return;
    final backup = result.backup;
    showBriefNotice(
      context,
      result.skipped == 0
          ? '已导入 ${result.written} 个文件${backup == null ? '' : '，备份 ${backup.path.split('/').last}'}'
          : '已导入 ${result.written} 个，跳过 ${result.skipped} 个',
    );
  } catch (error) {
    if (context.mounted) showBriefNotice(context, '导入失败：$error');
  }
}
