// 整机存档's two actions: export everything to one zip, or restore such a zip.
//
// Export writes to /sdcard/Download/DSH-Go/ when it can, so the file can be
// copied to another phone; import reads a zip the picker returns.

import 'dart:async';
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

Future<bool> _confirm(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(confirmLabel)),
      ],
    ),
  );
  return result ?? false;
}

Future<void> exportArchive(BuildContext context) async {
  final fs = await HomeArchive.local();
  if (!context.mounted) return;
  if (fs == null) {
    showBriefNotice(context, '本机运行时还没装好，没有可导出内容');
    return;
  }
  final sizes = fs.measure();
  final total = sizes.fold<int>(0, (sum, e) => sum + e.bytes);
  final files = sizes.fold<int>(0, (sum, e) => sum + e.files);
  final ok = await _confirm(
    context,
    title: '导出整机存档',
    message: '会打包规则、技能、插件、插件配置、对话历史、状态数据，共 $files 个文件、${_humanBytes(total)}。\n\n密钥不在里面。',
    confirmLabel: '导出',
  );
  if (!ok || !context.mounted) return;
  try {
    final file = await fs.export();
    if (context.mounted) showBriefNotice(context, '已导出到 ${file.path}');
  } catch (e) {
    if (context.mounted) showBriefNotice(context, '导出失败：$e');
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
  final ok = await _confirm(
    context,
    title: '导入整机存档',
    message: '会用 ${path.split('/').last} 覆盖同名的规则、技能、插件配置、对话历史。\n\n导入完请到本机引擎里重启一次。',
    confirmLabel: '导入',
  );
  if (!ok || !context.mounted) return;
  try {
    final count = await fs.import(File(path));
    if (context.mounted) showBriefNotice(context, '已恢复 $count 个文件，记得重启引擎');
  } catch (e) {
    if (context.mounted) showBriefNotice(context, '导入失败：$e');
  }
}
