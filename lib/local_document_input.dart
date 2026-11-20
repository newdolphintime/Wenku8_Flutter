import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:archive/archive.dart';

/// A leased native descriptor is already authorized. Reopening /proc/self/fd
/// is not equivalent on Android's scoped-storage FUSE provider, and Darwin
/// does not expose that path. Read bounded ranges from the live descriptor
/// without staging another copy of the original.
class LocalDocumentInput {
  const LocalDocumentInput.file(this.path)
    : descriptor = null,
      size = null,
      offset = 0,
      verifiedDigest = null;
  const LocalDocumentInput.descriptor(
    this.descriptor,
    this.size, {
    this.offset = 0,
    this.verifiedDigest,
  }) : path = null;
  final String? path, verifiedDigest;
  final int? descriptor, size;
  final int offset;
  int get length => size ?? File(path!).lengthSync();

  LocalDocumentBuffer open() {
    if (offset != 0) throw const FormatException('这份输入范围需要使用有界读取');
    if (path case final filePath?) {
      return LocalDocumentBuffer._(InputFileStream(filePath));
    }
    final handle = _DescriptorFileHandle(openReadBuffer());
    try {
      return LocalDocumentBuffer._(InputFileStream.withFileHandle(handle));
    } catch (_) {
      handle.closeSync();
      rethrow;
    }
  }

  /// Uses bounded positional reads so a truncated original reports a read
  /// error without touching stale memory-mapped pages.
  LocalDocumentReadBuffer openReadBuffer() =>
      LocalDocumentReadBuffer._open(this);

  Stream<List<int>> bytes() async* {
    if (path != null && offset == 0) {
      yield* File(path!).openRead();
      return;
    }
    final reader = openReadBuffer();
    try {
      for (var at = 0; at < reader.length;) {
        final count = math.min(
          reader.length - at,
          LocalDocumentReadBuffer.maxReadBytes,
        );
        yield reader.read(at, count);
        at += count;
      }
    } finally {
      reader.close();
    }
  }
}

/// The raw reader retains a 64-bit offset on 32-bit Android as well.
String localDocumentPreadSymbol(String operatingSystem) =>
    operatingSystem == 'ios' || operatingSystem == 'macos'
    ? 'pread'
    : 'pread64';

/// libc's thread-local errno entry points differ between Darwin, Bionic and
/// the musl libc used by Harmony/Linux. It is used only to retry EINTR.
String localDocumentErrnoSymbol(String operatingSystem) =>
    operatingSystem == 'ios' || operatingSystem == 'macos'
    ? '__error'
    : operatingSystem == 'android'
    ? '__errno'
    : '__errno_location';

typedef _PreadNative = IntPtr Function(Int32, Pointer<Void>, UintPtr, Int64);
typedef _Pread = int Function(int, Pointer<Void>, int, int);
typedef _AllocateNative = Pointer<Void> Function(UintPtr);
typedef _Allocate = Pointer<Void> Function(int);
typedef _FreeNative = Void Function(Pointer<Void>);
typedef _Free = void Function(Pointer<Void>);
typedef _ErrnoNative = Pointer<Int32> Function();
typedef _Errno = Pointer<Int32> Function();

/// A reader owns at most 32 KiB of scratch space and never owns the native
/// descriptor lease. Short reads/early EOF become ordinary source errors.
class LocalDocumentReadBuffer {
  LocalDocumentReadBuffer._(this._input, this.length, this._file, this._memory);
  factory LocalDocumentReadBuffer._open(LocalDocumentInput input) {
    final size = input.length;
    if (size < 0 || input.offset < 0) {
      throw const FormatException('原文件大小无效，请重新选择原文件');
    }
    if (input.path case final path?) {
      return LocalDocumentReadBuffer._(
        input,
        size,
        File(path).openSync(),
        null,
      );
    }
    final memory = _allocate(maxReadBytes).cast<Uint8>();
    if (memory.address == 0) throw OutOfMemoryError();
    return LocalDocumentReadBuffer._(input, size, null, memory);
  }

  static const maxReadBytes = 32 * 1024;
  static final _libc = DynamicLibrary.process();
  static final _allocate = _libc.lookupFunction<_AllocateNative, _Allocate>(
    'malloc',
  );
  static final _free = _libc.lookupFunction<_FreeNative, _Free>('free');
  static final _pread = _libc.lookupFunction<_PreadNative, _Pread>(
    localDocumentPreadSymbol(Platform.operatingSystem),
  );
  static final _errno = _libc.lookupFunction<_ErrnoNative, _Errno>(
    localDocumentErrnoSymbol(Platform.operatingSystem),
  );
  final LocalDocumentInput _input;
  final RandomAccessFile? _file;
  final Pointer<Uint8>? _memory;
  final int length;
  bool _closed = false;

  /// Reads an exact logical range without changing the leased descriptor's
  /// position. The returned bytes no longer depend on the original's lifetime.
  Uint8List read(int offset, int count) {
    if (count < 0 || count > maxReadBytes) {
      throw RangeError('原文件读取范围无效');
    }
    final bytes = Uint8List(count);
    _readInto(offset, bytes, 0, count);
    return bytes;
  }

  void _readInto(int offset, Uint8List target, int start, int count) {
    if (_closed) throw StateError('原文件读取已结束');
    if (offset < 0 || count > length - offset) {
      throw RangeError('原文件读取范围无效');
    }
    final file = _file;
    var done = 0;
    if (file != null) {
      file.setPositionSync(_input.offset + offset);
      while (done < count) {
        final read = file.readIntoSync(target, start + done, start + count);
        if (read == 0) throw const FormatException('原文件已变化，请重新选择');
        done += read;
      }
      return;
    }
    final errno = _errno;
    final memory = _memory!;
    while (done < count) {
      final read = _pread(
        _input.descriptor!,
        (memory + done).cast<Void>(),
        count - done,
        _input.offset + offset + done,
      );
      if (read < 0) {
        final code = errno().value;
        if (code == 4) continue; // EINTR never changes a decoder checkpoint.
        throw FileSystemException('无法读取原文件，请重新定位原文件', '', OSError('', code));
      }
      if (read == 0) throw const FormatException('原文件已变化，请重新选择');
      done += read;
    }
    if (count > 0) {
      target.setRange(start, start + count, memory.asTypedList(count));
    }
  }

  /// Releases only owned scratch storage/file handles, never the native lease.
  void close() {
    if (_closed) return;
    _closed = true;
    try {
      _file?.closeSync();
    } finally {
      if (_memory case final memory?) _free(memory.cast<Void>());
    }
  }
}

/// Gives the archive decoder buffered random access while leaving ownership
/// of the underlying Android or iOS document lease with the platform.
class _DescriptorFileHandle extends AbstractFileHandle {
  _DescriptorFileHandle(this._reader);

  final LocalDocumentReadBuffer _reader;
  @override
  int position = 0;
  @override
  int get length => _reader.length;
  @override
  bool get isOpen => !_reader._closed;

  @override
  bool open({FileAccess mode = FileAccess.read}) =>
      isOpen && mode == FileAccess.read;

  @override
  int readInto(Uint8List buffer, [int? size]) {
    final count = math.min(size ?? buffer.length, length - position);
    var done = 0;
    while (done < count) {
      final chunk = math.min(
        count - done,
        LocalDocumentReadBuffer.maxReadBytes,
      );
      _reader._readInto(position, buffer, done, chunk);
      position += chunk;
      done += chunk;
    }
    return done;
  }

  @override
  void writeFromSync(List<int> buffer, [int start = 0, int? end]) =>
      throw UnsupportedError('原文件为只读');

  @override
  Future<void> close() async => closeSync();

  @override
  void closeSync() => _reader.close();
}

class LocalDocumentBuffer {
  LocalDocumentBuffer._(this.stream);

  final InputStream stream;
  bool _closed = false;

  void close() {
    if (_closed) return;
    _closed = true;
    stream.closeSync();
  }
}
