import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Save `bytes` to disk via the browser (ADR-0013 Phase 6).
///
/// Two paths, tried in order:
///
/// 1. **File System Access API** (`showSaveFilePicker`) — user picks
///    the destination, we write via a `WritableStream`. Available on
///    Chromium (Chrome / Edge / Opera). True streaming under the
///    hood; peak browser memory ≈ writer's internal buffer.
/// 2. **`<a download>` fallback** — construct a `blob:` object URL
///    and click a synthetic anchor. Works everywhere (Firefox,
///    Safari, older Chromium). No location picker; the browser drops
///    the file into the default downloads folder.
///
/// Returns a short human-readable label of where the file went
/// (the FSA-picked name or the fallback filename), or `null` when
/// the user cancelled the FSA picker. Any other failure throws.
Future<String?> saveBytesWeb({
  required Uint8List bytes,
  required String filename,
  String? mimeType,
}) async {
  final blob = _blobFromBytes(bytes, mimeType);
  final win = web.window;
  if (win.has('showSaveFilePicker')) {
    // Cancellation returns null from here rather than throwing, and is
    // NOT retried through the anchor: the anchor path drops the file
    // into Downloads with no prompt, so falling back on cancel would
    // write a decrypted file to disk immediately after the user
    // declined to save it.
    return _saveViaFsa(win, blob, filename);
  }
  // Anchor fallback is for browsers with no FSA at all (Firefox,
  // Safari), not for an FSA call that failed.
  _saveViaAnchor(blob, filename);
  return filename;
}

web.Blob _blobFromBytes(Uint8List bytes, String? mimeType) {
  final part = bytes.toJS as JSAny;
  final parts = [part].toJS;
  final options = web.BlobPropertyBag(
    type: mimeType ?? 'application/octet-stream',
  );
  return web.Blob(parts, options);
}

/// Returns the saved name, or `null` if the user cancelled the picker.
Future<String?> _saveViaFsa(
  web.Window win,
  web.Blob blob,
  String filename,
) async {
  final options = _SaveFilePickerOptions(suggestedName: filename);
  final JSAny? handleJs;
  try {
    // Called as a METHOD on window. The previous binding was a
    // top-level `showSaveFilePicker(window, options)` taking two
    // arguments, but the API takes at most one — so the browser read
    // the options dictionary off the Window object (where
    // `suggestedName` is undefined) and dropped the real options as a
    // surplus argument. The picker opened with an empty filename and
    // no Dart-side default could reach it.
    handleJs = await win.fsa.showSaveFilePicker(options).toDart;
  } on Object catch (err) {
    // The user dismissing the picker REJECTS the promise with an
    // AbortError — it does not resolve to null, so the old
    // `isUndefinedOrNull` check could never fire.
    if (_isAbortError(err)) return null;
    rethrow;
  }
  if (handleJs.isUndefinedOrNull) return null;
  final handle = handleJs as _FileSystemFileHandle;
  final writable = await handle.createWritable().toDart;
  try {
    await writable.write(blob).toDart;
  } finally {
    await writable.close().toDart;
  }
  return handle.name;
}

/// True when a rejected FSA promise carries `DOMException.name ==
/// 'AbortError'` — i.e. the user cancelled rather than anything
/// failing. Written defensively: a non-JS error simply isn't an abort.
bool _isAbortError(Object err) {
  try {
    final name = (err as JSObject).getProperty<JSString?>('name'.toJS);
    return name?.toDart == 'AbortError';
  } on Object {
    return false;
  }
}

void _saveViaAnchor(web.Blob blob, String filename) {
  final url = web.URL.createObjectURL(blob);
  try {
    final anchor = web.HTMLAnchorElement()
      ..href = url
      ..download = filename
      ..style.display = 'none';
    web.document.body?.append(anchor);
    anchor.click();
    anchor.remove();
  } finally {
    web.URL.revokeObjectURL(url);
  }
}

extension on web.Window {
  bool has(String name) =>
      (this as JSObject).hasProperty(name.toJS).toDart;

  /// Reinterpret the window as its File System Access surface, so the
  /// picker is invoked as `window.showSaveFilePicker(options)` — a
  /// method call with the receiver bound — rather than as a top-level
  /// function taking the window as its first argument.
  _FsaWindow get fsa => _FsaWindow(this as JSObject);
}

/// Minimal FSA bindings — `package:web` doesn't ship them yet.
///
/// Declared as a member of the window rather than a top-level `@JS`
/// function on purpose: `showSaveFilePicker` accepts at most ONE
/// argument, so a two-argument top-level binding puts the Window where
/// the options dictionary belongs and the suggested name is lost.
extension type _FsaWindow(JSObject _) implements JSObject {
  external JSPromise<JSAny?> showSaveFilePicker(
    _SaveFilePickerOptions options,
  );
}

extension type _SaveFilePickerOptions._(JSObject _) implements JSObject {
  external factory _SaveFilePickerOptions({String suggestedName});
}

extension type _FileSystemFileHandle._(JSObject _) implements JSObject {
  external String get name;
  external JSPromise<_FileSystemWritableFileStream> createWritable();
}

extension type _FileSystemWritableFileStream._(JSObject _) implements JSObject {
  external JSPromise<JSAny?> write(web.Blob data);
  external JSPromise<JSAny?> close();
}
