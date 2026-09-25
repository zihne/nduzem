import 'dart:async';
import 'dart:js_interop';

import 'package:mime/mime.dart' show lookupMimeType;
import 'package:web/web.dart' as web;

import '../../crypto/blob_plaintext_source.dart';
import 'picked_file.dart';

/// How long to wait, after the page regains focus, before treating the
/// pick as finished on browsers that never fired an event.
///
/// The trade-off is one-sided but real. Too short and a slow `change`
/// (iOS transcodes HEIC to JPEG at selection time, which is not
/// instant) is read as a cancel; too long and cancelling feels broken.
/// Three seconds is generous for the transcode and still short enough
/// that a cancel doesn't look hung — and because the fallback resolves
/// with whatever `input.files` holds rather than with "cancelled", the
/// early-fire case degrades to an empty pick rather than a wrong one.
const _pickSettleDelay = Duration(seconds: 3);

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
///
/// This function must always complete. The caller holds a spinner open
/// across the await, so a `Completer` that never fires is not a missed
/// file — it is an app that hangs with no way out. Safari makes that
/// the default outcome twice over, which is what the DOM attachment and
/// the focus fallback below are for.
Future<List<PickedFile>> pickFilesWeb() async {
  final input = web.HTMLInputElement()
    ..type = 'file'
    ..multiple = true;

  // The input must be in the document. Safari — iOS in particular —
  // does not reliably fire `change` on a detached file input: the
  // picker opens, the user chooses, and no event is ever delivered.
  //
  // It also has to stay renderable. `display: none` and
  // `visibility: hidden` suppress the picker outright on some iOS
  // versions, so park it off-screen and transparent instead.
  input.style
    ..position = 'fixed'
    ..left = '-10000px'
    ..top = '0'
    ..width = '1px'
    ..height = '1px'
    ..opacity = '0';
  web.document.body!.appendChild(input);

  final done = Completer<web.FileList?>();
  Timer? settle;

  void finish(web.FileList? files) {
    if (!done.isCompleted) done.complete(files);
  }

  final onChange = ((web.Event _) => finish(input.files)).toJS;
  final onCancel = ((web.Event _) => finish(null)).toJS;

  // `cancel` is Chromium and Firefox only; Safari never fires it, so
  // dismissing the picker there would hang forever on its own. The
  // window regaining focus is the only signal Safari gives that the
  // native picker has closed, and it arrives slightly *before* any
  // `change`, hence the settle delay.
  //
  // The fallback deliberately resolves with `input.files` rather than
  // with null: that makes it a safety net for a dropped `change` event
  // as well as for the missing `cancel`, and the worst case becomes an
  // empty pick the user can retry instead of a dead screen.
  final onFocus = ((web.Event _) {
    settle?.cancel();
    settle = Timer(_pickSettleDelay, () => finish(input.files));
  }).toJS;

  web.FileList? files;
  try {
    input.addEventListener('change', onChange);
    input.addEventListener('cancel', onCancel);
    input.click();
    // Armed after the click so an unrelated focus event arriving before
    // the picker opens can't start the settle timer early.
    web.window.addEventListener('focus', onFocus);
    files = await done.future;
  } finally {
    settle?.cancel();
    input.removeEventListener('change', onChange);
    input.removeEventListener('cancel', onCancel);
    web.window.removeEventListener('focus', onFocus);
    // Safe to detach: a File is independent of the element that
    // produced it, and BlobPlaintextSource slices it long after this.
    input.remove();
  }

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
