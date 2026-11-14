// 整机存档（b9-2d）：按分类勾选导出/导入，而不是一键全量。
//
// 包里有两类位置：
//   root/…  引擎 rootfs 里的文件（规则、技能、插件、对话、状态）
//   host/…  手机存储里的文件（知识库原始文档）
//   config/ 少量非机密的偏好项（站点库、云盘地址与账号）
//   app/    本 App 自己的文件（通知缓存）
// manifest.json 说明这份包是谁、什么时候、装了哪些分类，带 schemaVersion。
//
// 刻意不进包：一切密码与 token（云盘密码在 FlutterSecureStorage、代理订阅 URL 里
// 带 token），node_modules、缓存、语音模型、附件。导入时manifest 只记“已配置/
// 未配置”，让用户知道哪一项要自己重新填。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ui/kb/kb_index.dart';

/// 导入时同名文件怎么办。
enum ArchiveConflict {
  /// 用包里的覆盖本机的。
  overwrite,

  /// 本机已有就不动。
  skip,

  /// 两个都留，新的改名成 `名字 (1).ext`。
  keepBoth,
}

/// 一个可勾选的分类。
class ArchiveCategory {
  const ArchiveCategory({
    required this.id,
    required this.label,
    this.note = '',
    this.defaultOn = true,
    this.presenceOnly = false,
    this.guestDirs = const <String>[],
    this.guestFiles = const <String>[],
  });

  final String id;
  final String label;

  /// 一行说明：这类里到底有什么。
  final String note;

  /// 默认是否勾上。账号、订阅、缓存这类默认不勾。
  final bool defaultOn;

  /// 只导出“有没有配置”，不导出内容（密码、token 所在的那几类）。
  final bool presenceOnly;

  final List<String> guestDirs;
  final List<String> guestFiles;
}

/// 分类大小，给勾选界面显示。
class ArchiveCategorySize {
  const ArchiveCategorySize(this.id, this.label, this.bytes, this.files);

  final String id;
  final String label;
  final int bytes;
  final int files;
}

/// 打开一个包之后看到的东西。
class ArchivePreview {
  const ArchivePreview({
    required this.path,
    required this.hasManifest,
    required this.schemaVersion,
    required this.categories,
    required this.newFiles,
    required this.replaceFiles,
    this.createdAt,
    this.presence = const <String, bool>{},
  });

  final String path;
  final bool hasManifest;
  final int schemaVersion;
  final List<ArchiveCategorySize> categories;

  /// 包里、本机还没有的文件数。
  final int newFiles;

  /// 包里、本机已有、会被覆盖的文件数。
  final int replaceFiles;

  final DateTime? createdAt;

  /// 包里记的“某项已配置”，用于告诉用户还差什么。
  final Map<String, bool> presence;
}

/// 导入结果。
class ArchiveImportResult {
  const ArchiveImportResult({required this.written, required this.skipped, required this.backup});

  final int written;
  final int skipped;

  /// 导入前自动留的那份备份；没导成时为 null。
  final File? backup;
}

class HomeArchive {
  HomeArchive(this.root);

  /// The on-device rootfs (guest `/`).
  final Directory root;

  static const int schemaVersion = 1;

  /// 知识的原始文档在手机存储里，不在 rootfs 里。
  static const String kbDir = KbIndex.rootDir;

  static const List<ArchiveCategory> categories = <ArchiveCategory>[
    ArchiveCategory(
      id: 'sessions',
      label: '会话',
      note: '对话历史',
      guestDirs: <String>['root/.dsh/sessions'],
    ),
    ArchiveCategory(
      id: 'skills',
      label: '技能',
      note: '用户自己的技能目录',
      guestDirs: <String>['root/.dsh/skills'],
    ),
    ArchiveCategory(
      id: 'plugins',
      label: '插件',
      note: '原生插件与插件配置',
      guestDirs: <String>['root/.dsh/dsh-go', 'root/.dsh/profiles'],
    ),
    ArchiveCategory(
      id: 'settings',
      label: '设置',
      note: '规则、状态数据、App 数据',
      guestDirs: <String>['root/.dsh/storages', 'root/.dsh/dsh-app', 'root/.agents'],
      guestFiles: <String>['root/.dsh/AGENTS.md'],
    ),
    ArchiveCategory(
      id: 'kb',
      label: '知识库',
      note: '原始文档（导入后自动重建索引）',
    ),
    ArchiveCategory(
      id: 'sites',
      label: '站点库',
      note: '内置浏览器去过的站点与放行设置',
      defaultOn: false,
    ),
    ArchiveCategory(
      id: 'notify',
      label: '通知缓存',
      note: '最近收到的通知',
      defaultOn: false,
    ),
    ArchiveCategory(
      id: 'dav',
      label: '云盘账号',
      note: '地址与账号；密码不进包',
      defaultOn: false,
    ),
    ArchiveCategory(
      id: 'proxy',
      label: '代理订阅',
      note: '只记有没有订阅；订阅地址含 token，不进包',
      defaultOn: false,
      presenceOnly: true,
    ),
  ];

  static const Set<String> _skipDirNames = <String>{'node_modules', '.git', 'cache', '.cache', 'tmp', '.index'};

  static const Set<String> _skipFileNames = <String>{'.credentials.yaml', '.anonymous-user-id', 'credentials.yaml'};

  static const String _kbPrefix = 'host/kb/';

  static const String _configPath = 'config/prefs.json';

  static const String _notifyPath = 'app/notifications.json';

  static const List<String> _exportablePrefs = <String>['browser.sites', 'dav.address', 'dav.user'];

  static Future<HomeArchive?> local() async {
    try {
      final support = await getApplicationSupportDirectory();
      final dir = Directory('${support.path}/runtime/rootfs');
      return dir.existsSync() ? HomeArchive(dir) : null;
    } catch (_) {
      return null;
    }
  }

  static List<ArchiveCategory> defaults() =>
      [for (final category in categories) if (category.defaultOn) category];

  static ArchiveCategory? categoryOf(String id) {
    for (final category in categories) {
      if (category.id == id) return category;
    }
    return null;
  }

  /// 每类现在是多大，给勾选界面用；不读文件内容，只 stat。
  List<ArchiveCategorySize> measure([Iterable<String>? ids]) {
    final wanted = ids == null ? <String>{for (final c in categories) c.id} : ids.toSet();
    final out = <ArchiveCategorySize>[];
    for (final category in categories) {
      if (!wanted.contains(category.id)) continue;
      var bytes = 0;
      var files = 0;
      for (final rel in category.guestDirs) {
        final dir = Directory('${root.path}/$rel');
        if (!dir.existsSync()) continue;
        for (final entity in dir.listSync(recursive: true, followLinks: false)) {
          if (entity is! File) continue;
          if (_skipFileNames.contains(_baseName(entity.path))) continue;
          if (_hasSkippedSegment(entity.path)) continue;
          bytes += entity.lengthSync();
          files++;
        }
      }
      for (final rel in category.guestFiles) {
        final file = File('${root.path}/$rel');
        if (file.existsSync()) {
          bytes += file.lengthSync();
          files++;
        }
      }
      if (category.id == 'kb') {
        final dir = Directory(kbDir);
        if (dir.existsSync()) {
          for (final entity in dir.listSync(recursive: true, followLinks: false)) {
            if (entity is! File) continue;
            if (_hasSkippedSegment(entity.path)) continue;
            bytes += entity.lengthSync();
            files++;
          }
        }
      }
      out.add(ArchiveCategorySize(category.id, category.label, bytes, files));
    }
    return out;
  }

  /// 打包选中的分类。返回写好的 zip。
  Future<File> export({Iterable<String>? ids, String? nameHint}) async {
    final wanted = ids == null ? <String>{for (final c in categories) c.id} : ids.toSet();
    final archive = Archive();
    final sizes = <String, ArchiveCategorySize>{};
    final presence = <String, bool>{};
    final prefs = await _prefs();

    for (final category in categories) {
      if (!wanted.contains(category.id)) continue;
      var bytes = 0;
      var files = 0;
      for (final rel in category.guestDirs) {
        for (final file in _guestFiles(rel)) {
          bytes += file.lengthSync();
          files++;
          _addFile(archive, _relative(file.path));
        }
      }
      for (final rel in category.guestFiles) {
        final file = File('${root.path}/$rel');
        if (!file.existsSync()) continue;
        bytes += file.lengthSync();
        files++;
        _addFile(archive, rel);
      }
      switch (category.id) {
        case 'kb':
          for (final file in _kbFiles()) {
            bytes += file.lengthSync();
            files++;
            _addBytes(archive, '$_kbPrefix${_relativeToKb(file.path)}', file.readAsBytesSync());
          }
        case 'sites':
        {
          final raw = prefs?.getString('browser.sites');
          if (raw != null && raw.isNotEmpty) {
            bytes += raw.length;
            files++;
            _addJson(archive, _configPath, <String, Object?>{'browser.sites': raw});
          }
        }
        case 'dav':
        {
          final address = prefs?.getString('dav.address') ?? '';
          final user = prefs?.getString('dav.user') ?? '';
          presence['dav'] = address.isNotEmpty;
          final payload = <String, Object?>{};
          if (address.isNotEmpty) payload['dav.address'] = address;
          if (user.isNotEmpty) payload['dav.user'] = user;
          if (payload.isNotEmpty) {
            bytes += jsonEncode(payload).length;
            files++;
            _addJson(archive, _configPath, payload);
          }
        }
        case 'notify':
        {
          final file = await _notifyFile();
          if (file != null && await file.exists()) {
            bytes += await file.length();
            files++;
            _addBytes(archive, _notifyPath, await file.readAsBytes());
          }
        }
        case 'proxy':
        {
          final enabled = prefs?.getBool('proxy.enabled') ?? false;
          final port = prefs?.getInt('proxy.port') ?? 0;
          presence['proxy'] = enabled || (prefs?.getString('proxy.subscription') ?? '').isNotEmpty;
          if (enabled || port > 0) {
            final payload = <String, Object?>{'proxy.port': port};
            bytes += jsonEncode(payload).length;
            files++;
            _addJson(archive, _configPath, payload);
          }
        }
      }
      sizes[category.id] = ArchiveCategorySize(category.id, category.label, bytes, files);
    }

    final manifest = <String, Object?>{
      'schemaVersion': schemaVersion,
      'app': 'dsh-go',
      'createdAt': DateTime.now().toIso8601String(),
      'categories': [
        for (final size in sizes.values)
          {'id': size.id, 'label': size.label, 'files': size.files, 'bytes': size.bytes},
      ],
      'presence': presence,
      'neverPacked': ['云盘密码', '代理订阅地址', 'API Key', '登录凭据'],
    };
    _addJson(archive, 'manifest.json', manifest);

    final bytes = Uint8List.fromList(ZipEncoder().encode(archive));
    final target = File('${await _exportDir()}/${nameHint ?? 'dsh-go-archive'}-${_stamp()}.zip');
    target.writeAsBytesSync(bytes, flush: true);
    return target;
  }

  /// 只看包里有什么、会不会覆盖本机文件，不写入任何东西。
  Future<ArchivePreview> previewImport(File zip) async {
    final archive = _decode(zip);
    final manifest = _manifestOf(archive);
    final presence = <String, bool>{};
    final rawPresence = manifest?['presence'];
    if (rawPresence is Map) {
      for (final entry in rawPresence.entries) {
        presence['${entry.key}'] = entry.value == true;
      }
    }
    var newFiles = 0;
    var replaceFiles = 0;
    for (final entry in archive.files) {
      if (!entry.isFile || entry.name == 'manifest.json') continue;
      final target = await _importTarget(entry.name);
      if (target == null) continue;
      if (target.existsSync()) {
        replaceFiles++;
      } else {
        newFiles++;
      }
    }
    DateTime? createdAt;
    final rawCreated = manifest?['createdAt'];
    if (rawCreated is String) createdAt = DateTime.tryParse(rawCreated);
    final categories = <ArchiveCategorySize>[];
    final rawCategories = manifest?['categories'];
    if (rawCategories is List) {
      for (final item in rawCategories) {
        if (item is! Map) continue;
        final id = '${item['id']}';
        categories.add(
          ArchiveCategorySize(
            id,
            '${item['label'] ?? categoryOf(id)?.label ?? id}',
            item['bytes'] is int ? item['bytes'] as int : 0,
            item['files'] is int ? item['files'] as int : 0,
          ),
        );
      }
    }
    final version = manifest?['schemaVersion'];
    return ArchivePreview(
      path: zip.path,
      hasManifest: manifest != null,
      schemaVersion: version is int ? version : 0,
      categories: categories,
      newFiles: newFiles,
      replaceFiles: replaceFiles,
      createdAt: createdAt,
      presence: presence,
    );
  }

  /// 写入 [zip]；写之前先把本机现状备份一份。分类只用来挑备份内容。
  Future<ArchiveImportResult> import(File zip, {ArchiveConflict conflict = ArchiveConflict.overwrite}) async {
    final archive = _decode(zip);
    final manifest = _manifestOf(archive);
    final rawCategories = manifest?['categories'];
    final ids = <String>[];
    if (rawCategories is List) {
      for (final item in rawCategories) {
        if (item is Map && categoryOf('${item['id']}') != null) ids.add('${item['id']}');
      }
    }
    File? backup;
    try {
      backup = await export(ids: ids.isEmpty ? null : ids, nameHint: 'dsh-go-before-import');
    } catch (_) {
      // 备份失败不拦导入；结果里 backup 为 null，界面会说没留备份。
    }
    var written = 0;
    var skipped = 0;
    final prefs = await _prefs();
    var touchedKb = false;
    final configPayload = <String, Object?>{};
    for (final entry in archive.files) {
      if (!entry.isFile || entry.name == 'manifest.json') continue;
      if (entry.name == _configPath) {
        try {
          final bytes = entry.readBytes();
          if (bytes != null) {
            final decoded = jsonDecode(utf8.decode(bytes));
            if (decoded is Map) configPayload.addAll(<String, Object?>{for (final e in decoded.entries) '${e.key}': e.value});
          }
        } catch (_) {}
        continue;
      }
      final target = await _importTarget(entry.name);
      if (target == null) {
        skipped++;
        continue;
      }
      final exists = target.existsSync();
      if (exists && conflict == ArchiveConflict.skip) {
        skipped++;
        continue;
      }
      var destination = target;
      if (exists && conflict == ArchiveConflict.keepBoth) destination = _freeName(target);
      try {
        await destination.parent.create(recursive: true);
        final output = OutputFileStream(destination.path);
        try {
          entry.writeContent(output);
        } finally {
          await output.close();
        }
        written++;
        if (entry.name.startsWith(_kbPrefix)) touchedKb = true;
      } catch (_) {
        skipped++;
      }
    }
    if (prefs != null && configPayload.isNotEmpty) {
      for (final key in _exportablePrefs) {
        final value = configPayload[key];
        if (value == null) continue;
        await prefs.setString(key, '$value');
      }
    }
    if (touchedKb) {
      // 索引是派生数据：导入原始文件后重建一次，不把 .index 打进包里。
      await KbIndex().refresh();
    }
    return ArchiveImportResult(written: written, skipped: skipped, backup: backup);
  }

  // ── 内部 ────────────────────────────────────────────────────────────────

  Future<SharedPreferences?> _prefs() async {
    try {
      return await SharedPreferences.getInstance();
    } catch (_) {
      return null;
    }
  }

  Future<File?> _notifyFile() async {
    try {
      final support = await getApplicationSupportDirectory();
      return File('${support.path}/notifications.json');
    } catch (_) {
      return null;
    }
  }

  Archive _decode(File zip) => ZipDecoder().decodeBytes(zip.readAsBytesSync());

  Map<String, Object?>? _manifestOf(Archive archive) {
    for (final entry in archive.files) {
      if (entry.name != 'manifest.json' || !entry.isFile) continue;
      try {
        final bytes = entry.readBytes();
        if (bytes == null) return null;
        final decoded = jsonDecode(utf8.decode(bytes));
        if (decoded is Map) return <String, Object?>{for (final e in decoded.entries) '${e.key}': e.value};
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  /// 包里的一条记录该写到哪；不安全或认不出的前缀返回 null。
  Future<File?> _importTarget(String name) async {
    if (_isUnsafe(name)) return null;
    if (name.startsWith(_kbPrefix)) {
      final rel = name.substring(_kbPrefix.length);
      if (_isUnsafe(rel)) return null;
      return File('$kbDir/$rel');
    }
    if (name == _notifyPath) return _notifyFile();
    if (name.startsWith('root/')) return File('${root.path}/$name');
    return null;
  }

  List<File> _guestFiles(String rel) {
    final dir = Directory('${root.path}/$rel');
    if (!dir.existsSync()) return const <File>[];
    final out = <File>[];
    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      if (_skipFileNames.contains(_baseName(entity.path))) continue;
      if (_hasSkippedSegment(entity.path)) continue;
      out.add(entity);
    }
    return out;
  }

  List<File> _kbFiles() {
    final dir = Directory(kbDir);
    if (!dir.existsSync()) return const <File>[];
    final out = <File>[];
    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      if (_hasSkippedSegment(entity.path)) continue;
      out.add(entity);
    }
    return out;
  }

  void _addFile(Archive archive, String rel) {
    if (_skipFileNames.contains(_baseName(rel))) return;
    for (final segment in rel.split('/')) {
      if (_skipDirNames.contains(segment)) return;
    }
    final file = File('${root.path}/$rel');
    if (!file.existsSync()) return;
    _addBytes(archive, rel, file.readAsBytesSync());
  }

  void _addBytes(Archive archive, String rel, List<int> bytes) {
    archive.add(ArchiveFile.bytes(rel, bytes));
  }

  void _addJson(Archive archive, String rel, Map<String, Object?> value) {
    _addBytes(archive, rel, utf8.encode(jsonEncode(value)));
  }

  String _relative(String absolute) =>
      absolute.startsWith('${root.path}/') ? absolute.substring(root.path.length + 1) : absolute;

  String _relativeToKb(String absolute) =>
      absolute.startsWith('$kbDir/') ? absolute.substring(kbDir.length + 1) : _baseName(absolute);

  bool _hasSkippedSegment(String path) {
    for (final segment in path.split('/')) {
      if (_skipDirNames.contains(segment)) return true;
    }
    return false;
  }

  Future<String> _exportDir() async {
    final downloads = Directory('/sdcard/Download/DSH-Go');
    try {
      await downloads.create(recursive: true);
      return downloads.path;
    } catch (_) {
      final docs = await getApplicationDocumentsDirectory();
      return docs.path;
    }
  }

  /// 同名文件改成 `名字 (1).ext`，和浏览器下载的命名一致。
  File _freeName(File file) {
    final name = _baseName(file.path);
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final ext = dot > 0 ? name.substring(dot) : '';
    final dir = file.parent.path;
    var candidate = file;
    var n = 1;
    while (candidate.existsSync()) {
      candidate = File('$dir/$stem ($n)$ext');
      n++;
      if (n > 500) break;
    }
    return candidate;
  }

  static String _stamp() {
    final now = DateTime.now();
    final d = '${now.year}${_two(now.month)}${_two(now.day)}';
    return '$d-${_two(now.hour)}${_two(now.minute)}';
  }

  static String _two(int value) => value.toString().padLeft(2, '0');

  static String _baseName(String path) => path.split('/').last;

  /// Rejects absolute paths and `..` escapes before anything is written.
  static bool _isUnsafe(String rel) {
    if (rel.isEmpty) return true;
    if (rel.startsWith('/')) return true;
    for (final segment in rel.split('/')) {
      if (segment == '..' || segment.isEmpty) return true;
    }
    return false;
  }
}
