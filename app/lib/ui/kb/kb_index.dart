// 知识库索引：b9-2 的 RAG 需要一层“扫目录 → 抽文本 → 切块 → 检索”，而这一层
// 不应该被界面绑死。这里刻意只 import dart:convert、dart:io 和三个纯 Dart 包
// （archive、crypto、html），不碰 Flutter、path_provider、sqlite：单元测试、
// 后台 isolate 和 CLI 都能直接调用，也不会把新的平台依赖带进 App。
//
// 索引写在源目录的 .index/index.json：源文件保持用户可读、可手动整理，派生数据
// 集中在一处；扫描时所有以 . 开头的目录/文件都跳过，.index 自然不会索引自己。
// 每次构建都临时文件 + rename，保证手机被杀进程时磁盘上不会只剩半个 JSON。
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:html/parser.dart' as html_parser;

/// 一条检索命中。
///
/// text 截到 400 字是为了给上下文窗口留余量；snippet 只取命中位置附近，
/// 列表里展示时不用渲染整块。
class KbHit {
  const KbHit({
    required this.docPath,
    required this.chunkIndex,
    required this.score,
    required this.text,
    required this.snippet,
  });

  /// 相对 [KbIndex.rootDir] 的路径，统一用 `/` 分隔。
  final String docPath;

  /// 文档内从 0 开始的块序号。
  final int chunkIndex;

  /// 词频总和 + 命中词种类奖励，越大越相关。
  final int score;

  /// 块原文，最多 400 字。
  final String text;

  /// 第一个命中词前后各 40 字的摘录。
  final String snippet;
}

/// 一个切块。start 是它在清洗后全文里的 UTF-16 偏移，用来解释重叠和回溯位置。
class KbChunk {
  const KbChunk({required this.index, required this.start, required this.text});

  /// 从 0 开始的块序号。
  final int index;

  /// 在清洗后全文中的起始字符偏移。
  final int start;

  /// 块文本（已 trim，块之间可能重叠）。
  final String text;

  Map<String, Object?> toJson() => <String, Object?>{'index': index, 'start': start, 'text': text};

  factory KbChunk.fromJson(Map<String, Object?> json) => KbChunk(
    index: _asInt(json['index']),
    start: _asInt(json['start']),
    text: json['text'] is String ? json['text'] as String : '',
  );
}

/// 索引里的一个文档及其全部切块。
class KbDoc {
  const KbDoc({
    required this.path,
    required this.bytes,
    required this.mtimeMs,
    required this.sha1,
    required this.chunks,
  });

  /// 相对 [KbIndex.rootDir] 的路径，统一用 `/` 分隔。
  final String path;

  /// 源文件字节数。
  final int bytes;

  /// 源文件修改时间（毫秒时间戳），与 bytes 一起做增量判定。
  final int mtimeMs;

  /// 源文件 SHA-1，供索引使用方核对内容是否变过。
  final String sha1;

  /// 切块，按 [KbChunk.index] 递增。
  final List<KbChunk> chunks;

  /// 块数。
  int get chunkCount => chunks.length;

  Map<String, Object?> toJson() => <String, Object?>{
    'path': path,
    'bytes': bytes,
    'mtimeMs': mtimeMs,
    'sha1': sha1,
    'chunks': <Object?>[for (final chunk in chunks) chunk.toJson()],
  };

  factory KbDoc.fromJson(Map<String, Object?> json) {
    final chunks = <KbChunk>[];
    final rawChunks = json['chunks'];
    if (rawChunks is List) {
      for (final raw in rawChunks) {
        if (raw is Map) chunks.add(KbChunk.fromJson(Map<String, Object?>.from(raw)));
      }
    }
    return KbDoc(
      path: json['path'] is String ? json['path'] as String : '',
      bytes: _asInt(json['bytes']),
      mtimeMs: _asInt(json['mtimeMs']),
      sha1: json['sha1'] is String ? json['sha1'] as String : '',
      chunks: chunks,
    );
  }
}

/// 知识库概况。builtAtMs 为 0 表示还没有成功构建过。
class KbStats {
  const KbStats({this.docs = 0, this.chunks = 0, this.totalBytes = 0, this.builtAtMs = 0, this.skippedFiles = 0});

  /// 已索引文档数。
  final int docs;

  /// 全部文档的切块总数。
  final int chunks;

  /// 已索引源文件的总字节数。
  final int totalBytes;

  /// 上次成功写入索引的时间（毫秒时间戳）。
  final int builtAtMs;

  /// 本次扫描跳过的文件数：不支持的扩展名，或解析失败的文件。
  final int skippedFiles;
}

/// [KbIndex.putWebDoc] 的结果：新页面 / 内容变了 / 没变 / 写不进去。
enum KbPutResult { added, updated, unchanged, failed }

/// 知识库索引：扫描 [rootDir]，把支持的文档抽成文本并切成重叠块，写入
/// [indexDir]/index.json，再提供增量刷新、检索和增删入口。
///
/// 所有公开方法都自己吞掉异常：知识库是辅助功能，目录没权限、单个文件损坏或
/// 索引写到一半失败，都不该把异常抛进聊天主流程。调用方拿到空列表/零统计时，
/// 下一次 refresh 会再试。
class KbIndex {
  KbIndex();

  /// 用户放知识库源文件的目录。
  static const String rootDir = '/sdcard/Download/DSH-Go/知识库';

  /// 派生索引目录；扫描时因为是隐藏目录而整体跳过。
  static const String indexDir = '/sdcard/Download/DSH-Go/知识库/.index';

  static const String _indexPath = '$indexDir/index.json';

  /// 网页抓来的文档放在这个子目录里，一眼能和用户自己的资料分开。
  static const String webDirName = '网页';

  static const String _webMapPath = '$indexDir/web.json';

  /// 能真正抽出文本的扩展名（小写，不含点）。
  static const Set<String> supportedExtensions = <String>{
    'txt',
    'md',
    'markdown',
    'html',
    'htm',
    'csv',
    'json',
    'docx',
  };

  /// 明确已知但暂不索引的扩展名。PDF 需要 OCR/版面分析，纯 Dart 做不可靠，
  /// 所以和其它二进制/办公格式一起跳过；扫描时仍会计入 skippedFiles。
  static const Set<String> skippedExtensions = <String>{
    'pdf',
    'doc',
    'docm',
    'dot',
    'xls',
    'xlsx',
    'ppt',
    'pptx',
    'epub',
    'rtf',
    'odt',
    'ods',
    'odp',
    'png',
    'jpg',
    'jpeg',
    'gif',
    'webp',
    'heic',
    'bmp',
    'svg',
    'tif',
    'tiff',
    'mp3',
    'm4a',
    'wav',
    'ogg',
    'flac',
    'mp4',
    'mov',
    'mkv',
    'avi',
    'webm',
    'zip',
    'rar',
    '7z',
    'gz',
    'tar',
    'apk',
    'exe',
    'dmg',
    'iso',
  };

  // 800/100 的块在手机屏幕上大约是一屏正文：再小会切碎上下文，再大会让一次
  // 检索返回太多无关文字。480 是“至少保留六成内容再找句号”的下限，避免为了
  // 一个换行把块切得过短。
  static const int _chunkSize = 800;
  static const int _chunkOverlap = 100;
  static const int _minChunkSize = 480;
  static const int _textLimit = 400;
  static const int _snippetRadius = 40;

  static final RegExp _whitespace = RegExp(r'\s+');
  static final RegExp _cjk = RegExp(r'[\u4e00-\u9fff]');
  static final RegExp _cjkRun = RegExp(r'[\u4e00-\u9fff]+');
  static final RegExp _edgePunctuation = RegExp(r'^[^\w\u4e00-\u9fff]+|[^\w\u4e00-\u9fff]+$');
  static final RegExp _xmlTag = RegExp(r'<[^>]+>');
  static final RegExp _paragraphEnd = RegExp(r'</w:p\s*>');
  static final RegExp _lineBreak = RegExp(r'<w:br\s*/>');
  static final RegExp _tab = RegExp(r'<w:tab\s*/>');
  static final RegExp _entity = RegExp(r'&(#[0-9]+|#x[0-9a-fA-F]+|amp|lt|gt|quot|apos);');

  List<KbDoc> _docs = const <KbDoc>[];
  int _builtAtMs = 0;
  int _skippedFiles = 0;
  bool _loaded = false;

  /// 网页抓进来的文档记在 `.index/web.json`：url → 文件名、url → 正文哈希。
  /// 只放在索引这一侧，源目录里仍然是普通的 .md，用户看得懂、删得掉。
  Map<String, String> _webFiles = <String, String>{};
  Map<String, String> _webHashes = <String, String>{};
  bool _webLoaded = false;

  /// 全量重建：忽略旧索引，逐个文件重新解析。
  ///
  /// 用户主动点“重建”或清洗/切块规则升级时用它；只按 (bytes, mtimeMs) 复用
  /// 旧块会让规则升级对未改动文件失效，所以这里必须强制重算。
  Future<KbStats> rebuild() async {
    try {
      return await _build(force: true);
    } catch (_) {
      return _currentStats();
    }
  }

  /// 增量刷新：新增、改动、删除的文件才会重新解析，其余复用旧 chunks。
  ///
  /// App 启动、从分享面板导入后调用；正常使用比 [rebuild] 便宜得多。
  Future<KbStats> refresh() async {
    try {
      return await _build(force: false);
    } catch (_) {
      return _currentStats();
    }
  }

  /// 检索 [query]，返回分数最高的前 [limit] 块。
  ///
  /// 空查询、limit <= 0 或索引读取失败都返回空列表；调用方不需要区分“没索引”
  /// 和“没命中”。
  Future<List<KbHit>> search(String query, {int limit = 8}) async {
    try {
      if (limit <= 0 || query.trim().isEmpty) return const <KbHit>[];
      final terms = _queryTerms(query);
      if (terms.isEmpty) return const <KbHit>[];
      await _ensureLoaded();
      final hits = <KbHit>[];
      for (final doc in _docs) {
        for (final chunk in doc.chunks) {
          final lower = chunk.text.toLowerCase();
          var occurrences = 0;
          var kinds = 0;
          var firstAt = -1;
          var firstLength = 0;
          for (final term in terms) {
            final count = _countOccurrences(lower, term);
            if (count == 0) continue;
            kinds += 1;
            occurrences += count;
            final at = lower.indexOf(term);
            if (at >= 0 && (firstAt < 0 || at < firstAt)) {
              firstAt = at;
              firstLength = term.length;
            }
          }
          if (kinds == 0) continue;
          // 命中词种类比同一个词重复多次更能说明这段相关，所以每多一种 +2。
          final score = occurrences + (kinds > 1 ? (kinds - 1) * 2 : 0);
          hits.add(
            KbHit(
              docPath: doc.path,
              chunkIndex: chunk.index,
              score: score,
              text: _clip(chunk.text, _textLimit),
              snippet: firstAt < 0 ? _clip(chunk.text, 120) : _snippet(chunk.text, firstAt, firstLength),
            ),
          );
        }
      }
      hits.sort((a, b) {
        final byScore = b.score.compareTo(a.score);
        if (byScore != 0) return byScore;
        final byPath = a.docPath.compareTo(b.docPath);
        if (byPath != 0) return byPath;
        return a.chunkIndex.compareTo(b.chunkIndex);
      });
      return hits.take(limit).toList(growable: false);
    } catch (_) {
      return const <KbHit>[];
    }
  }

  /// 文档数、块数、总字节和上次构建时间；读不到索引时全为 0。
  Future<KbStats> stats() async {
    try {
      await _ensureLoaded();
      return _currentStats();
    } catch (_) {
      return const KbStats();
    }
  }

  /// 每个文档的路径、字节、块数、mtime。按路径排序，界面可以稳定展示。
  Future<List<KbDoc>> docs() async {
    try {
      await _ensureLoaded();
      return List<KbDoc>.unmodifiable(_docs);
    } catch (_) {
      return const <KbDoc>[];
    }
  }

  /// 把外部文件复制进 [rootDir] 并刷新索引。
  ///
  /// 源文件已经在 rootDir 下时不再复制（用户可能只是拖进来了），直接刷新。
  /// 同名目标按 `名字 (1).md` 递增，避免覆盖用户已有知识。
  Future<void> importFile(String sourcePath) async {
    try {
      await _ensureLoaded();
      final source = File(sourcePath);
      if (!await source.exists()) return;
      if (_relFromRoot(sourcePath) == null) {
        await Directory(rootDir).create(recursive: true);
        final target = '$rootDir/${_uniqueName(_basename(sourcePath))}';
        await source.copy(target);
      }
      await refresh();
    } catch (_) {
      // 复制或写索引失败就保持旧索引；调用方看到文档数没变即可判断没成功。
    }
  }

  /// 把一页网页正文写成知识库文档，按 URL 增量：正文没变就不动文件。
  ///
  /// 返回 added（新页面）/ updated（内容变了）/ unchanged（和上次一样）/ failed。
  /// 这里只写文件，不重建索引：抓一整站时由调用方最后统一 refresh 一次，
  /// 否则每次写盘都要重扫一遍整个目录。
  Future<KbPutResult> putWebDoc({
    required String url,
    required String text,
    String? title,
    DateTime? fetchedAt,
  }) async {
    try {
      final normalized = _normalizeUrl(url);
      if (normalized == null) return KbPutResult.failed;
      final body = text.trim();
      if (body.isEmpty) return KbPutResult.failed;
      await _ensureWebLoaded();
      final hash = sha1.convert(utf8.encode(body)).toString();
      var rel = _webFiles[normalized];
      if (rel != null && !File('$rootDir/$rel').existsSync()) {
        // 用户删过这个文件：下次抓取当作新页面，别把已删的东西又写回去。
        rel = null;
        _webFiles.remove(normalized);
        _webHashes.remove(normalized);
      }
      if (rel != null && _webHashes[normalized] == hash) return KbPutResult.unchanged;
      final existed = rel != null;
      rel ??= _newWebPath(normalized, title);
      final file = File('$rootDir/$rel');
      await file.parent.create(recursive: true);
      final at = fetchedAt ?? DateTime.now();
      await file.writeAsString(_webDocText(normalized, title, body, at), flush: true);
      _webFiles[normalized] = rel;
      _webHashes[normalized] = hash;
      await _saveWebMap();
      return existed ? KbPutResult.updated : KbPutResult.added;
    } catch (_) {
      return KbPutResult.failed;
    }
  }

  /// 抓取过的网页数（web.json 里的 URL 数）。界面用来区分“自己的文件”和“抓来的”。
  Future<int> webDocCount() async {
    await _ensureWebLoaded();
    return _webFiles.length;
  }

  /// 删除 [docPath] 对应的源文件并更新索引；路径非法或删除失败返回 false。
  Future<bool> deleteDoc(String docPath) async {
    try {
      await _ensureLoaded();
      final rel = _relKey(docPath);
      if (rel == null) return false;
      final file = File('$rootDir/$rel');
      if (await file.exists()) await file.delete();
      // 先从内存摘掉，刷新写盘失败时 search/readChunkText 也不会再返回已删文件。
      _docs = <KbDoc>[
        for (final doc in _docs)
          if (doc.path != rel) doc,
      ];
      await _ensureWebLoaded();
      var dropped = false;
      for (final entry in _webFiles.entries.toList()) {
        if (entry.value != rel) continue;
        _webFiles.remove(entry.key);
        _webHashes.remove(entry.key);
        dropped = true;
      }
      if (dropped) await _saveWebMap();
      await _build(force: false);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 从索引取整块原文；文档/块不存在或索引损坏返回 null。
  String? readChunkText(String docPath, int chunkIndex) {
    try {
      if (chunkIndex < 0) return null;
      _loadSync();
      final rel = _relKey(docPath);
      if (rel == null) return null;
      for (final doc in _docs) {
        if (doc.path != rel) continue;
        for (final chunk in doc.chunks) {
          if (chunk.index == chunkIndex) return chunk.text;
        }
        return null;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<(List<File>, int)> _scan(Directory dir, String prefix) async {
    final files = <File>[];
    var skipped = 0;
    try {
      await for (final entity in dir.list(followLinks: false)) {
        final name = _basename(entity.path);
        if (name.startsWith('.')) continue;
        final rel = prefix.isEmpty ? name : '$prefix/$name';
        if (entity is Directory) {
          final (childFiles, childSkipped) = await _scan(entity, rel);
          files.addAll(childFiles);
          skipped += childSkipped;
        } else if (entity is File) {
          if (!supportedExtensions.contains(_extensionOf(name))) {
            skipped += 1;
            continue;
          }
          files.add(entity);
        }
      }
    } catch (_) {
      // 单个子目录读不了（权限、扫描中被删）不影响其余目录和已有索引。
    }
    return (files, skipped);
  }

  Future<KbStats> _build({required bool force}) async {
    try {
      await _ensureLoaded();
      final previous = <String, KbDoc>{for (final doc in _docs) doc.path: doc};
      final root = Directory(rootDir);
      if (!await root.exists()) await root.create(recursive: true);
      // 自己递归而不是 list(recursive: true)，这样隐藏目录能整棵剪掉，
      // 不会为了索引而遍历 .index 或用户自己的 .git/.thumbnails。
      final (files, scannedSkipped) = await _scan(root, '');
      var skipped = scannedSkipped;
      files.sort((a, b) => a.path.compareTo(b.path));
      final docs = <KbDoc>[];
      for (final file in files) {
        try {
          final rel = _relFromRoot(file.path);
          if (rel == null) continue;
          final stat = await file.stat();
          final old = force ? null : previous[rel];
          if (old != null && old.bytes == stat.size && old.mtimeMs == stat.modified.millisecondsSinceEpoch) {
            docs.add(old);
            continue;
          }
          final bytes = await file.readAsBytes();
          final raw = _rawText(_extensionOf(_basename(rel)), bytes);
          if (raw == null) {
            skipped += 1;
            continue;
          }
          docs.add(
            KbDoc(
              path: rel,
              bytes: bytes.length,
              mtimeMs: stat.modified.millisecondsSinceEpoch,
              sha1: sha1.convert(bytes).toString(),
              chunks: _chunk(_clean(raw)),
            ),
          );
        } catch (_) {
          // 单个文件（加密 docx、读到一半被删）失败就跳过，不让整次构建归零。
          skipped += 1;
        }
      }
      final builtAt = DateTime.now().millisecondsSinceEpoch;
      if (await _writeIndex(builtAt, skipped, docs)) {
        _docs = List<KbDoc>.unmodifiable(docs);
        _builtAtMs = builtAt;
        _skippedFiles = skipped;
      }
      return _currentStats();
    } catch (_) {
      return _currentStats();
    }
  }

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    try {
      await _load();
    } catch (_) {
      _loaded = true;
    }
  }

  Future<void> _load() async {
    try {
      final file = File(_indexPath);
      if (await file.exists()) _applyIndex(await file.readAsString());
    } catch (_) {
      _reset();
    } finally {
      _loaded = true;
    }
  }

  // readChunkText 是同步 API（界面在 build 里直接用），所以保留一条同步读取路径；
  // 正常流程里 search/stats 已经先异步加载过，这里通常只命中缓存。
  void _loadSync() {
    if (_loaded) return;
    try {
      final file = File(_indexPath);
      if (file.existsSync()) _applyIndex(file.readAsStringSync());
    } catch (_) {
      _reset();
    } finally {
      _loaded = true;
    }
  }

  void _applyIndex(String raw) {
    _reset();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      if (_asInt(decoded['version']) != 1) return;
      final rawDocs = decoded['docs'];
      if (rawDocs is! List) return;
      final docs = <KbDoc>[];
      for (final item in rawDocs) {
        if (item is! Map) continue;
        final doc = KbDoc.fromJson(Map<String, Object?>.from(item));
        if (doc.path.isEmpty) continue;
        docs.add(doc);
      }
      docs.sort((a, b) => a.path.compareTo(b.path));
      _docs = List<KbDoc>.unmodifiable(docs);
      _builtAtMs = _asInt(decoded['builtAt']);
      _skippedFiles = _asInt(decoded['skippedFiles']);
    } catch (_) {
      // 坏 JSON、字段类型不对都当空索引：下一条 refresh 会重建，没必要让界面崩。
      _reset();
    }
  }

  void _reset() {
    _docs = const <KbDoc>[];
    _builtAtMs = 0;
    _skippedFiles = 0;
  }

  Future<bool> _writeIndex(int builtAt, int skipped, List<KbDoc> docs) async {
    final tmpPath = '$_indexPath.tmp';
    try {
      await Directory(indexDir).create(recursive: true);
      final payload = jsonEncode(<String, Object?>{
        'version': 1,
        'builtAt': builtAt,
        'skippedFiles': skipped,
        'docs': <Object?>[for (final doc in docs) doc.toJson()],
      });
      final tmp = File(tmpPath);
      await tmp.writeAsString(payload, flush: true);
      try {
        await tmp.rename(_indexPath);
      } catch (_) {
        // 个别 Android 文件系统不允许 rename 覆盖旧文件：先删旧文件再改名。
        final target = File(_indexPath);
        if (await target.exists()) await target.delete();
        await tmp.rename(_indexPath);
      }
      return true;
    } catch (_) {
      return false;
    } finally {
      try {
        final tmp = File(tmpPath);
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {
        // 临时文件删不掉不影响已落盘的索引。
      }
    }
  }

  KbStats _currentStats() {
    var bytes = 0;
    var chunks = 0;
    for (final doc in _docs) {
      bytes += doc.bytes;
      chunks += doc.chunks.length;
    }
    return KbStats(
      docs: _docs.length,
      chunks: chunks,
      totalBytes: bytes,
      builtAtMs: _builtAtMs,
      skippedFiles: _skippedFiles,
    );
  }

  String? _rawText(String ext, List<int> bytes) => switch (ext) {
    'docx' => _docxText(bytes),
    'html' || 'htm' => html_parser.parse(utf8.decode(bytes, allowMalformed: true)).body?.text ?? '',
    'txt' || 'md' || 'markdown' || 'csv' || 'json' => utf8.decode(bytes, allowMalformed: true),
    _ => null,
  };

  String _docxText(List<int> bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final entry = archive.findFile('word/document.xml');
    // 不是合法 docx（或只是改了扩展名）时让单文件解析失败，交给上层计入 skipped，
    // 而不是留下一个 0 块的“空文档”污染列表。
    if (entry == null) throw const FormatException('docx missing word/document.xml');
    final xml = utf8.decode(entry.content, allowMalformed: true);
    // 先把段落结束变成换行，再去标签；否则所有段落会粘成一行，切块时找不到边界。
    final spaced = xml.replaceAll(_paragraphEnd, '\n').replaceAll(_lineBreak, '\n').replaceAll(_tab, ' ');
    return _decodeEntities(spaced.replaceAll(_xmlTag, ''));
  }

  String _decodeEntities(String input) {
    return input.replaceAllMapped(_entity, (match) {
      final body = match.group(1) ?? '';
      switch (body) {
        case 'amp':
          return '&';
        case 'lt':
          return '<';
        case 'gt':
          return '>';
        case 'quot':
          return '"';
        case 'apos':
          return "'";
      }
      final code = body.startsWith('#x') ? int.tryParse(body.substring(2), radix: 16) : int.tryParse(body.substring(1));
      if (code == null || code < 0 || code > 0x10FFFF) return match.group(0) ?? '';
      return String.fromCharCode(code);
    });
  }

  // 每行独立 trim + 连续空白压成一个空格，空行直接丢掉：块文本给检索和模型看，
  // 保留原始缩进只会浪费 token。
  String _clean(String raw) {
    final lines = <String>[];
    for (final line in raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n')) {
      final collapsed = line.replaceAll(_whitespace, ' ').trim();
      if (collapsed.isNotEmpty) lines.add(collapsed);
    }
    return lines.join('\n');
  }

  List<KbChunk> _chunk(String text) {
    final chunks = <KbChunk>[];
    var start = 0;
    while (start < text.length) {
      // 重叠可能把起点落在 emoji 的代理对中间，往后挪一格，别把字符劈开。
      if (start > 0 && _isLowSurrogate(text.codeUnitAt(start))) start += 1;
      final hardEnd = start + _chunkSize < text.length ? start + _chunkSize : text.length;
      var end = hardEnd;
      if (hardEnd < text.length) {
        // 只在前 60% 之后找断点；找到就把断点包含进本块，下一块从 100 字重叠开始。
        final cut = _lastBreak(text, start + _minChunkSize, hardEnd);
        if (cut > start) end = cut;
      }
      if (end > start && end < text.length && _isHighSurrogate(text.codeUnitAt(end - 1))) end -= 1;
      final rawBody = text.substring(start, end);
      final leading = rawBody.length - rawBody.trimLeft().length;
      final body = rawBody.trim();
      var chunkEnd = end;
      // start 记的是 trim 后正文的位置，这样调用方能拿它回原文对齐；重叠也按
      // 正文末尾算，避免把尾部换行算进 100 字里导致实际只重叠 99 字。
      if (body.isNotEmpty) {
        chunks.add(KbChunk(index: chunks.length, start: start + leading, text: body));
        chunkEnd = start + leading + body.length;
      }
      if (end >= text.length) break;
      final next = chunkEnd - _chunkOverlap;
      start = next > start ? next : start + 1;
    }
    return chunks;
  }

  // 返回断点后一位；找不到返回 -1（调用方硬切）。换行和句末标点优先，分号次之。
  int _lastBreak(String text, int floor, int ceiling) {
    for (var i = ceiling - 1; i >= floor; i--) {
      final unit = text.codeUnitAt(i);
      if (unit == 0x0A ||
          unit == 0x3002 ||
          unit == 0xFF01 ||
          unit == 0xFF1F ||
          unit == 0x2E ||
          unit == 0x21 ||
          unit == 0x3F ||
          unit == 0x3B ||
          unit == 0xFF1B) {
        return i + 1;
      }
    }
    return -1;
  }

  Set<String> _queryTerms(String query) {
    final terms = <String>{};
    for (final raw in query.toLowerCase().split(_whitespace)) {
      final token = raw.replaceAll(_edgePunctuation, '');
      if (token.isEmpty) continue;
      terms.add(token);
      if (!_cjk.hasMatch(token)) continue;
      // 中文没有空格：整串之外再补 bigram，“知识库”也能命中“知识”“识库”。
      for (final match in _cjkRun.allMatches(token)) {
        final run = match.group(0) ?? '';
        if (run.length == 1) {
          terms.add(run);
          continue;
        }
        for (var i = 0; i + 1 < run.length; i++) {
          terms.add(run.substring(i, i + 2));
        }
      }
    }
    return terms;
  }

  int _countOccurrences(String text, String term) {
    if (term.isEmpty) return 0;
    var count = 0;
    var at = text.indexOf(term);
    while (at >= 0) {
      count += 1;
      at = text.indexOf(term, at + term.length);
    }
    return count;
  }

  // 按 code unit 截断，但要避免把代理对切成半个字符（emoji 在知识库里也会出现）。
  String _clip(String text, int limit) {
    if (text.length <= limit) return text;
    var end = limit;
    if (end > 0 && _isHighSurrogate(text.codeUnitAt(end - 1))) end -= 1;
    return text.substring(0, end);
  }

  String _snippet(String text, int at, int length) {
    var start = at - _snippetRadius;
    if (start < 0) start = 0;
    var end = at + length + _snippetRadius;
    if (end > text.length) end = text.length;
    if (start > 0 && _isLowSurrogate(text.codeUnitAt(start))) start -= 1;
    if (end < text.length && _isHighSurrogate(text.codeUnitAt(end - 1))) end += 1;
    final body = text.substring(start, end);
    return '${start > 0 ? '…' : ''}$body${end < text.length ? '…' : ''}';
  }

  bool _isHighSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;

  bool _isLowSurrogate(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;

  // ── 网页入库 ────────────────────────────────────────────────────────────

  String? _normalizeUrl(String url) {
    var raw = url.trim();
    if (raw.isEmpty) return null;
    if (!raw.contains('://')) raw = 'https://$raw';
    final uri = Uri.tryParse(raw);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) return null;
    return uri.removeFragment().toString();
  }

  /// `网页/example.com/标题.md`，重名就加 (1)；同名 URL 由调用方复用旧路径。
  String _newWebPath(String url, String? title) {
    final uri = Uri.parse(url);
    final host = _safeSegment(uri.host.isEmpty ? 'unknown' : uri.host);
    final rawName = (title ?? '').trim().isNotEmpty
        ? title!.trim()
        : (uri.pathSegments.isEmpty ? 'index' : uri.pathSegments.last);
    var stem = _safeSegment(rawName);
    stem = stem.replaceFirst(RegExp(r'\.(html?|php|aspx?|jsp|shtml)$', caseSensitive: false), '');
    if (stem.isEmpty) stem = 'page';
    if (stem.length > 60) stem = stem.substring(0, 60);
    final taken = _webFiles.values.toSet();
    var candidate = '$webDirName/$host/$stem.md';
    var n = 1;
    while (taken.contains(candidate) || File('$rootDir/$candidate').existsSync()) {
      candidate = '$webDirName/$host/$stem ($n).md';
      n += 1;
      if (n > 200) {
        candidate = '$webDirName/$host/$stem-${DateTime.now().millisecondsSinceEpoch}.md';
        break;
      }
    }
    return candidate;
  }

  /// 文件名里不能出现的字符换成空格：Android 上 `:`、`?` 会让写入直接失败。
  String _safeSegment(String raw) {
    final cleaned = raw.replaceAll(RegExp(r'[\\/:*?"<>|\r\n\t]'), ' ').replaceAll(_whitespace, ' ').trim();
    return cleaned.replaceFirst(RegExp(r'^\.+'), '').trim();
  }

  /// 文件头带来源 URL 和抓取时间，用户打开文件就知道这段文字是哪来的。
  String _webDocText(String url, String? title, String body, DateTime at) {
    final heading = (title ?? '').replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
    final head = '---\nurl: $url\ntitle: $heading\nfetched: ${at.toIso8601String()}\n---\n\n';
    return '$head${heading.isEmpty ? '' : '# $heading\n\n'}$body\n';
  }

  Future<void> _ensureWebLoaded() async {
    if (_webLoaded) return;
    _webLoaded = true;
    try {
      final file = File(_webMapPath);
      if (!await file.exists()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return;
      final files = decoded['files'];
      final hashes = decoded['hashes'];
      if (files is Map) {
        _webFiles = <String, String>{for (final entry in files.entries) '${entry.key}': '${entry.value}'};
      }
      if (hashes is Map) {
        _webHashes = <String, String>{for (final entry in hashes.entries) '${entry.key}': '${entry.value}'};
      }
    } catch (_) {
      // 坏 JSON 只丢增量线索：下次抓取会把页面重写一遍，内容不会丢。
      _webFiles = <String, String>{};
      _webHashes = <String, String>{};
    }
  }

  Future<void> _saveWebMap() async {
    final tmpPath = '$_webMapPath.tmp';
    try {
      await Directory(indexDir).create(recursive: true);
      final tmp = File(tmpPath);
      await tmp.writeAsString(
        jsonEncode(<String, Object?>{'version': 1, 'files': _webFiles, 'hashes': _webHashes}),
        flush: true,
      );
      try {
        await tmp.rename(_webMapPath);
      } catch (_) {
        final target = File(_webMapPath);
        if (await target.exists()) await target.delete();
        await tmp.rename(_webMapPath);
      }
    } catch (_) {
      // 写不了 web.json 只是下次重复抓同一页，比丢正文轻。
    }
  }

  String? _relFromRoot(String path) {
    final normalized = _normalizePath(path);
    if (!normalized.startsWith('$rootDir/')) return null;
    return normalized.substring(rootDir.length + 1);
  }

  // docs()/search() 给出的是相对路径，但调用方也可能传绝对路径，这里统一收口。
  String? _relKey(String docPath) {
    if (docPath.split(RegExp(r'[\\/]')).contains('..')) return null;
    final normalized = _normalizePath(docPath);
    if (normalized.startsWith('$rootDir/')) return normalized.substring(rootDir.length + 1);
    if (normalized.startsWith('/')) return null;
    return normalized.isEmpty ? null : normalized;
  }

  String _uniqueName(String fileName) {
    final dot = fileName.lastIndexOf('.');
    final stem = dot > 0 ? fileName.substring(0, dot) : fileName;
    final ext = dot > 0 ? fileName.substring(dot) : '';
    var candidate = fileName;
    var n = 1;
    while (File('$rootDir/$candidate').existsSync()) {
      candidate = '$stem ($n)$ext';
      n += 1;
      if (n > 1000) break;
    }
    return candidate;
  }
}

int _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}

String _basename(String path) {
  final normalized = path.replaceAll('\\', '/');
  final slash = normalized.lastIndexOf('/');
  return slash >= 0 ? normalized.substring(slash + 1) : normalized;
}

String _extensionOf(String fileName) {
  final dot = fileName.lastIndexOf('.');
  if (dot <= 0 || dot == fileName.length - 1) return '';
  return fileName.substring(dot + 1).toLowerCase();
}

String _normalizePath(String path) {
  final raw = path.trim().replaceAll('\\', '/');
  final absolute = raw.startsWith('/');
  final parts = <String>[];
  for (final segment in raw.split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      if (parts.isNotEmpty) parts.removeLast();
      continue;
    }
    parts.add(segment);
  }
  final joined = parts.join('/');
  return absolute ? '/$joined' : joined;
}
