// 整机存档: everything that is mine on this phone, as one zip file.
//
// Kept on purpose: 规则 (AGENTS.md), 技能 (skills), 原生插件 (dsh-go/), 插件配置
// (profiles/web), 对话历史 (sessions), 状态 (storages), app data (dsh-app), and
// the shared agents home.
//
// Kept out on purpose: credentials (never leave the phone in a file), caches,
// attachments and the speech model (hundreds of MB and re-creatable), and
// installed `node_modules` (re-installed on demand).

import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path_provider/path_provider.dart';

/// One entry a 整机存档 would carry, for the pre-flight size summary.
class ArchiveEntrySize {
  const ArchiveEntrySize(this.label, this.bytes, this.files);

  final String label;
  final int bytes;
  final int files;
}

class HomeArchive {
  HomeArchive(this.root);

  /// The on-device rootfs (guest `/`).
  final Directory root;

  /// Guest-relative paths that are directories inside the archive.
  static const includeDirs = <String>[
    'root/.dsh/skills',
    'root/.dsh/dsh-go',
    'root/.dsh/profiles',
    'root/.dsh/sessions',
    'root/.dsh/storages',
    'root/.dsh/dsh-app',
    'root/.agents',
  ];

  /// Guest-relative paths that are single files.
  static const includeFiles = <String>[
    'root/.dsh/AGENTS.md',
  ];

  /// Directory names never descended into.
  static const skipDirNames = <String>{
    'node_modules',
    '.git',
    'cache',
    '.cache',
    'tmp',
  };

  /// File names never packed, whatever directory they sit in.
  static const skipFileNames = <String>{
    '.credentials.yaml',
    '.anonymous-user-id',
    'credentials.yaml',
  };

  static Future<HomeArchive?> local() async {
    try {
      final support = await getApplicationSupportDirectory();
      final dir = Directory('${support.path}/runtime/rootfs');
      return dir.existsSync() ? HomeArchive(dir) : null;
    } catch (_) {
      return null;
    }
  }

  /// Sizes per include entry, before packing, so the sheet can say how big it is.
  List<ArchiveEntrySize> measure() {
    final out = <ArchiveEntrySize>[];
    for (final rel in includeDirs) {
      final dir = Directory('${root.path}/$rel');
      var bytes = 0;
      var files = 0;
      if (dir.existsSync()) {
        for (final entity in dir.listSync(recursive: true, followLinks: false)) {
          if (entity is! File) continue;
          if (skipFileNames.contains(_baseName(entity.path))) continue;
          bytes += entity.lengthSync();
          files++;
        }
      }
      out.add(ArchiveEntrySize(rel, bytes, files));
    }
    for (final rel in includeFiles) {
      final file = File('${root.path}/$rel');
      if (file.existsSync()) out.add(ArchiveEntrySize(rel, file.lengthSync(), 1));
    }
    return out;
  }

  /// Writes one zip holding every included entry. Returns the file written.
  Future<File> export() async {
    final archive = Archive();
    for (final rel in includeDirs) {
      _addDirectory(archive, rel);
    }
    for (final rel in includeFiles) {
      _addFile(archive, rel);
    }
    final bytes = Uint8List.fromList(ZipEncoder().encode(archive));
    final target = await _exportTarget();
    target.writeAsBytesSync(bytes, flush: true);
    return target;
  }

  /// Restores [zip] over this root. Existing files are overwritten; the archive
  /// never deletes anything it does not carry.
  Future<int> import(File zip) async {
    final archive = ZipDecoder().decodeBytes(zip.readAsBytesSync());
    var written = 0;
    for (final entry in archive.files) {
      if (!entry.isFile) continue;
      final rel = entry.name;
      if (_isUnsafe(rel)) continue;
      final target = File('${root.path}/$rel');
      await target.parent.create(recursive: true);
      final output = OutputFileStream(target.path);
      try {
        entry.writeContent(output);
      } finally {
        await output.close();
      }
      written++;
    }
    return written;
  }

  Future<File> _exportTarget() async {
    final now = DateTime.now();
    final stamp = '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}'
        '-${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}';
    final name = 'dsh-go-archive-$stamp.zip';
    // Prefer the shared Download folder so the file can be moved off the phone.
    final downloads = Directory('/sdcard/Download/DSH-Go');
    try {
      downloads.createSync(recursive: true);
      return File('${downloads.path}/$name');
    } catch (_) {
      final docs = await getApplicationDocumentsDirectory();
      return File('${docs.path}/$name');
    }
  }

  void _addDirectory(Archive archive, String rel) {
    final dir = Directory('${root.path}/$rel');
    if (!dir.existsSync()) return;
    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      _addFile(archive, _relative(entity.path));
    }
  }

  void _addFile(Archive archive, String rel) {
    if (skipFileNames.contains(_baseName(rel))) return;
    for (final segment in rel.split('/')) {
      if (skipDirNames.contains(segment)) return;
    }
    final file = File('${root.path}/$rel');
    if (!file.existsSync()) return;
    archive.add(ArchiveFile.bytes(rel, file.readAsBytesSync()));
  }

  String _relative(String absolute) =>
      absolute.startsWith('${root.path}/') ? absolute.substring(root.path.length + 1) : absolute;

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
