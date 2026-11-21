import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'book_import_limits.dart';
import 'local_book_archive.dart';
import 'local_document_input.dart';

/// Upper bound for a single illustration read from an imported EPUB archive.
/// Raised from 8 MiB to 24 MiB to accommodate high-resolution spreads in
/// GB-scale EPUBs while still bounding per-image memory allocation.
const int maxLocalEpubImageBytes = 24 * 1024 * 1024;

/// A damaged/missing image does not discard the other images read under the
/// same original-file lease. Failures remain retryable by the caller.
class LocalBookImageResult {
  const LocalBookImageResult.success(this.bytes) : error = null;
  const LocalBookImageResult.failure(this.error) : bytes = null;

  final Uint8List? bytes;
  final String? error;
}

/// Persistent background worker isolate that keeps an LRU pool of open
/// [RandomAccessFile] handles and parsed ZIP central-directory indices so
/// GB-scale EPUBs with thousands of images do not reopen and re-scan the
/// entire archive on every cold batch.
class LocalEpubMediaWorker {
  LocalEpubMediaWorker._();

  static final LocalEpubMediaWorker shared = LocalEpubMediaWorker._();

  static const int _maxOpenBooks = 2;
  static const Duration _idleCloseTimeout = Duration(seconds: 30);

  Isolate? _isolate;
  SendPort? _sendPort;
  ReceivePort? _receivePort;
  Future<SendPort>? _starting;
  int _nextRequestId = 0;
  final Map<int, Completer<Map<String, LocalBookImageResult>>> _inflight = {};
final Map<int, Completer<Map<String, ({int width, int height})>>> _sizeInflight = {};
  Future<SendPort> _ensureStarted() {
    if (_sendPort case final port?) return Future.value(port);
    return _starting ??= _start();
  }

  Future<SendPort> _start() async {
    final ready = Completer<SendPort>();
    final receivePort = ReceivePort();
    _receivePort = receivePort;

    receivePort.listen((dynamic message) {
      if (message is SendPort) {
        _sendPort = message;
        if (!ready.isCompleted) ready.complete(message);
        return;
      }
      if (message is Map) {
        final id = message['id'] as int?;
        if (id == null) return;
        if (message['kind'] == 'sizes') {
          final sizeCompleter = _sizeInflight.remove(id);
          if (sizeCompleter == null || sizeCompleter.isCompleted) return;
          final rawSizes = message['sizes'] as Map? ?? const {};
          final parsed = <String, ({int width, int height})>{};
          for (final entry in rawSizes.entries) {
            final name = entry.key as String;
            final pair = entry.value;
            if (pair is List && pair.length == 2) {
              parsed[name] = (width: pair[0] as int, height: pair[1] as int);
            }
          }
          sizeCompleter.complete(parsed);
          return;
        }
        final completer = _inflight.remove(id);
        if (completer == null || completer.isCompleted) return;
        final fatal = message['fatal'] as String?;
        if (fatal != null) {
          completer.completeError(FormatException(fatal));
          return;
        }
        final rawItems = message['items'] as Map? ?? const {};
        final decoded = <String, LocalBookImageResult>{};
        for (final entry in rawItems.entries) {
          final name = entry.key as String;
          final payload = entry.value;
          if (payload is TransferableTypedData) {
            decoded[name] = LocalBookImageResult.success(
              payload.materialize().asUint8List(),
            );
          } else if (payload is Uint8List) {
            decoded[name] = LocalBookImageResult.success(payload);
          } else if (payload is String) {
            decoded[name] = LocalBookImageResult.failure(payload);
          } else {
            decoded[name] = const LocalBookImageResult.failure('原书插图无法读取');
          }
        }
        completer.complete(decoded);
      }
    });

    try {
      _isolate = await Isolate.spawn(
        _workerEntryPoint,
        receivePort.sendPort,
        debugName: 'LocalEpubMediaWorker',
      );
      return await ready.future;
    } catch (error) {
      receivePort.close();
      _receivePort = null;
      _starting = null;
      rethrow;
    }
  }

  /// Reads up to four cold images for [directory] using the persistent worker,
  /// returning zero-copy [TransferableTypedData]-materialized bytes.
  Future<Map<String, LocalBookImageResult>> readImages(
    String directory,
    List<String> names,
  ) async {
    if (names.isEmpty) return {};
    final port = await _ensureStarted();
    final id = ++_nextRequestId;
    final completer = Completer<Map<String, LocalBookImageResult>>();
    _inflight[id] = completer;
    port.send(<String, Object?>{
      'op': 'read',
      'id': id,
      'directory': directory,
      'names': names,
    });
    return completer.future;
  }

  /// Reads a single cold image for [directory] via the persistent worker.
  Future<Uint8List> readImage(String directory, String name) async {
    final batch = await readImages(directory, [name]);
    final result = batch[name];
    if (result?.bytes case final bytes?) return bytes;
    throw FormatException(result?.error ?? '原书插图无法读取');
  }

  /// Probes width/height for a batch of local images in a single worker round
  /// trip using header-only reads, avoiding full-image I/O during pagination.
  Future<Map<String, ({int width, int height})>> probeImageSizes(
    String directory,
    List<String> names,
  ) async {
    if (names.isEmpty) return {};
    final port = await _ensureStarted();
    final id = ++_nextRequestId;
    final completer = Completer<Map<String, ({int width, int height})>>();
    _sizeInflight[id] = completer;
    port.send(<String, Object?>{
      'op': 'probe_sizes',
      'id': id,
      'directory': directory,
      'names': names,
    });
    return completer.future;
  }

  /// Closes the cached [RandomAccessFile] and index for [directory] immediately.
  void evictDirectory(String directory) {
    _sendPort?.send(<String, Object?>{
      'op': 'evict',
      'directory': directory,
    });
  }

  /// Closes all cached book handles inside the worker (e.g. on library reload).
  void evictAll() {
    _sendPort?.send(const <String, Object?>{'op': 'evict_all'});
  }

  /// Shuts down the background worker isolate and releases its ports.
  void dispose() {
    evictAll();
    _receivePort?.close();
    _receivePort = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _sendPort = null;
    _starting = null;
    for (final completer in _inflight.values) {
      if (!completer.isCompleted) {
        completer.completeError(const FormatException('本地插图读取已中止'));
      }
    }
    _inflight.clear();
    for (final completer in _sizeInflight.values) {
      if (!completer.isCompleted) {
        completer.complete(const {});
      }
    }
    _sizeInflight.clear();
  }

  static void _workerEntryPoint(SendPort mainPort) {
    final inbox = ReceivePort();
    mainPort.send(inbox.sendPort);

    final sessions = <String, _WorkerBookSession>{};
    Timer? idleTimer;

    void closeSession(String directory) {
      sessions.remove(directory)?.close();
    }

    void touchSession(String directory, _WorkerBookSession session) {
      sessions.remove(directory);
      sessions[directory] = session;
      while (sessions.length > _maxOpenBooks) {
        final oldest = sessions.keys.first;
        sessions.remove(oldest)?.close();
      }
    }

    void rescheduleIdleSweep() {
      idleTimer?.cancel();
      if (sessions.isEmpty) return;
      idleTimer = Timer(_idleCloseTimeout, () {
        final now = DateTime.now();
        final stale = sessions.entries
            .where((e) => now.difference(e.value.lastUsed) >= _idleCloseTimeout)
            .map((e) => e.key)
            .toList();
        for (final key in stale) {
          closeSession(key);
        }
        if (sessions.isNotEmpty) rescheduleIdleSweep();
      });
    }

    inbox.listen((dynamic message) {
      if (message is! Map) return;
      final op = message['op'] as String?;
      if (op == 'evict') {
        final directory = message['directory'] as String?;
        if (directory != null) closeSession(directory);
        return;
      }
      if (op == 'evict_all') {
        for (final session in sessions.values) {
          session.close();
        }
        sessions.clear();
        idleTimer?.cancel();
        return;
      }
      if (op == 'probe_sizes') {
        final id = message['id'] as int;
        final directory = message['directory'] as String;
        final names = (message['names'] as List).cast<String>();
        final sizes = <String, List<int>>{};
        final archived = <String>[];
        for (final name in names) {
          final file = File('$directory/$name');
          if (file.existsSync()) {
            final dims = _probeLocalFileHeader(file);
            if (dims != null) {
              sizes[name] = [dims.width, dims.height];
            }
          } else {
            archived.add(name);
          }
        }
        if (archived.isNotEmpty) {
          try {
            final session = _openOrReuseSession(sessions, directory);
            touchSession(directory, session);
            session.lastUsed = DateTime.now();
            rescheduleIdleSweep();
            sizes.addAll(session.probeSizes(archived));
          } catch (_) {
            closeSession(directory);
          }
        }
        mainPort.send(<String, Object?>{
          'id': id,
          'kind': 'sizes',
          'sizes': sizes,
        });
        return;
      }
      if (op != 'read') return;

      final id = message['id'] as int;
      final directory = message['directory'] as String;
      final names = (message['names'] as List).cast<String>();

      try {
        final session = _openOrReuseSession(sessions, directory);
        touchSession(directory, session);
        session.lastUsed = DateTime.now();
        rescheduleIdleSweep();

        final items = session.readBatch(names);
        mainPort.send(<String, Object?>{
          'id': id,
          'items': items,
        });
      } on FormatException catch (error) {
        closeSession(directory);
        mainPort.send(<String, Object?>{
          'id': id,
          'fatal': error.message,
        });
      } catch (_) {
        closeSession(directory);
        mainPort.send(<String, Object?>{
          'id': id,
          'fatal': '原书插图无法读取，请重新导入完整原书',
        });
      }
    });
  }

  static _WorkerBookSession _openOrReuseSession(
    Map<String, _WorkerBookSession> sessions,
    String directory,
  ) {
    final existing = sessions[directory];
    if (existing != null && existing.isFresh()) {
      return existing;
    }
    existing?.close();
    sessions.remove(directory);
    return _WorkerBookSession.open(directory);
  }
}

class _WorkerBookSession {
  _WorkerBookSession._({
    required this.directory,
    required this.indexModifiedMs,
    required this.originalModifiedMs,
    required this.originalLength,
    required this.recoverDamagedEpub,
    required this.mediaEntries,
    required this.raf,
    required this.zipIndex,
  }) : lastUsed = DateTime.now();

  final String directory;
  final int indexModifiedMs;
  final int originalModifiedMs;
  final int originalLength;
  final bool recoverDamagedEpub;
  final Map<String, String> mediaEntries;
  final RandomAccessFile? raf;
  final Map<String, LocalBookZipEntryIndex>? zipIndex;
  DateTime lastUsed;

  static _WorkerBookSession open(String directory) {
    final indexFile = File('$directory/media.json');
    final indexStat = indexFile.statSync();
    if (indexStat.type == FileSystemEntityType.notFound) {
      throw const FormatException('本地插图索引无效');
    }
    if (indexStat.size > 4 * 1024 * 1024) {
      throw const FormatException('本地插图索引过大');
    }
    final decoded = jsonDecode(indexFile.readAsStringSync());
    if (decoded is! Map ||
        decoded['version'] != 1 ||
        decoded['entries'] is! Map) {
      throw const FormatException('本地插图索引无效');
    }
    final rawEntries = decoded['entries'] as Map;
    final mediaEntries = <String, String>{};
    for (final entry in rawEntries.entries) {
      if (entry.key is String && entry.value is String) {
        mediaEntries[entry.key as String] = entry.value as String;
      }
    }
    final recover = decoded['recoverDamagedEpub'] == true;
    final originalFile = File('$directory/original');
    final originalStat = originalFile.statSync();
    if (originalStat.type == FileSystemEntityType.notFound) {
      throw const FormatException('原书插图无法读取，请重新导入完整原书');
    }

    RandomAccessFile? raf;
    Map<String, LocalBookZipEntryIndex>? zipIndex;
    if (!recover) {
      raf = originalFile.openSync(mode: FileMode.read);
      try {
        zipIndex = indexLocalBookArchiveEntries(raf);
      } catch (_) {
        raf.closeSync();
        rethrow;
      }
    }

    return _WorkerBookSession._(
      directory: directory,
      indexModifiedMs: indexStat.modified.millisecondsSinceEpoch,
      originalModifiedMs: originalStat.modified.millisecondsSinceEpoch,
      originalLength: originalStat.size,
      recoverDamagedEpub: recover,
      mediaEntries: mediaEntries,
      raf: raf,
      zipIndex: zipIndex,
    );
  }

  bool isFresh() {
    final indexStat = File('$directory/media.json').statSync();
    final originalStat = File('$directory/original').statSync();
    return indexStat.modified.millisecondsSinceEpoch == indexModifiedMs &&
        originalStat.modified.millisecondsSinceEpoch == originalModifiedMs &&
        originalStat.size == originalLength;
  }

  Map<String, Object> readBatch(List<String> names) {
    if (recoverDamagedEpub || raf == null || zipIndex == null) {
      final fallback = readLocalEpubImagesFromInput((
        directory: directory,
        names: names,
        original: LocalDocumentInput.file('$directory/original'),
      ));
      return {
        for (final entry in fallback.entries)
          entry.key: entry.value.bytes != null
              ? TransferableTypedData.fromList([entry.value.bytes!])
              : (entry.value.error ?? '原书插图无法读取'),
      };
    }

    final items = <String, Object>{};
    final fallbackNames = <String>[];
    for (final name in names) {
      final path = mediaEntries[name];
      if (path == null) {
        items[name] = '原书中没有这张插图';
        continue;
      }
      final zipEntry = zipIndex![path];
      if (zipEntry == null ||
          zipEntry.isDirectory ||
          zipEntry.uncompressedSize > maxLocalEpubImageBytes) {
        items[name] = '原书插图无效或超过 ${maxLocalEpubImageBytes ~/ (1024 * 1024)} MiB';
        continue;
      }
      try {
        final bytes = readIndexedLocalBookEntry(
          raf!,
          zipEntry,
          verifyCrc: false,
          maxEntryBytes: maxLocalEpubImageBytes,
        );
        items[name] = TransferableTypedData.fromList([bytes]);
      } on UnsupportedError {
        fallbackNames.add(name);
      } on FormatException {
        items[name] = '原书插图无法读取，请重新导入完整原书';
      } on FileSystemException {
        items[name] = '原书插图无法读取，请重新导入完整原书';
      }
    }

    if (fallbackNames.isNotEmpty) {
      final fallback = readLocalEpubImagesFromInput((
        directory: directory,
        names: fallbackNames,
        original: LocalDocumentInput.file('$directory/original'),
      ));
      for (final entry in fallback.entries) {
        items[entry.key] = entry.value.bytes != null
            ? TransferableTypedData.fromList([entry.value.bytes!])
            : (entry.value.error ?? '原书插图无法读取');
      }
    }
    return items;
  }

  Map<String, List<int>> probeSizes(List<String> names) {
    final cached = _readCachedMediaSizes(directory, indexModifiedMs);
    final result = <String, List<int>>{};
    final missing = <String>[];
    for (final name in names) {
      final hit = cached[name];
      if (hit != null) {
        result[name] = hit;
      } else {
        missing.add(name);
      }
    }
    if (missing.isEmpty || recoverDamagedEpub || raf == null || zipIndex == null) {
      return result;
    }
    var dirty = false;
    for (final name in missing) {
      final path = mediaEntries[name];
      if (path == null) continue;
      final zipEntry = zipIndex![path];
      if (zipEntry == null) continue;
      try {
        final dims = probeIndexedLocalBookImageSize(
          raf!,
          zipEntry,
          maxEntryBytes: maxLocalEpubImageBytes,
        );
        if (dims != null) {
          final pair = [dims.width, dims.height];
          result[name] = pair;
          cached[name] = pair;
          dirty = true;
        }
      } catch (_) {
        // Leave unprobed so caller can fall back to full decoding if needed.
      }
    }
    if (dirty) {
      _writeCachedMediaSizes(directory, indexModifiedMs, cached);
    }
    return result;
  }

  void close() {
    try {
      raf?.closeSync();
    } catch (_) {
      // Ignore close errors during session eviction.
    }
  }
}

/// Runs off the UI isolate. The index points only into this book's retained
/// original, never to external paths or remote resources.
Uint8List readLocalEpubImage(({String directory, String name}) request) {
  return readLocalEpubImageFromFile((
    directory: request.directory,
    name: request.name,
    original: '${request.directory}/original',
  ));
}

Uint8List readLocalEpubImageFromFile(
  ({String directory, String name, String original}) request,
) => readLocalEpubImageFromInput((
  directory: request.directory,
  name: request.name,
  original: LocalDocumentInput.file(request.original),
));

Uint8List readLocalEpubImageFromInput(
  ({String directory, String name, LocalDocumentInput original}) request,
) {
  final result = readLocalEpubImagesFromInput((
    directory: request.directory,
    names: [request.name],
    original: request.original,
  ))[request.name]!;
  if (result.bytes case final bytes?) return bytes;
  throw FormatException(result.error ?? '原书插图无法读取');
}

/// Reads at most four cold images with one index read and archive open. Owned
/// encoded bytes leave the worker before the input mapping/lease is released.
Map<String, LocalBookImageResult> readLocalEpubImagesFromInput(
  ({String directory, List<String> names, LocalDocumentInput original}) request,
) {
  if (request.names.isEmpty) return {};
  if (request.names.length > 4) {
    throw const FormatException('本地插图批次过大');
  }
  final index = File('${request.directory}/media.json');
  if (index.lengthSync() > 4 * 1024 * 1024) {
    throw const FormatException('本地插图索引过大');
  }
  final value = jsonDecode(index.readAsStringSync());
  if (value is! Map || value['version'] != 1 || value['entries'] is! Map) {
    throw const FormatException('本地插图索引无效');
  }
  final entries = value['entries'] as Map;
  final results = <String, LocalBookImageResult>{};
  final paths = <String, String>{};
  for (final name in request.names) {
    final path = entries[name];
    if (path is String) {
      paths[name] = path;
    } else {
      results[name] = const LocalBookImageResult.failure('原书中没有这张插图');
    }
  }
  if (paths.isEmpty) return results;
  final buffer = request.original.open();
  try {
    final recover = value['recoverDamagedEpub'] == true;
    final fallbackPaths = <String, String>{};
    if (!recover) {
      final zipIndex = indexLocalBookArchiveFromStream(buffer.stream);
      for (final entry in paths.entries) {
        final name = entry.key, path = entry.value;
        final zipEntry = zipIndex[path];
        if (zipEntry == null ||
            zipEntry.isDirectory ||
            zipEntry.uncompressedSize > maxLocalEpubImageBytes) {
          results[name] = LocalBookImageResult.failure(
            '原书插图无效或超过 ${maxLocalEpubImageBytes ~/ (1024 * 1024)} MiB',
          );
          continue;
        }
        try {
          final bytes = readIndexedLocalBookEntryFromStream(
            buffer.stream,
            zipEntry,
            verifyCrc: false,
            maxEntryBytes: maxLocalEpubImageBytes,
          );
          results[name] = LocalBookImageResult.success(bytes);
        } on UnsupportedError {
          fallbackPaths[name] = path;
        } on FormatException {
          results[name] = const LocalBookImageResult.failure(
            '原书插图无法读取，请重新导入完整原书',
          );
        }
      }
    } else {
      fallbackPaths.addAll(paths);
    }
    if (fallbackPaths.isNotEmpty) {
      buffer.stream.setPosition(0);
      final archive = recover
          ? readLocalBookArchiveForRecovery(
              buffer.stream,
              maxSize: maxExpandedLocalEpubBytes,
              allowLargeMedia: true,
            ).archive
          : readLocalBookArchive(
              buffer.stream,
              maxSize: maxExpandedLocalEpubBytes,
              allowLargeMedia: true,
            );
      for (final entry in fallbackPaths.entries) {
        final name = entry.key, path = entry.value;
        try {
          final image = archive.findFile(path);
          if (image == null ||
              !image.isFile ||
              image.size > maxLocalEpubImageBytes) {
            results[name] = LocalBookImageResult.failure(
              '原书插图无效或超过 ${maxLocalEpubImageBytes ~/ (1024 * 1024)} MiB',
            );
            continue;
          }
          final bytes = readLocalBookArchiveEntry(image, verifyCrc: false);
          results[name] = LocalBookImageResult.success(
            Uint8List.fromList(bytes),
          );
        } on ArchiveException {
          results[name] = const LocalBookImageResult.failure(
            '原书插图无法读取，请重新导入完整原书',
          );
        } on FormatException {
          results[name] = const LocalBookImageResult.failure(
            '原书插图无法读取，请重新导入完整原书',
          );
        }
      }
    }
    return results;
  } on ArchiveException {
    throw const FormatException('原书插图无法读取，请重新导入完整原书');
  } finally {
    buffer.close();
  }
}

({int width, int height})? _probeLocalFileHeader(File file) {
  RandomAccessFile? raf;
  try {
    final length = file.lengthSync();
    if (length <= 0 || length > maxLocalEpubImageBytes) return null;
    raf = file.openSync(mode: FileMode.read);
    for (final cap in const [16384, 65536]) {
      final toRead = length < cap ? length : cap;
      raf.setPositionSync(0);
      final slice = raf.readSync(toRead);
      final dims = probeImageDimensionsFromHeader(slice);
      if (dims != null || toRead == length) return dims;
    }
    return null;
  } catch (_) {
    return null;
  } finally {
    try {
      raf?.closeSync();
    } catch (_) {}
  }
}
/// Probes dimensions for an entire chapter's local images from a direct/SAF
/// [LocalDocumentInput] in a single central-directory open, with persistent
/// disk caching in `media_sizes.json`.
Map<String, ({int width, int height})> probeLocalEpubImageSizesFromInput(
  ({String directory, List<String> names, LocalDocumentInput original}) request,
) {
  if (request.names.isEmpty) return {};
  final indexFile = File('${request.directory}/media.json');
  final indexStat = indexFile.statSync();
  if (indexStat.type == FileSystemEntityType.notFound ||
      indexStat.size > 4 * 1024 * 1024) {
    return {};
  }
  final indexModifiedMs = indexStat.modified.millisecondsSinceEpoch;
  final cached = _readCachedMediaSizes(request.directory, indexModifiedMs);
  final result = <String, ({int width, int height})>{};
  final missing = <String>[];
  for (final name in request.names) {
    final hit = cached[name];
    if (hit != null) {
      result[name] = (width: hit[0], height: hit[1]);
    } else {
      missing.add(name);
    }
  }
  if (missing.isEmpty) return result;

  final value = jsonDecode(indexFile.readAsStringSync());
  if (value is! Map ||
      value['version'] != 1 ||
      value['entries'] is! Map ||
      value['recoverDamagedEpub'] == true) {
    return result;
  }
  final entries = value['entries'] as Map;
  final paths = <String, String>{};
  for (final name in missing) {
    final path = entries[name];
    if (path is String) paths[name] = path;
  }
  if (paths.isEmpty) return result;

  final buffer = request.original.open();
  var dirty = false;
  try {
    final zipIndex = indexLocalBookArchiveFromStream(buffer.stream);
    for (final entry in paths.entries) {
      final zipEntry = zipIndex[entry.value];
      if (zipEntry == null) continue;
      try {
        final dims = probeIndexedLocalBookImageSizeFromStream(
          buffer.stream,
          zipEntry,
          maxEntryBytes: maxLocalEpubImageBytes,
        );
        if (dims != null) {
          result[entry.key] = dims;
          cached[entry.key] = [dims.width, dims.height];
          dirty = true;
        }
      } catch (_) {
        // Leave unprobed for caller fallback.
      }
    }
  } catch (_) {
    // Return partial probed results; caller falls back for the rest.
  } finally {
    buffer.close();
  }
  if (dirty) {
    _writeCachedMediaSizes(request.directory, indexModifiedMs, cached);
  }
  return result;
}

Map<String, List<int>> _readCachedMediaSizes(
  String directory,
  int indexModifiedMs,
) {
  final result = <String, List<int>>{};
  try {
    final file = File('$directory/media_sizes.json');
    if (!file.existsSync() || file.lengthSync() > 4 * 1024 * 1024) {
      return result;
    }
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map ||
        decoded['version'] != 1 ||
        decoded['indexModifiedMs'] != indexModifiedMs ||
        decoded['sizes'] is! Map) {
      return result;
    }
    for (final entry in (decoded['sizes'] as Map).entries) {
      final key = entry.key;
      final val = entry.value;
      if (key is String && val is List && val.length == 2) {
        final w = val[0], h = val[1];
        if (w is int && h is int && w > 0 && h > 0) {
          result[key] = [w, h];
        }
      }
    }
  } catch (_) {
    // Corrupted cache is ignored and regenerated lazily.
  }
  return result;
}

void _writeCachedMediaSizes(
  String directory,
  int indexModifiedMs,
  Map<String, List<int>> sizes,
) {
  try {
    final tmp = File('$directory/media_sizes.json.tmp');
    final target = File('$directory/media_sizes.json');
    tmp.writeAsStringSync(
      jsonEncode(<String, Object?>{
        'version': 1,
        'indexModifiedMs': indexModifiedMs,
        'sizes': sizes,
      }),
    );
    tmp.renameSync(target.path);
  } catch (_) {
    // Disk cache write failures are non-fatal.
  }
}
