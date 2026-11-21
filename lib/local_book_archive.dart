import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

class LocalBookArchiveCorruption extends FormatException {
  LocalBookArchiveCorruption(this.path, this.reason)
    : super(path == null ? '压缩文件损坏，请重新下载完整原书' : '压缩文件内容损坏：$path，请重新下载完整原书');
  final String? path;
  final String reason;
}

LocalBookArchiveCorruption _damagedArchive([
  String? path,
  String reason = 'ZIP 文件记录损坏',
]) => LocalBookArchiveCorruption(path, reason);

/// Check a requested entry, without expanding unrelated text or images.
/// [ArchiveFile.readBytes] alone does not verify ZIP CRCs or short output.
Uint8List readLocalBookArchiveEntry(ArchiveFile file, {bool verifyCrc = true}) {
  try {
    final output = OutputMemoryStream();
    file.writeContent(output);
    final bytes = output.getBytes();
    if (bytes.length != file.size) {
      throw _damagedArchive(file.name, '展开后的大小与 ZIP 目录不一致');
    }
    if (verifyCrc && file.crc32 != null && getCrc32(bytes) != file.crc32) {
      throw _damagedArchive(file.name, '内容 CRC 校验不一致');
    }
    return bytes;
  } on LocalBookArchiveCorruption {
    rethrow;
  } on ArchiveException {
    throw _damagedArchive(file.name, '压缩内容无法解码');
  } on FormatException {
    throw _damagedArchive(file.name, '压缩内容无法解码');
  } on RangeError {
    throw _damagedArchive(file.name, '压缩内容不完整');
  }
}

/// Inspect directory limits and local-record structure before decoding entries.
/// File streams keep compressed images on disk until an image is requested.
Archive readLocalBookArchive(
  InputStream input, {
  required int maxSize,
  int maxEntrySize = 40 * 1024 * 1024,
  bool allowLargeMedia = false,
}) {
  if (input.totalLength < 22) {
    throw const FormatException('压缩文件不完整，请重新下载原书');
  }
  final ZipDirectory headers;
  try {
    headers = ZipDirectory()..read(input);
    _checkArchiveStructure(input, headers);
  } on ArchiveException {
    throw _damagedArchive();
  } on RangeError {
    throw _damagedArchive();
  }
  if (headers.fileHeaders.isEmpty) {
    throw const FormatException('压缩包中没有可读取的文件');
  }
  if (headers.fileHeaders.length > 12000) {
    throw const FormatException('压缩包包含过多文件');
  }
  var declared = 0;
  for (final header in headers.fileHeaders) {
    declared += header.uncompressedSize;
    _checkEntryLimits(header, declared, maxSize, maxEntrySize, allowLargeMedia);
  }
  input.setPosition(0);
  final archive = ZipDecoder().decodeStream(input);
  if (archive.length > 12000) throw const FormatException('压缩包包含过多文件');
  var total = 0;
  for (final entry in archive) {
    total += entry.size;
    _checkExpandedSize(total, maxSize);
    if (entry.isSymbolicLink ||
        _entryTooLarge(entry.name, entry.size, maxEntrySize, allowLargeMedia) ||
        _unsupportedPath(entry.name)) {
      throw const FormatException('压缩包大小或路径不受支持');
    }
  }
  return archive;
}

class LocalBookArchiveRecovery {
  const LocalBookArchiveRecovery(this.archive, this.damagedEntries);
  final Archive archive;
  final Map<String, String> damagedEntries;
}

/// Only the explicitly selected recovery import uses this entry point. The
/// central directory must be readable; unsafe paths and size limits still fail.
/// Damaged local records stay in [damagedEntries], never as invented content.
LocalBookArchiveRecovery readLocalBookArchiveForRecovery(
  InputStream input, {
  required int maxSize,
  int maxEntrySize = 40 * 1024 * 1024,
  bool allowLargeMedia = false,
}) {
  final directory = _readRecoveryDirectory(input);
  if (directory.fileHeaders.isEmpty) {
    throw const FormatException('压缩包中没有可读取的文件');
  }
  if (directory.fileHeaders.length > 12000) {
    throw const FormatException('压缩包包含过多文件');
  }
  var declared = 0;
  final names = <String>{};
  for (final header in directory.fileHeaders) {
    declared += header.uncompressedSize;
    _checkEntryLimits(header, declared, maxSize, maxEntrySize, allowLargeMedia);
    if (header.diskNumberStart != 0 || header.generalPurposeBitFlag & 1 != 0) {
      throw const FormatException('不支持分卷或加密 ZIP，请选择未加密的完整原书');
    }
    if (!const {0, 8, 12, 93}.contains(header.compressionMethod)) {
      throw const FormatException('EPUB 使用暂不支持的压缩方式');
    }
    if (!names.add(header.filename)) {
      throw const FormatException('压缩目录包含重复资源，无法安全恢复');
    }
  }
  final archive = Archive();
  final damaged = <String, String>{};
  final sorted = directory.fileHeaders.toList()
    ..sort((a, b) => a.localHeaderOffset.compareTo(b.localHeaderOffset));
  for (var index = 0; index < sorted.length; index++) {
    final header = sorted[index];
    final next = index + 1 < sorted.length
        ? sorted[index + 1].localHeaderOffset
        : directory.centralDirectoryOffset;
    final limit = next.clamp(0, directory.centralDirectoryOffset);
    try {
      _checkArchiveEntryStructure(
        input,
        header,
        limit,
        directory.centralDirectoryOffset,
      );
      final content = ZipFile(header)
        ..read(
          input.subset(
            position: header.localHeaderOffset,
            length: limit - header.localHeaderOffset,
          ),
        );
      final entry = header.filename.endsWith('/')
          ? ArchiveFile.directory(header.filename)
          : ArchiveFile.file(header.filename, header.uncompressedSize, content);
      entry
        ..compression = content.compressionMethod
        ..crc32 = header.crc32
        ..mode = header.externalFileAttributes >> 16
        ..lastModTime =
            header.lastModifiedFileDate << 16 | header.lastModifiedFileTime;
      archive.add(entry);
    } on LocalBookArchiveCorruption catch (error) {
      damaged[header.filename] = error.reason;
    } on ArchiveException {
      damaged[header.filename] = 'ZIP 本地文件记录无法读取';
    } on RangeError {
      damaged[header.filename] = 'ZIP 本地文件记录不完整';
    }
  }
  return LocalBookArchiveRecovery(archive, damaged);
}

void _checkEntryLimits(
  ZipFileHeader header,
  int total,
  int maxSize,
  int maxEntrySize,
  bool allowLargeMedia,
) {
  _checkExpandedSize(total, maxSize);
  if (header.uncompressedSize < 0 ||
      _entryTooLarge(
        header.filename,
        header.uncompressedSize,
        maxEntrySize,
        allowLargeMedia,
      ) ||
      (header.externalFileAttributes >> 16) & 0xf000 == 0xa000) {
    throw const FormatException('压缩包包含不支持的文件或大小超出限制');
  }
  if (_unsupportedPath(header.filename)) {
    throw const FormatException('压缩包大小或路径不受支持');
  }
}

// Audio/video stays in the original archive. The reader never expands it into
// chapter or image memory, while the archive-wide expanded limit still applies.
final _epubMediaPath = RegExp(
  r'\.(mov|mp4|m4v|webm|ogv|mp3|m4a|aac|ogg|oga|wav|flac)$',
  caseSensitive: false,
);

bool _entryTooLarge(String name, int size, int limit, bool allowLargeMedia) =>
    size > limit && !(allowLargeMedia && _epubMediaPath.hasMatch(name));

void _checkExpandedSize(int total, int maxSize) {
  if (total > maxSize) {
    throw FormatException('压缩包展开后合计超过 ${maxSize ~/ (1024 * 1024)} MiB');
  }
}

// ZipDirectory.read eagerly visits local records. Read only its central-header
// metadata here, so one broken local record cannot hide healthy later records.
ZipDirectory _readRecoveryDirectory(InputStream input) {
  try {
    final length = input.totalLength;
    if (length < 22) throw _damagedArchive();
    final tailStart = length > 65557 ? length - 65557 : 0;
    final tail = input.subset(position: tailStart).toUint8List();
    final bytes = ByteData.sublistView(tail);
    var eocd = -1;
    for (var at = tail.length - 22; at >= 0; at--) {
      if (bytes.getUint32(at, Endian.little) == ZipDirectory.eocdSignature &&
          at + 22 + bytes.getUint16(at + 20, Endian.little) == tail.length) {
        eocd = tailStart + at;
        break;
      }
    }
    if (eocd < 0) throw _damagedArchive();
    final end = input.subset(position: eocd, length: 22)..skip(4);
    final directory = ZipDirectory()
      ..filePosition = eocd
      ..numberOfThisDisk = end.readUint16()
      ..diskWithTheStartOfTheCentralDirectory = end.readUint16()
      ..totalCentralDirectoryEntriesOnThisDisk = end.readUint16()
      ..totalCentralDirectoryEntries = end.readUint16()
      ..centralDirectorySize = end.readUint32()
      ..centralDirectoryOffset = end.readUint32();
    if (eocd >= 20) {
      final locator = input.subset(position: eocd - 20, length: 20);
      if (locator.readUint32() == ZipDirectory.zip64EocdLocatorSignature) {
        if (locator.readUint32() != 0) throw _damagedArchive();
        final offset = locator.readUint64();
        if (locator.readUint32() != 1 ||
            offset < 0 ||
            offset + 56 > eocd - 20) {
          throw _damagedArchive();
        }
        final wide = input.subset(position: offset, length: eocd - 20 - offset);
        if (wide.readUint32() != ZipDirectory.zip64EocdSignature ||
            wide.readUint64() < 44) {
          throw _damagedArchive();
        }
        wide.skip(4);
        directory
          ..numberOfThisDisk = wide.readUint32()
          ..diskWithTheStartOfTheCentralDirectory = wide.readUint32()
          ..totalCentralDirectoryEntriesOnThisDisk = wide.readUint64()
          ..totalCentralDirectoryEntries = wide.readUint64()
          ..centralDirectorySize = wide.readUint64()
          ..centralDirectoryOffset = wide.readUint64();
      }
    }
    if (directory.numberOfThisDisk != 0 ||
        directory.diskWithTheStartOfTheCentralDirectory != 0 ||
        directory.totalCentralDirectoryEntriesOnThisDisk !=
            directory.totalCentralDirectoryEntries ||
        directory.totalCentralDirectoryEntries > 12000 ||
        directory.totalCentralDirectoryEntries < 0 ||
        directory.centralDirectoryOffset < 0 ||
        directory.centralDirectorySize < 0 ||
        directory.centralDirectoryOffset + directory.centralDirectorySize >
            eocd) {
      throw _damagedArchive();
    }
    final central = input.subset(
      position: directory.centralDirectoryOffset,
      length: directory.centralDirectorySize,
    );
    for (
      var index = 0;
      index < directory.totalCentralDirectoryEntries;
      index++
    ) {
      if (central.length < 46) throw _damagedArchive();
      final fixed = central.peekBytes(46);
      if (fixed.readUint32() != ZipFileHeader.signature) {
        throw _damagedArchive();
      }
      fixed.skip(24);
      final variable =
          fixed.readUint16() + fixed.readUint16() + fixed.readUint16();
      if (46 + variable > central.length) throw _damagedArchive();
      central.skip(4);
      directory.fileHeaders.add(ZipFileHeader()..read(central));
    }
    if (!central.isEOS) {
      if (central.length < 6 ||
          central.readUint32() != 0x05054b50 ||
          central.readUint16() != central.length) {
        throw _damagedArchive();
      }
    }
    return directory;
  } on ArchiveException {
    throw _damagedArchive();
  } on RangeError {
    throw _damagedArchive();
  }
}

bool _unsupportedPath(String name) =>
    name.startsWith('/') ||
    name.contains('\\') ||
    name.split('/').contains('..');

void _checkArchiveStructure(InputStream input, ZipDirectory directory) {
  final start = directory.centralDirectoryOffset;
  final size = directory.centralDirectorySize;
  if (directory.filePosition < 0 ||
      directory.numberOfThisDisk != 0 ||
      directory.diskWithTheStartOfTheCentralDirectory != 0 ||
      directory.totalCentralDirectoryEntriesOnThisDisk !=
          directory.totalCentralDirectoryEntries ||
      directory.fileHeaders.length != directory.totalCentralDirectoryEntries ||
      start < 0 ||
      size < 0 ||
      start + size > directory.filePosition ||
      directory.filePosition + 22 > input.totalLength) {
    throw _damagedArchive();
  }
  final sorted = directory.fileHeaders.toList()
    ..sort((a, b) => a.localHeaderOffset.compareTo(b.localHeaderOffset));
  for (var index = 0; index < sorted.length; index++) {
    final header = sorted[index];
    final limit = index + 1 < sorted.length
        ? sorted[index + 1].localHeaderOffset
        : start;
    _checkArchiveEntryStructure(input, header, limit, start);
  }
}

void _checkArchiveEntryStructure(
  InputStream input,
  ZipFileHeader header,
  int limit,
  int start,
) {
  final offset = header.localHeaderOffset;
  if (header.diskNumberStart != 0 ||
      offset < 0 ||
      offset + 30 > limit ||
      limit > start ||
      header.compressedSize < 0 ||
      header.uncompressedSize < 0) {
    throw _damagedArchive(header.filename, 'ZIP 本地记录位置或长度无效');
  }
  final local = input.subset(position: offset, length: limit - offset);
  if (local.readUint32() != ZipFile.zipSignature) {
    throw _damagedArchive(header.filename, 'ZIP 本地文件头损坏');
  }
  local.skip(2); // version needed
  final flags = local.readUint16();
  final method = local.readUint16();
  local.skip(4); // modification time and date
  final crc = local.readUint32();
  final compressed = local.readUint32();
  final uncompressed = local.readUint32();
  final nameLength = local.readUint16();
  final extraLength = local.readUint16();
  final dataStart = offset + 30 + nameLength + extraLength;
  final dataEnd = dataStart + header.compressedSize;
  if (flags & 1 != 0) {
    throw const FormatException('不支持加密 ZIP，请选择未加密的完整原书');
  }
  if (dataStart > limit || dataEnd > limit) {
    throw _damagedArchive(header.filename);
  }
  final name = local.readString(size: nameLength);
  if (_unsupportedPath(name)) {
    throw const FormatException('压缩包大小或路径不受支持');
  }
  if (flags != header.generalPurposeBitFlag ||
      method != header.compressionMethod ||
      name != header.filename) {
    throw _damagedArchive(header.filename);
  }
  if (flags & 8 == 0) {
    // Zip64 places real sizes in the extra field, not these 32-bit fields.
    if (crc != header.crc32 ||
        compressed != 0xffffffff && compressed != header.compressedSize ||
        uncompressed != 0xffffffff && uncompressed != header.uncompressedSize) {
      throw _damagedArchive(header.filename);
    }
  } else {
    // Streaming writers put CRC/sizes after the compressed payload. The
    // decoder reads those too; do not let a truncated descriptor read into
    // the next local header or the central directory.
    var zip64 = false;
    final extra = local.readBytes(extraLength);
    while (extra.length >= 4) {
      final id = extra.readUint16();
      final length = extra.readUint16();
      if (length > extra.length) throw _damagedArchive(header.filename);
      if (id == 1) zip64 = true;
      extra.skip(length);
    }
    final descriptor = input.subset(position: dataEnd, length: limit - dataEnd);
    final minimum = zip64 ? 20 : 12;
    if (descriptor.length < minimum) throw _damagedArchive(header.filename);
    final signatureOrCrc = descriptor.readUint32();
    final hasSignature = signatureOrCrc == 0x08074b50;
    if (hasSignature && descriptor.length < minimum) {
      throw _damagedArchive(header.filename);
    }
    final descriptorCrc = hasSignature
        ? descriptor.readUint32()
        : signatureOrCrc;
    final descriptorCompressed = zip64
        ? descriptor.readUint64()
        : descriptor.readUint32();
    final descriptorUncompressed = zip64
        ? descriptor.readUint64()
        : descriptor.readUint32();
    if (descriptorCrc != header.crc32 ||
        descriptorCompressed != header.compressedSize ||
        descriptorUncompressed != header.uncompressedSize) {
      throw _damagedArchive(header.filename);
    }
  }
}

/// Lightweight central-directory metadata for O(1) random-access reads on
/// large GB-scale EPUB archives without re-scanning all local headers.
class LocalBookZipEntryIndex {
  LocalBookZipEntryIndex({
    required this.filename,
    required this.localHeaderOffset,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.compressionMethod,
    required this.crc32,
    required this.generalPurposeBitFlag,
    required this.isSymbolicLink,
  });

  final String filename;
  final int localHeaderOffset;
  final int compressedSize;
  final int uncompressedSize;
  final int compressionMethod;
  final int crc32;
  final int generalPurposeBitFlag;
  final bool isSymbolicLink;

  int? dataOffset;

  bool get isDirectory => filename.endsWith('/');
}

/// Reads ONLY the ZIP/ZIP64 End of Central Directory and Central Directory
/// records in a single sequential read, avoiding per-entry local header seeks.
Map<String, LocalBookZipEntryIndex> indexLocalBookArchiveEntries(
  RandomAccessFile raf, {
  int maxEntries = 65535,
}) {
  final fileLength = raf.lengthSync();
  if (fileLength < 22) {
    throw _damagedArchive(null, '压缩文件不完整，请重新下载原书');
  }
  final tailStart = fileLength > 65557 ? fileLength - 65557 : 0;
  final tailLength = fileLength - tailStart;
  raf.setPositionSync(tailStart);
  final tail = raf.readSync(tailLength);
  if (tail.length < 22) throw _damagedArchive();
  final tailView = ByteData.sublistView(tail);

  var eocd = -1;
  for (var at = tail.length - 22; at >= 0; at--) {
    if (tailView.getUint32(at, Endian.little) == ZipDirectory.eocdSignature &&
        at + 22 + tailView.getUint16(at + 20, Endian.little) == tail.length) {
      eocd = tailStart + at;
      break;
    }
  }
  if (eocd < 0) throw _damagedArchive();

  final localEocdOffset = eocd - tailStart;
  var diskNumber = tailView.getUint16(localEocdOffset + 4, Endian.little);
  var cdDisk = tailView.getUint16(localEocdOffset + 6, Endian.little);
  var diskEntries = tailView.getUint16(localEocdOffset + 8, Endian.little);
  var totalEntries = tailView.getUint16(localEocdOffset + 10, Endian.little);
  var cdSize = tailView.getUint32(localEocdOffset + 12, Endian.little);
  var cdOffset = tailView.getUint32(localEocdOffset + 16, Endian.little);

  if (eocd >= 20) {
    raf.setPositionSync(eocd - 20);
    final locatorBytes = raf.readSync(20);
    if (locatorBytes.length == 20) {
      final loc = ByteData.sublistView(locatorBytes);
      if (loc.getUint32(0, Endian.little) ==
          ZipDirectory.zip64EocdLocatorSignature) {
        final zip64Disk = loc.getUint32(4, Endian.little);
        final zip64Offset = loc.getUint64(8, Endian.little);
        final totalDisks = loc.getUint32(16, Endian.little);
        if (zip64Disk != 0 ||
            totalDisks != 1 ||
            zip64Offset < 0 ||
            zip64Offset + 56 > eocd - 20) {
          throw _damagedArchive();
        }
        raf.setPositionSync(zip64Offset);
        final z64Bytes = raf.readSync(56);
        if (z64Bytes.length < 56) throw _damagedArchive();
        final z64 = ByteData.sublistView(z64Bytes);
        if (z64.getUint32(0, Endian.little) != ZipDirectory.zip64EocdSignature ||
            z64.getUint64(4, Endian.little) < 44) {
          throw _damagedArchive();
        }
        diskNumber = z64.getUint32(16, Endian.little);
        cdDisk = z64.getUint32(20, Endian.little);
        diskEntries = z64.getUint64(24, Endian.little);
        totalEntries = z64.getUint64(32, Endian.little);
        cdSize = z64.getUint64(40, Endian.little);
        cdOffset = z64.getUint64(48, Endian.little);
      }
    }
  }

  if (diskNumber != 0 ||
      cdDisk != 0 ||
      diskEntries != totalEntries ||
      totalEntries <= 0 ||
      totalEntries > maxEntries ||
      cdOffset < 0 ||
      cdSize <= 0 ||
      cdOffset + cdSize > eocd) {
    throw _damagedArchive();
  }

  raf.setPositionSync(cdOffset);
  final cdBytes = raf.readSync(cdSize);
  if (cdBytes.length != cdSize) throw _damagedArchive();
  final cd = ByteData.sublistView(cdBytes);

  final entries = <String, LocalBookZipEntryIndex>{};
  var pos = 0;
  for (var i = 0; i < totalEntries; i++) {
    if (pos + 46 > cdBytes.length) throw _damagedArchive();
    if (cd.getUint32(pos, Endian.little) != ZipFileHeader.signature) {
      throw _damagedArchive();
    }
    final flags = cd.getUint16(pos + 8, Endian.little);
    final method = cd.getUint16(pos + 10, Endian.little);
    final crc32 = cd.getUint32(pos + 16, Endian.little);
    var compressedSize = cd.getUint32(pos + 20, Endian.little);
    var uncompressedSize = cd.getUint32(pos + 24, Endian.little);
    final nameLength = cd.getUint16(pos + 28, Endian.little);
    final extraLength = cd.getUint16(pos + 30, Endian.little);
    final commentLength = cd.getUint16(pos + 32, Endian.little);
    var entryDisk = cd.getUint16(pos + 34, Endian.little);
    final externalAttrs = cd.getUint32(pos + 38, Endian.little);
    var localHeaderOffset = cd.getUint32(pos + 42, Endian.little);

    final recordEnd = pos + 46 + nameLength + extraLength + commentLength;
    if (recordEnd > cdBytes.length) throw _damagedArchive();

    final nameStart = pos + 46;
    final nameBytes = Uint8List.sublistView(
      cdBytes,
      nameStart,
      nameStart + nameLength,
    );
    final filename = utf8.decode(nameBytes, allowMalformed: true);

    if (extraLength >= 4 &&
        (uncompressedSize == 0xffffffff ||
            compressedSize == 0xffffffff ||
            localHeaderOffset == 0xffffffff ||
            entryDisk == 0xffff)) {
      var extraPos = nameStart + nameLength;
      final extraEnd = extraPos + extraLength;
      while (extraPos + 4 <= extraEnd) {
        final headerId = cd.getUint16(extraPos, Endian.little);
        final dataSize = cd.getUint16(extraPos + 2, Endian.little);
        final dataStart = extraPos + 4;
        if (dataStart + dataSize > extraEnd) break;
        if (headerId == 0x0001) {
          var fieldPos = dataStart;
          if (uncompressedSize == 0xffffffff && fieldPos + 8 <= dataStart + dataSize) {
            uncompressedSize = cd.getUint64(fieldPos, Endian.little);
            fieldPos += 8;
          }
          if (compressedSize == 0xffffffff && fieldPos + 8 <= dataStart + dataSize) {
            compressedSize = cd.getUint64(fieldPos, Endian.little);
            fieldPos += 8;
          }
          if (localHeaderOffset == 0xffffffff && fieldPos + 8 <= dataStart + dataSize) {
            localHeaderOffset = cd.getUint64(fieldPos, Endian.little);
            fieldPos += 8;
          }
          if (entryDisk == 0xffff && fieldPos + 4 <= dataStart + dataSize) {
            entryDisk = cd.getUint32(fieldPos, Endian.little);
          }
          break;
        }
        extraPos = dataStart + dataSize;
      }
    }

    pos = recordEnd;
    if (entryDisk != 0 ||
        flags & 1 != 0 ||
        _unsupportedPath(filename) ||
        compressedSize < 0 ||
        uncompressedSize < 0 ||
        localHeaderOffset < 0 ||
        localHeaderOffset >= cdOffset) {
      continue;
    }

    entries[filename] = LocalBookZipEntryIndex(
      filename: filename,
      localHeaderOffset: localHeaderOffset,
      compressedSize: compressedSize,
      uncompressedSize: uncompressedSize,
      compressionMethod: method,
      crc32: crc32,
      generalPurposeBitFlag: flags,
      isSymbolicLink: ((externalAttrs >> 16) & 0xf000) == 0xa000,
    );
  }
  return entries;
}

/// Reads and decodes a single indexed ZIP entry in O(1) using [RandomAccessFile].
Uint8List readIndexedLocalBookEntry(
  RandomAccessFile raf,
  LocalBookZipEntryIndex entry, {
  bool verifyCrc = false,
  int maxEntryBytes = 40 * 1024 * 1024,
}) {
  if (entry.isDirectory || entry.isSymbolicLink) {
    throw _damagedArchive(entry.filename, '不支持读取目录或符号链接');
  }
  if (entry.uncompressedSize > maxEntryBytes) {
    throw FormatException('压缩包条目超过大小限制：${entry.filename}');
  }
  var dataStart = entry.dataOffset;
  if (dataStart == null) {
    raf.setPositionSync(entry.localHeaderOffset);
    final headerBytes = raf.readSync(30);
    if (headerBytes.length < 30) {
      throw _damagedArchive(entry.filename, 'ZIP 本地文件头不完整');
    }
    final header = ByteData.sublistView(headerBytes);
    if (header.getUint32(0, Endian.little) != ZipFile.zipSignature) {
      throw _damagedArchive(entry.filename, 'ZIP 本地文件头损坏');
    }
    final nameLength = header.getUint16(26, Endian.little);
    final extraLength = header.getUint16(28, Endian.little);
    dataStart = entry.localHeaderOffset + 30 + nameLength + extraLength;
    entry.dataOffset = dataStart;
  }

  raf.setPositionSync(dataStart);
  final compressed = raf.readSync(entry.compressedSize);
  if (compressed.length != entry.compressedSize) {
    throw _damagedArchive(entry.filename, '压缩内容不完整');
  }

  final Uint8List bytes;
  switch (entry.compressionMethod) {
    case 0:
      bytes = compressed;
    case 8:
      final inflated = ZLibDecoder(raw: true).convert(compressed);
      bytes = inflated is Uint8List ? inflated : Uint8List.fromList(inflated);
    default:
      throw UnsupportedError('Unsupported ZIP method ${entry.compressionMethod}');
  }

  if (bytes.length != entry.uncompressedSize) {
    throw _damagedArchive(entry.filename, '展开后的大小与 ZIP 目录不一致');
  }
  if (verifyCrc && getCrc32(bytes) != entry.crc32) {
    throw _damagedArchive(entry.filename, '内容 CRC 校验不一致');
  }
  return bytes;
}

/// Parses image width/height from only the leading file header bytes (PNG, GIF,
/// WebP, JPEG) without full bitmap decoding. Returns null if the header is
/// incomplete, unsupported, or carries non-trivial EXIF rotation so callers can
/// fall back to full decoding.
({int width, int height})? probeImageDimensionsFromHeader(Uint8List bytes) {
  if (bytes.length < 10) return null;
  final data = ByteData.sublistView(bytes);
  
  // PNG: 8-byte signature + IHDR chunk (width @ 16, height @ 20).
  if (bytes.length >= 24 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47 &&
      bytes[4] == 0x0D &&
      bytes[5] == 0x0A &&
      bytes[6] == 0x1A &&
      bytes[7] == 0x0A &&
      bytes[12] == 0x49 &&
      bytes[13] == 0x48 &&
      bytes[14] == 0x44 &&
      bytes[15] == 0x52) {
    final w = data.getUint32(16, Endian.big);
    final h = data.getUint32(20, Endian.big);
    return (w > 0 && h > 0) ? (width: w, height: h) : null;
  }

  // GIF87a / GIF89a (width @ 6, height @ 8).
  if (bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x38 &&
      (bytes[4] == 0x37 || bytes[4] == 0x39) &&
      bytes[5] == 0x61) {
    final w = data.getUint16(6, Endian.little);
    final h = data.getUint16(8, Endian.little);
    return (w > 0 && h > 0) ? (width: w, height: h) : null;
  }

  // WebP: RIFF....WEBP + VP8 / VP8L / VP8X.
  if (bytes.length >= 25 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    final c0 = bytes[12], c1 = bytes[13], c2 = bytes[14], c3 = bytes[15];
    // 'VP8 '
    if (c0 == 0x56 && c1 == 0x50 && c2 == 0x38 && c3 == 0x20) {
      if (bytes.length < 30 ||
          bytes[23] != 0x9D ||
          bytes[24] != 0x01 ||
          bytes[25] != 0x2A) {
        return null;
      }
      final w = data.getUint16(26, Endian.little) & 0x3FFF;
      final h = data.getUint16(28, Endian.little) & 0x3FFF;
      return (w > 0 && h > 0) ? (width: w, height: h) : null;
    }
    // 'VP8L'
    if (c0 == 0x56 && c1 == 0x50 && c2 == 0x38 && c3 == 0x4C) {
      if (bytes[20] != 0x2F) return null;
      final bits = data.getUint32(21, Endian.little);
      final w = (bits & 0x3FFF) + 1;
      final h = ((bits >> 14) & 0x3FFF) + 1;
      return (w > 0 && h > 0) ? (width: w, height: h) : null;
    }
    // 'VP8X'
    if (c0 == 0x56 && c1 == 0x50 && c2 == 0x38 && c3 == 0x58) {
      if (bytes.length < 30) return null;
      final w = 1 + (bytes[24] | (bytes[25] << 8) | (bytes[26] << 16));
      final h = 1 + (bytes[27] | (bytes[28] << 8) | (bytes[29] << 16));
      return (w > 0 && h > 0) ? (width: w, height: h) : null;
    }
    return null;
  }

  // JPEG: SOI (0xFFD8) followed by marker segments until SOF0..SOF15.
  if (bytes[0] == 0xFF && bytes[1] == 0xD8) {
    var offset = 2;
    var swapForExif = false;
    while (offset + 4 <= bytes.length) {
      if (bytes[offset] != 0xFF) return null;
      while (offset < bytes.length && bytes[offset] == 0xFF) {
        offset++;
      }
      if (offset >= bytes.length) return null;
      final marker = bytes[offset++];
      if (marker == 0xD9 || marker == 0xDA) return null;
      if (marker == 0x00 ||
          marker == 0x01 ||
          (marker >= 0xD0 && marker <= 0xD8)) {
        continue;
      }
      if (offset + 2 > bytes.length) return null;
      final segLen = data.getUint16(offset, Endian.big);
      if (segLen < 2) return null;
      if (marker == 0xE1 && offset + segLen <= bytes.length) {
        final orient = _readJpegExifOrientation(bytes, offset + 2, segLen - 2);
        if (orient != null && orient >= 5 && orient <= 8) {
          swapForExif = true;
        }
      }
      final isSof =
          (marker >= 0xC0 && marker <= 0xC3) ||
          (marker >= 0xC5 && marker <= 0xC7) ||
          (marker >= 0xC9 && marker <= 0xCB) ||
          (marker >= 0xCD && marker <= 0xCF);
      if (isSof) {
        if (offset + 7 > bytes.length) return null;
        final h = data.getUint16(offset + 3, Endian.big);
        final w = data.getUint16(offset + 5, Endian.big);
        if (w <= 0 || h <= 0) return null;
        return swapForExif ? (width: h, height: w) : (width: w, height: h);
      }
      offset += segLen;
    }
  }
  return null;
}

int? _readJpegExifOrientation(Uint8List bytes, int start, int length) {
  if (length < 14 || start + length > bytes.length) return null;
  // "Exif\0\0"
  if (bytes[start] != 0x45 ||
      bytes[start + 1] != 0x78 ||
      bytes[start + 2] != 0x69 ||
      bytes[start + 3] != 0x66 ||
      bytes[start + 4] != 0x00 ||
      bytes[start + 5] != 0x00) {
    return null;
  }
  final tiff = start + 6;
  final data = ByteData.sublistView(bytes);
  final little = bytes[tiff] == 0x49 && bytes[tiff + 1] == 0x49;
  final big = bytes[tiff] == 0x4D && bytes[tiff + 1] == 0x4D;
  if (!little && !big) return null;
  final endian = little ? Endian.little : Endian.big;
  if (data.getUint16(tiff + 2, endian) != 42) return null;
  final ifdOffset = data.getUint32(tiff + 4, endian);
  final ifd = tiff + ifdOffset;
  if (ifd < tiff || ifd + 2 > start + length) return null;
  final count = data.getUint16(ifd, endian);
  var entryPos = ifd + 2;
  for (var i = 0; i < count; i++) {
    if (entryPos + 12 > start + length) return null;
    if (data.getUint16(entryPos, endian) == 0x0112) {
      return data.getUint16(entryPos + 8, endian);
    }
    entryPos += 12;
  }
  return null;
}

/// Probes image dimensions for an indexed ZIP entry by reading only the leading
/// header slice on Store entries (16 KiB -> 64 KiB), avoiding full-file I/O.
({int width, int height})? probeIndexedLocalBookImageSize(
  RandomAccessFile raf,
  LocalBookZipEntryIndex entry, {
  int maxEntryBytes = 40 * 1024 * 1024,
}) {
  if (entry.isDirectory ||
      entry.isSymbolicLink ||
      entry.uncompressedSize <= 0 ||
      entry.uncompressedSize > maxEntryBytes) {
    return null;
  }
  var dataStart = entry.dataOffset;
  if (dataStart == null) {
    raf.setPositionSync(entry.localHeaderOffset);
    final headerBytes = raf.readSync(30);
    if (headerBytes.length < 30) return null;
    final header = ByteData.sublistView(headerBytes);
    if (header.getUint32(0, Endian.little) != ZipFile.zipSignature) return null;
    final nameLength = header.getUint16(26, Endian.little);
    final extraLength = header.getUint16(28, Endian.little);
    dataStart = entry.localHeaderOffset + 30 + nameLength + extraLength;
    entry.dataOffset = dataStart;
  }

  if (entry.compressionMethod == 0) {
    for (final cap in const [16384, 65536]) {
      final toRead = entry.compressedSize < cap ? entry.compressedSize : cap;
      raf.setPositionSync(dataStart);
      final slice = raf.readSync(toRead);
      final dims = probeImageDimensionsFromHeader(slice);
      if (dims != null || toRead == entry.compressedSize) return dims;
    }
    return null;
  }

  if (entry.compressionMethod == 8) {
    raf.setPositionSync(dataStart);
    final compressed = raf.readSync(entry.compressedSize);
    if (compressed.length != entry.compressedSize) return null;
    final inflated = ZLibDecoder(raw: true).convert(compressed);
    final bytes =
        inflated is Uint8List ? inflated : Uint8List.fromList(inflated);
    return probeImageDimensionsFromHeader(bytes);
  }
  return null;
}
