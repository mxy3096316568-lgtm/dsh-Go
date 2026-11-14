// 知识库页面：能力控制 → 知识库。索引本身在 kb_index.dart，这里只做展示与
// 增删入口：放进去的是什么、切成了几块、删掉、重建。
//
// 删除是本页唯一的破坏性操作，所以每一步都先问一次；导入和重建只读源文件，
// 不值得多一次确认。
import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../common/brief_notice.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import 'kb_index.dart';
import '../settings/settings_widgets.dart';

/// `1.2 KB` / `340 B` / `3.4 MB`.
String _fmtBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}

String _basename(String path) {
  final at = path.lastIndexOf('/');
  return at < 0 ? path : path.substring(at + 1);
}

/// `网页/example.com/abc.md` → `网页/example.com`; a root file has no folder.
String? _dirOf(String path) {
  final at = path.lastIndexOf('/');
  return at <= 0 ? null : path.substring(0, at);
}

String _when(int ms) {
  if (ms <= 0) return '还没有建立过';
  final at = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int v) => v.toString().padLeft(2, '0');
  final now = DateTime.now();
  final sameDay = at.year == now.year && at.month == now.month && at.day == now.day;
  final clock = '${two(at.hour)}:${two(at.minute)}';
  return sameDay ? '今天 $clock' : '${at.month}月${at.day}日 $clock';
}

class KbPage extends StatefulWidget {
  const KbPage({super.key});

  static Route<void> route() => MaterialPageRoute<void>(builder: (_) => const KbPage());

  @override
  State<KbPage> createState() => _KbPageState();
}

class _KbPageState extends State<KbPage> {
  final KbIndex _kb = KbIndex();
  KbStats _stats = const KbStats();
  List<KbDoc> _docs = const <KbDoc>[];
  bool _busy = false;

  /// What the last action did, shown under the 现状 card.
  String? _note;

  @override
  void initState() {
    super.initState();
    // Opening the page is also the moment files dropped in by a file manager
    // should appear, so this is a refresh and not just a read.
    unawaited(_load(rebuild: false));
  }

  Future<void> _load({required bool rebuild}) async {
    if (mounted) {
      setState(() {
        _busy = true;
        _note = rebuild ? '正在重建索引，文档多时要等一会儿…' : null;
      });
    }
    try {
      final stats = rebuild ? await _kb.rebuild() : await _kb.refresh();
      final docs = await _kb.docs();
      if (!mounted) return;
      setState(() {
        _stats = stats;
        _docs = docs;
        _busy = false;
        if (rebuild) _note = '重建完成：${stats.docs} 个文档、${stats.chunks} 块';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _note = '读索引失败：$error';
      });
    }
  }

  Future<void> _importFiles() async {
    List<PlatformFile> picked;
    try {
      picked = await FilePicker.pickFiles();
    } catch (error) {
      if (mounted) showBriefNotice(context, '打不开文件选择器：$error');
      return;
    }
    if (picked.isEmpty || !mounted) return;
    setState(() {
      _busy = true;
      _note = '正在导入 ${picked.length} 个文件…';
    });
    var imported = 0;
    final skipped = <String>[];
    for (final file in picked) {
      final path = file.path;
      final ext = file.name.contains('.') ? file.name.split('.').last.toLowerCase() : '';
      if (path == null || !KbIndex.supportedExtensions.contains(ext)) {
        skipped.add(file.name);
        continue;
      }
      await _kb.importFile(path);
      imported += 1;
    }
    final stats = await _kb.stats();
    final docs = await _kb.docs();
    if (!mounted) return;
    setState(() {
      _stats = stats;
      _docs = docs;
      _busy = false;
      _note = skipped.isEmpty
          ? '导入 $imported 个文件'
          : '导入 $imported 个，跳过 ${skipped.length} 个（只收 ${KbIndex.supportedExtensions.join(' / ')}）：${skipped.take(3).join('、')}';
    });
  }

  Future<void> _delete(KbDoc doc) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除这个文档？'),
        content: Text('会删掉手机上的源文件：\n${doc.path}\n\n对应的 ${doc.chunkCount} 块也会一起移除，不能撤销。'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('删除')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final done = await _kb.deleteDoc(doc.path);
    if (!mounted) return;
    if (!done) {
      showBriefNotice(context, '没删掉：文件可能已经被移走或没有权限');
      await _load(rebuild: false);
      return;
    }
    final stats = await _kb.stats();
    final docs = await _kb.docs();
    if (!mounted) return;
    setState(() {
      _stats = stats;
      _docs = docs;
      _note = '已删除 ${_basename(doc.path)}';
    });
  }

  Future<void> _preview(KbDoc doc) async {
    final chunks = <String>[
      for (var i = 0; i < doc.chunkCount && i < 3; i++) _kb.readChunkText(doc.path, i) ?? '',
    ].where((text) => text.isNotEmpty).toList();
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_basename(doc.path)),
        content: SizedBox(
          width: double.maxFinite,
          child: chunks.isEmpty
              ? const Text('这个文档的正文是空的。')
              : SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final text in chunks)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text(text, style: const TextStyle(fontSize: 12)),
                        ),
                      if (doc.chunkCount > chunks.length)
                        Text(
                          '…… 还有 ${doc.chunkCount - chunks.length} 块，助手会用 kb_search 取',
                          style: const TextStyle(fontSize: 12),
                        ),
                    ],
                  ),
                ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('关闭')),
        ],
      ),
    );
  }

  /// `12 块 · 24.0 KB · 笔记/工作`.
  String _docLine(KbDoc doc) {
    final dir = _dirOf(doc.path);
    return [
      '${doc.chunkCount} 块',
      _fmtBytes(doc.bytes),
      if (dir != null) dir,
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final note = _note;
    return AppPage.list(
      title: '知识库',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            '放自己的资料进来，助手回答前会先搜这里，并且告诉你出处。\n'
            '文件夹：${KbIndex.rootDir}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        SettingsSection(
          title: '现状',
          children: [
            SettingsTile(
              key: const ValueKey('kb-docs'),
              icon: AppIcons.skill,
              title: '已收录',
              value: Text('${_stats.docs} 个 · ${_stats.chunks} 块'),
            ),
            SettingsTile(
              icon: AppIcons.files,
              title: '占用',
              subtitle: _stats.skippedFiles == 0 ? null : '还有 ${_stats.skippedFiles} 个文件不支持，没收录',
              value: Text(_fmtBytes(_stats.totalBytes)),
            ),
            SettingsTile(
              icon: AppIcons.bookmark,
              title: '上次重建',
              value: Text(_when(_stats.builtAtMs)),
            ),
            SettingsTile(
              key: const ValueKey('kb-import'),
              icon: AppIcons.uploadToHost,
              title: '导入文件',
              subtitle: 'txt / md / html / csv / json / docx，会复制进知识库文件夹',
              onTap: _busy ? null : _importFiles,
            ),
            SettingsTile(
              key: const ValueKey('kb-reindex'),
              icon: AppIcons.swap,
              title: '重建索引',
              subtitle: _busy ? '正在处理…' : '把全部文档重新抽文本、重新切块',
              onTap: _busy ? null : () => unawaited(_load(rebuild: true)),
            ),
          ],
        ),
        if (note != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(note, style: Theme.of(context).textTheme.bodySmall),
          ),
        SettingsSection(
          title: '文档',
          children: [
            if (_docs.isEmpty)
              SettingsTile(
                title: '还没有文档',
                subtitle: '用上面的「导入文件」，或把文件拷进知识库文件夹后回到这一页',
              ),
            for (final doc in _docs.take(300))
              SettingsTile(
                key: ValueKey('kb-doc-${doc.path}'),
                title: _basename(doc.path),
                subtitle: _docLine(doc),
                onTap: () => unawaited(_preview(doc)),
                trailing: IconButton(
                  tooltip: '删除',
                  icon: const Icon(Icons.delete_outline, size: 20),
                  onPressed: _busy ? null : () => unawaited(_delete(doc)),
                ),
              ),
            if (_docs.length > 300)
              SettingsTile(
                title: '还有 ${_docs.length - 300} 个没显示',
                subtitle: '列表只显示前 300 个，检索和助手读的是全部',
              ),
          ],
        ),
      ],
    );
  }
}
