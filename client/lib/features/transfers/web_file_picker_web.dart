import 'dart:async';
import 'dart:js_interop';

import 'package:mime/mime.dart' show lookupMimeType;
import 'package:web/web.dart' as web;

import '../../crypto/blob_plaintext_source.dart';
import 'picked_file.dart';

/// Web file pick via a browser-native `<input type="file">` (ADR-0013
/// Phase 4). Returns each picked file wrapped in a
/// [BlobPlaintextSource] so the send pipeline slices the Blob
/// directly — no eager materialisation, peak memory bounded by the
/// sodium chunk size.
///
/// Uses `package:web` rather than `file_picker` because file_picker's
/// web plugin doesn't expose the underlying `Blob` reference; we
/// need it to control the slice window ourselves.
///
/// Resolves an empty list on cancel (user closed the picker without
/// choosing anything).
Future<List<PickedFile>> pickFilesWeb() async {
  final input = web.HTMLInputElement()
    ..type = 'file'
    ..multiple = true;
  final done = Completer<web.FileList?>();
  void onChange(web.Event _) {
    done.complete(input.files);
  }

  void onCancel(web.Event _) {
    if (!done.isCompleted) done.complete(null);
  }

  input.addEventListener('change', onChange.toJS);
  input.addEventListener('cancel', onCancel.toJS);
  input.click();
  final files = await done.future;
  if (files == null || files.length == 0) return const [];
  final picked = <PickedFile>[];
  for (var i = 0; i < files.length; i++) {
    final f = files.item(i);
    if (f == null) continue;
    final name = f.name;
    // Browsers set `type` to '' for unknown MIME; fall back to a
    // filename-based lookup so the recipient's Save-As default still
    // lands somewhere reasonable.
    final mime = f.type.isEmpty ? lookupMimeType(name) : f.type;
    picked.add(
      PickedFile(
        source: BlobPlaintextSource(
          blob: f,
          filename: name,
          mimeType: mime,
        ),
        name: name,
        mime: mime,
        length: f.size,
      ),
    );
  }
  return picked;
}
