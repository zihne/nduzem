import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'plaintext_source.dart';

/// Browser-backed `PlaintextSource` (web, ADR-0013 Phase 4).
///
/// Wraps a `Blob` (or a `File`, which is a Blob subclass) coming out
/// of the browser file picker. Every call to [openRead] slices the
/// Blob into `chunkSize` windows and reads each slice via
/// `arrayBuffer()`. Because the browser only materializes the current
/// slice, peak memory is `chunkSize` regardless of file size — the
/// same streaming property `File.openRead()` gives us on mobile.
///
/// Loaded via `blob_plaintext_source.dart`'s conditional export so
/// non-web builds see a stub instead of this file.
class BlobPlaintextSource implements PlaintextSource {
  BlobPlaintextSource({
    required this.blob,
    required this.filename,
    this.mimeType,
    this.chunkSize = 64 * 1024,
  }) : lengthBytes = blob.size;

  final web.Blob blob;

  @override
  final String filename;

  @override
  final String? mimeType;

  /// Bytes per Blob.slice window. 64 KiB matches the sodium chunk
  /// size so the downstream re-chunker sees one chunk per slice —
  /// no re-buffering overhead.
  final int chunkSize;

  @override
  final int lengthBytes;

  @override
  Stream<List<int>> openRead() async* {
    var offset = 0;
    while (offset < lengthBytes) {
      final end = offset + chunkSize < lengthBytes
          ? offset + chunkSize
          : lengthBytes;
      final slice = blob.slice(offset, end);
      final buffer = await slice.arrayBuffer().toDart;
      yield buffer.toDart.asUint8List();
      offset = end;
    }
  }
}
