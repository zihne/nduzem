# ADR-0008: Native SAF stream-save for large-file receive

- **Status**: Accepted
- **Date**: 2026-07-04
- **Related**: [ADR-0006](0006-m4-streaming-receive.md) — open follow-up
  called this out explicitly ("Save step is the residual OOM risk…
  slated for a follow-up branch that writes directly through a SAF URI")

## Context

Post-ADR-0006 the receive flow streams download + decrypt into two
temp files under the OS cache dir, peak memory ≈ one 64 KiB chunk.
The **save** step still routes through
`file_picker.saveFile(bytes: ...)` on Android, which OOMs above
~200 MiB on mid-range devices because the plugin's Android backend
accepts bytes only — no path-based streaming API.

ADR-0006 shipped a fallback (`_saveToExternalStorage`) that copies
the plaintext temp file into `Android/data/<pkg>/files/Nduzem/`
via `File.copy` (streaming). It works for multi-GB files but the
destination is:

- buried under Files-app navigation (most users can't find it
  without a walkthrough)
- deleted when the app is uninstalled (not "the user's file" in any
  meaningful sense)
- outside the SAF picker experience the user expected when they
  chose to receive the file

Users want the same "pick where to save this" flow they get for
small files, all the way up to multi-GB. That means a **native SAF
stream-write** — the recipient picks a `content://` URI via
`ACTION_CREATE_DOCUMENT`, and we copy the plaintext temp file into
`ContentResolver.openOutputStream(uri)` chunk-by-chunk on the
platform thread.

Open questions:

1. **Method-channel shape** — one round-trip that both picks and
   writes, or two round-trips?
2. **iOS scope** — do we implement both platforms in this branch,
   or ship Android now and follow up on iOS?
3. **Progress + cancel** — do we surface per-byte progress and
   cancellation, or treat the write as one indivisible fast
   operation?
4. **Fallback lifetime** — delete `_saveToExternalStorage` outright
   or keep it as belt-and-braces?

## Decision

### Split channel: `pickSaveUri` + `writeFileToUri`

Two round-trips over one method channel
(`com.nduzem.app/saf_stream_save`):

- `pickSaveUri(suggestedFilename: String) -> String?` launches
  `ACTION_CREATE_DOCUMENT` via `startActivityForResult` +
  `onActivityResult` (the classic Flutter-plugin path — Flutter's
  `FlutterActivity` extends bare `android.app.Activity`, not
  `androidx.activity.ComponentActivity`, so the modern
  `ActivityResultRegistry` isn't available without swapping the
  base class to `FlutterFragmentActivity`, which we avoid to keep
  the blast radius on theming + splash + plugin registration
  small). Returns the resulting `content://` URI as a string. Null
  on user-cancel.
- `writeFileToUri(sourcePath: String, uri: String) -> Unit`
  opens the source file for read + `ContentResolver.openOutputStream`
  for write, copies in a 64 KiB loop on a dedicated worker thread
  (`kotlin.concurrent.thread`) so the platform (main) thread stays
  free during multi-GB copies. Throws `PlatformException` on I/O
  error.

Why split:

- **Retry semantics.** If the write fails partway, the receive
  screen can prompt "retry the save?" without re-launching the SAF
  picker (which would present the user with a "file already exists,
  overwrite?" dialog for the same URI).
- **UI feedback.** The screen can update state between picker and
  write — "Saving to `filename.zip`…" — without inventing an
  intermediate callback.
- **Testability.** Each round-trip mocks independently.

### Android only for v1

The Kotlin side implements both methods. iOS remains on the existing
`_saveToExternalStorage` fallback (which on iOS resolves to
`getApplicationDocumentsDirectory()`, i.e. the app's Documents dir
that's user-visible in Files-app). Rationale:

- iOS app heap is roomier (typically 1-2 GB effective before jetsam)
  so the OOM ceiling is much higher; users hit it less often.
- iOS's SAF-equivalent is `UIDocumentPickerViewController` with
  `forExporting:` — a different mental model that deserves its own
  design pass.
- Owner is on Android; Android delivers the biggest immediate win.

An **iOS follow-up ADR** is queued when iOS receive traffic warrants
it.

### No progress + no cancel during write

The write step copies from the app's cache dir to a
`content://` sink. On modern flash storage this is 100-400 MB/s;
a 5 GB file lands in 15-50 seconds. The receive screen shows an
indeterminate spinner + "Saving…" label — same visual pattern as
the current SAF small-file save.

If real-world usage produces multi-minute waits (very old devices,
slow removable media, cloud-backed URIs like Google Drive) we
revisit with an EventChannel-based progress feed and a cancel path.
Not worth building preemptively; the plumbing is real cost.

### Keep `_saveToExternalStorage` as belt-and-braces

Two triggers keep it alive:

- **iOS receives** — no SAF equivalent yet on iOS.
- **`pickSaveUri` returns null** — user cancelled the picker.
  We surface a "Save cancelled — keep on cache?" prompt with the
  existing fallback as the "yes, keep it" branch.
- **`writeFileToUri` throws** — SAF write failed. Fallback lets
  the user still walk away with the file.

Concretely: on Android, the primary path is
`pickSaveUri` → `writeFileToUri` → `savedPath = uri`. Fallback fires
only on explicit failure. On iOS, `_saveToExternalStorage` remains
the primary large-file path unchanged.

### Dart-side abstraction

```dart
abstract class SafSaver {
  Future<String?> pickSaveUri({required String suggestedFilename});
  Future<void> writeFileToUri({
    required String sourcePath,
    required String uri,
  });
}
```

Concrete `MethodChannelSafSaver` uses the method channel;
`_UnsupportedSafSaver` returns `pickSaveUri(...) → null` on non-
Android platforms so the screen can route to the fallback without
a branch on `Platform.isAndroid` at the call site.

Provider wiring: `Provider<SafSaver>` in `auth_providers.dart`
(matches the pattern for other infrastructure seams). Tests
override with a fake.

## Consequences

- **Multi-GB receives now save to a real, user-picked location** —
  Downloads folder, Google Drive, external SD, whatever SAF exposes.
  The buried `Android/data/…/Nduzem/` path is no longer the
  destination for large files (it's still the fallback).
- **One new Kotlin class + minimal MainActivity change.** The
  plugin registers on `configureFlutterEngine` per Flutter's
  embedding v2 pattern.
- **Uninstall now leaves the file.** Files saved via SAF live at
  the user-chosen URI; uninstalling the app doesn't touch them.
  This is what users expect.
- **iOS receives are unchanged.** Same effective behaviour as
  before this branch. The follow-up will close the gap.
- **`_saveToExternalStorage` gains a real reason to exist** — it's
  the escape hatch when SAF isn't available or fails, not the
  primary path.

## Alternatives considered

- **One-method channel** (`pickAndWriteToUri`). Simpler surface but
  couples picker + write, making retry-on-write-failure a
  re-picker round-trip. Rejected on UX.
- **Bundled iOS in this branch.** Doubles the scope for an unclear
  win — iOS OOM at save is real but happens less often, and the
  iOS design deserves its own pass. Deferred.
- **`share_plus` "Share this file" instead of save.** Nice touch,
  works today, but doesn't answer "I want to keep this file";
  save-and-manage is the primary intent.
- **Ship progress + cancel now.** EventChannel for progress + a
  MethodChannel cancel call. Real cost, unclear benefit until we
  see a real slow case. Deferred.
- **Delete `_saveToExternalStorage` outright.** Would remove ~40
  lines but leaves users with no fallback on iOS or picker
  failure. Keep it.
- **Use a third-party plugin** (e.g. `saf` or `flutter_file_dialog`).
  Both exist, both add a maintained dep for what's ultimately ~80
  lines of Kotlin. Keep the native code local so the receive-side
  save path has no plugin risk.

## Open follow-ups

- **iOS SAF-equivalent** — `UIDocumentPickerViewController` +
  `URLSession` streaming write. Own ADR when it lands.
- **Progress + cancel during write** — only if real usage produces
  multi-minute waits.
- **Overwrite semantics** — SAF returns the same URI when the user
  picks "overwrite existing." We rely on that; a future
  "save-as-copy" feature would need a distinct code path.
- **Cloud-backed URIs** — Google Drive / Dropbox providers appear
  in the SAF picker on many devices. `openOutputStream` on those
  buffers to a local temp before upload, so a "success" from
  Kotlin's perspective doesn't mean "uploaded." Acceptable —
  matches every other SAF-based Android app.
