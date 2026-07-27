import 'dart:io';
import 'dart:typed_data';

/// Platform-neutral view of "the plaintext bytes we're about to
/// encrypt + upload" (ADR-0013 Phase 1 + Phase 4).
///
/// Mobile has a filesystem — pass a `FilePlaintextSource(path: …)`.
/// Web has `Blob`s from the browser file picker — pass a
/// `BlobPlaintextSource(blob: …)` from
/// `crypto/blob_plaintext_source.dart` (streams via `Blob.slice(...)
/// .arrayBuffer()` under the hood).
///
/// The single-pipeline invariant from ADR-0013: `openRead()` must be
/// callable AS A STREAM (not "load into memory then wrap in a
/// stream") so peak memory stays proportional to the sodium chunk
/// size, not the file size. The `FilePlaintextSource` below delegates
/// to `File.openRead()` which the Dart VM implements as
/// OS-scheduled chunked reads; the browser side will delegate to
/// `Blob.slice` + `arrayBuffer()` in a loop over slice windows.
///
/// The `lengthBytes` field is required and known ahead of time —
/// mobile stat + browser `File.size` both give it synchronously.
/// The transfer pipeline needs it for the pre-flight `/initiate`
/// call (server sizes the multipart plan based on total bytes).
abstract class PlaintextSource {
  /// Total plaintext size in bytes. MUST match the number of bytes
  /// that will actually be emitted by [openRead] — the server + the
  /// enc_header + the quota accounting all rely on this being
  /// truthful.
  int get lengthBytes;

  /// User-visible filename. Encoded into the `enc_header` so the
  /// recipient sees the same name the sender chose. Does NOT need
  /// to correspond to any on-disk name; a URL-derived name or a
  /// user-typed rename works too.
  String get filename;

  /// Best-effort MIME type. Nullable because platforms don't always
  /// know (Android SAF sometimes returns `application/octet-stream`;
  /// browser `File.type` can be empty for exotic extensions).
  /// The recipient's Save-As UI uses this to pick a default handler.
  String? get mimeType;

  /// Emit plaintext bytes as a `Stream<List<int>>`. Chunk sizes are
  /// implementation-defined (OS default on mobile, slice window on
  /// web); the crypto pipeline downstream re-chunks via sodium's
  /// `pushChunked` to the sodium chunk size. Callers should NOT
  /// assume any particular chunk size here.
  ///
  /// Implementations should not hold the emitted bytes in memory
  /// after they've been yielded downstream — that's the whole point
  /// of the streaming shape.
  Stream<List<int>> openRead();
}

/// Filesystem-backed `PlaintextSource` (mobile). Wraps a file path
/// and its stat metadata; `openRead()` delegates to `File.openRead()`.
///
/// Construct via the async [FilePlaintextSource.fromPath] factory
/// when you only have a path (does the stat for you), or via the
/// direct constructor when the caller already knows the length
/// (e.g., from the file picker, which returns the length as part of
/// `PickedFile`).
class FilePlaintextSource implements PlaintextSource {
  const FilePlaintextSource({
    required this.path,
    required this.filename,
    required this.lengthBytes,
    this.mimeType,
  });

  /// Async factory when the caller only has a path and hasn't stat'd
  /// the file yet. Prefer the direct constructor when possible —
  /// avoids a redundant syscall.
  static Future<FilePlaintextSource> fromPath(
    String path, {
    String? filename,
    String? mimeType,
  }) async {
    final file = File(path);
    final length = await file.length();
    return FilePlaintextSource(
      path: path,
      filename: filename ?? _basename(path),
      lengthBytes: length,
      mimeType: mimeType,
    );
  }

  final String path;

  @override
  final String filename;

  @override
  final int lengthBytes;

  @override
  final String? mimeType;

  @override
  Stream<List<int>> openRead() => File(path).openRead();
}

String _basename(String path) {
  // Platform-neutral: strip after the last `/` or `\`. Robust enough
  // for filename display; the send pipeline never treats the value
  // as a path.
  final lastSep = path.lastIndexOf(RegExp(r'[\\/]'));
  if (lastSep < 0) return path;
  return path.substring(lastSep + 1);
}

/// In-memory `PlaintextSource` backed by a `Uint8List`. Handy for
/// small payloads (test fixtures, future "paste text to send" web
/// affordance) where the whole plaintext already lives in RAM.
///
/// Do NOT use this for user-selected files — that would defeat the
/// streaming property. Use `FilePlaintextSource` on mobile and the
/// (upcoming) `BlobPlaintextSource` on web instead.
class BytesPlaintextSource implements PlaintextSource {
  BytesPlaintextSource({
    required this.bytes,
    required this.filename,
    this.mimeType,
    this.chunkSize = 64 * 1024,
  });

  final Uint8List bytes;

  @override
  final String filename;

  @override
  final String? mimeType;

  /// Chunk size for [openRead]. Defaults to the sodium chunk size so
  /// the downstream re-chunker sees exactly one chunk per emit.
  final int chunkSize;

  @override
  int get lengthBytes => bytes.length;

  @override
  Stream<List<int>> openRead() async* {
    var offset = 0;
    while (offset < bytes.length) {
      final end = (offset + chunkSize).clamp(0, bytes.length);
      yield Uint8List.sublistView(bytes, offset, end);
      offset = end;
    }
  }
}

