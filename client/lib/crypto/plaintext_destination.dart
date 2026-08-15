import 'dart:io';
import 'dart:typed_data';

import 'file_crypto.dart' show FileCrypto;

/// Platform-neutral view of "where the decrypted plaintext lands"
/// (ADR-0013 Phase 5). Mirror of `PlaintextSource` on the send side.
///
/// Mobile writes each chunk into a temp file
/// ([FilePlaintextDestination]); web will accumulate into a `Blob` /
/// stream to a File-System-Access writer (Phase 6). The receive
/// pipeline calls [add] as the streaming decrypt emits chunks, then
/// [close] once the ciphertext stream drains. On error the caller
/// calls [discard] to clean up (partial temp file, dangling object
/// URL, …).
abstract class PlaintextDestination {
  /// Append one plaintext chunk. Same shape as [IOSink.add]; may
  /// return a real Future when the underlying sink back-pressures.
  Future<void> add(List<int> chunk);

  /// Finalize the destination. After this returns the plaintext is
  /// readable from wherever the concrete impl exposes it (a file
  /// path for [FilePlaintextDestination]; a blob handle for the
  /// web variant landing in Phase 6). Idempotent — a second call
  /// after a successful close is a no-op.
  Future<void> close();

  /// Best-effort teardown for the failure / cancel path. Drops any
  /// partial temp file, releases any object URL. Safe to call after
  /// [close] (no-op then).
  Future<void> discard();

  /// Cumulative bytes written via [add]. Used by the receive-side
  /// progress callback.
  int get bytesWritten;
}

/// Filesystem-backed [PlaintextDestination] (mobile). Writes each
/// chunk to a temp file opened by [newTempFile]; the caller reads
/// bytes back at save-time via [path].
class FilePlaintextDestination implements PlaintextDestination {
  FilePlaintextDestination._(this.path, this._sink);

  /// Path of the plaintext temp file. The caller owns its lifetime
  /// after [close]: reads it into memory for `file_picker.saveFile`
  /// or streams it via SAF, then deletes on ack.
  final String path;

  final IOSink _sink;
  int _bytesWritten = 0;
  bool _closed = false;

  /// Open a fresh temp file under `tempDir`. Creates the directory
  /// if needed — mirrors the old `decryptFileToTempFile` contract
  /// so the receive path can pass `path_provider`'s temp dir
  /// verbatim.
  static Future<FilePlaintextDestination> newTempFile(Directory tempDir) async {
    if (!await tempDir.exists()) await tempDir.create(recursive: true);
    final file = File(
      '${tempDir.path}/nduzem-${FileCrypto.randomTempSlug()}.dec.tmp',
    );
    return FilePlaintextDestination._(file.path, file.openWrite());
  }

  @override
  Future<void> add(List<int> chunk) async {
    _sink.add(chunk);
    _bytesWritten += chunk.length;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _sink.flush();
    await _sink.close();
  }

  @override
  Future<void> discard() async {
    // Best-effort close so we can then delete. Failures are ignored —
    // the caller is already unwinding an error.
    try {
      if (!_closed) {
        await _sink.close();
        _closed = true;
      }
    } on Object {
      // ignore
    }
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } on Object {
      // ignore
    }
  }

  @override
  int get bytesWritten => _bytesWritten;
}

/// In-memory [PlaintextDestination] that accumulates chunks into a
/// single `Uint8List` (ADR-0013 Phase 6). Web receive uses this
/// because the browser has no filesystem — the assembled bytes get
/// handed to a File System Access API writer or an `<a download>`
/// blob URL at save time.
///
/// Peak memory here is the whole plaintext size, once — a genuine
/// cost of the browser environment until the streaming FSA save path
/// lands as a Phase 7 polish. On mobile prefer [FilePlaintextDestination]
/// which keeps memory bounded to a single chunk.
class BlobPlaintextDestination implements PlaintextDestination {
  BlobPlaintextDestination();

  final BytesBuilder _buffer = BytesBuilder(copy: false);
  int _bytesWritten = 0;
  bool _closed = false;
  Uint8List? _bytes;

  /// Assembled plaintext. Only valid after [close] — reading earlier
  /// throws because the accumulator hasn't finalised its buffer yet.
  Uint8List get bytes {
    final b = _bytes;
    if (b == null) {
      throw StateError(
        'BlobPlaintextDestination: bytes read before close()',
      );
    }
    return b;
  }

  @override
  Future<void> add(List<int> chunk) async {
    _buffer.add(chunk);
    _bytesWritten += chunk.length;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _bytes = _buffer.takeBytes();
  }

  @override
  Future<void> discard() async {
    _buffer.clear();
    _bytes = null;
    _closed = true;
  }

  @override
  int get bytesWritten => _bytesWritten;
}
