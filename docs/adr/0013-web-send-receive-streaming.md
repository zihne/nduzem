# ADR-0013 — Web send + receive: streaming pipeline unified across mobile and web

Status: Accepted
Date: 2026-07-26

## Context

The mobile client ships full-featured send + receive: multi-GB files,
`crypto_secretstream_xchacha20poly1305` encryption chunked at 64 KiB,
R2 multipart upload with per-part `ETag`s, streaming decrypt to a
recipient-chosen destination (SAF on Android, documents-directory on
iOS). Peak memory ≈ 8 MiB regardless of file size (ADR-0004, ADR-0006).

The Flutter web app (WS 3 of the scale-to-business roadmap) is now at
"shell" stage — auth flow works, but send/receive would throw
`UnsupportedError` at the first `dart:io File(...)` call. Mobile-only
today.

The goal — set in the roadmap: **full parity with mobile on web**.
Same 10 GB per-transfer cap, same streaming crypto, same multipart
upload, same 8-ish-MiB peak memory. Not a "web supports smaller files"
compromise.

### What forces this to be non-trivial

Every part of the mobile send/receive path assumes a filesystem:

1. **Input**: `plaintextPath: String` → `File(plaintextPath).openRead()`
   → `Stream<Uint8List>` fed into `_sodium.crypto.secretStream.pushChunked`.
   Browsers have no filesystem; the plaintext arrives as a `Blob` via
   `<input type="file">` or drag-drop.

2. **Intermediate storage**: `encryptFileToTempFile()` writes the
   ciphertext to `<tempDir>/opaqueshare_send_XXX.bin`. The upload code
   then re-opens that temp file and streams part-sized chunks from it
   for multipart PUTs. Web has no `getTemporaryDirectory()`; ciphertext
   staging must live in memory or, better, never fully materialize.

3. **Output (receive)**: mobile streams ciphertext from R2 → temp
   file, then streams-decrypt from that temp file → plaintext temp
   file, then hands the plaintext path to the OS save picker.
   Web can't write to disk except via `<a download>` (blob-in-memory)
   or the File System Access API (Chromium-only, chunked writes).

The sodium_libs smoke test
([docs/dev/sodium-web-smoke-test.md](../dev/sodium-web-smoke-test.md))
already proved that `crypto_secretstream_xchacha20poly1305.pushChunked`
streams cleanly on Flutter web with peak heap bounded by chunk size
(~300 MiB total across all sizes up to 2 GiB input). So the CRYPTO
layer is not the bottleneck. The bottleneck is the surrounding I/O
plumbing that assumes files everywhere.

### What's out of scope for this ADR

- **Batch / multi-file send** — mobile has this (SendQueue,
  BatchSendScreen). Web v1 is single-file only. Batch on web is a
  possible v2 feature; deferred pending demand.
- **Resume-after-tab-close** — web can't. Mobile can via SAF
  document persistence. Web transfers that interrupt mid-flight
  cancel and require restart.
- **Link-mode receive on the web app** — already handled by the
  marketing site's `password-reset.html` / decrypt HTML per server
  ADR-0035. The Flutter web app's `/r/:id` route is redundant and
  stays a defensive no-op fallback.

## Decision

**A single streaming pipeline that both mobile and web use.** No
platform forking of the crypto or transfer logic. The mobile
temp-file staging (ADR-0004) is retired in favor of an interleaved
encrypt-and-upload pipeline that never materializes the full
ciphertext on any platform.

Peak memory contract: **~one multipart part's worth of ciphertext
(~5-10 MiB)** on both mobile and web, plus the sodium chunk buffer
(64 KiB). Same as mobile today; web is a new baseline in that
range.

### Three abstractions, four files

**`PlaintextSource`** — the input side.

```dart
abstract class PlaintextSource {
  int get lengthBytes;                           // total, known ahead of time
  Stream<Uint8List> openRead({int chunkSize});   // caller cancels via cancel token
  String get filename;                           // used for enc_header
  String? get mimeType;
}
```

Two implementations:
- `FilePlaintextSource(String path)` — mobile — uses `File(path).openRead()`.
- `BlobPlaintextSource(dynamic blob)` — web — uses `Blob.slice(start, end).arrayBuffer()` in a loop.

**`CiphertextSink`** — the output side of encrypt, input side of upload.
Not a class; it's just the `Stream<Uint8List>` returned by the new
`FileCrypto.encryptToStream(...)`. The upload code consumes chunks
and accumulates them into one part's worth (5-10 MiB) before firing
the PUT, then discards the buffer.

**`PlaintextDestination`** — the receive side.

```dart
abstract class PlaintextDestination {
  IOSink openWrite();          // caller pushes decrypted chunks
  Future<void> finalize();     // save (SAF on Android, blob on web)
  String get displayLocation;  // "Saved to /Downloads/foo.pdf"
}
```

Two implementations:
- `FilePlaintextDestination` — mobile — writes to a temp file, then
  invokes the platform save picker (SAF on Android via ADR-0008
  native saver, iOS documents dir).
- `BlobPlaintextDestination` — web — accumulates chunks in a
  `Uint8List` buffer, `finalize()` wraps in a `Blob` and triggers a
  browser download via `<a download>`. Where supported (Chromium),
  uses File System Access API's `createWritable()` to stream
  directly to disk without holding the full plaintext in memory.

### The interleaved encrypt-and-upload pipeline

The new `TransferService.send` path (both platforms):

```
┌─────────────┐  chunks   ┌────────────┐  ciphertext  ┌────────────┐
│ Plaintext   │──64 KiB──▶│ sodium     │──stream──────▶│ Part       │
│ Source      │           │ pushChunked│               │ accumulator│
└─────────────┘           └────────────┘               └─────┬──────┘
                                                             │ 5-10 MiB
                                                             ▼
                                                       ┌───────────┐
                                                       │ PUT part  │
                                                       │ to R2     │
                                                       └─────┬─────┘
                                                             │ ETag
                                                             ▼
                                                       ┌───────────┐
                                                       │ /commit   │
                                                       │ (all ETags)│
                                                       └───────────┘
```

Steps in order:
1. `Source.openRead(64 KiB)` returns `Stream<Uint8List>`.
2. `FileCrypto.encryptToStream(source, key)` wraps that stream through
   `secretstream.pushChunked` → returns `Stream<Uint8List>` of ciphertext.
3. Part accumulator buffers ciphertext until it reaches the R2 part
   size (default 8 MiB, configurable). When full, PUT to the part's
   pre-signed URL from `/initiate`. On success, buffer clears; on
   failure, `/abort` + propagate.
4. Repeat until source drains. Last part MAY be smaller than the
   minimum part size (R2 allows this for the final part).
5. `/commit` with the full ETag list.

Peak memory at any time = 64 KiB (sodium chunk) + one part (~8 MiB)
= ~8 MiB. Same on mobile and web.

### FileCrypto surface changes

**New** (both platforms use these):
- `FileCrypto.encryptToStream({required PlaintextSource source, required
  SecureKey key, int chunkSize = 64 * 1024, CancelCallback? cancel,
  ProgressCallback? onProgress}) → Stream<Uint8List>` — the full
  OS4S container as a stream (magic + enc_header_len + enc_header +
  ciphertext).
- `FileCrypto.decryptToStream({required Stream<Uint8List> ciphertext,
  required SecureKey key, CancelCallback? cancel, ProgressCallback?
  onProgress}) → Stream<Uint8List>` — inverse.

**Retired** (deprecated in phase 1, removed in phase 3):
- `encryptFileToTempFile` / `decryptFileToTempFile` — replaced by
  the stream variants. The temp-file staging was a mobile-only
  compromise; the streamed pipeline supersedes it on both platforms.

**Kept** (used for small in-memory operations like `enc_header`):
- `encryptFile` / `decryptFile` — in-memory `Uint8List` variants.

### Web-specific save behavior

Two paths, feature-detected at runtime:

**Chromium (Chrome, Edge, Opera, Brave, mobile Chrome)** — File System
Access API:
```js
const handle = await window.showSaveFilePicker({suggestedName: ...});
const writable = await handle.createWritable();
// stream chunks:
for (const chunk of decryptedStream) await writable.write(chunk);
await writable.close();
```
User picks the destination file; chunks stream directly to disk. No
memory ceiling beyond browser tab budget for buffered writes.

**Firefox / Safari** — `<a download>` blob fallback:
```js
const blob = new Blob(allChunks, {type: mime});
const url = URL.createObjectURL(blob);
// programmatic anchor click:
const a = document.createElement('a');
a.href = url; a.download = filename; a.click();
URL.revokeObjectURL(url);
```
Requires holding the entire plaintext in memory before download.
This constrains Firefox/Safari to whatever the tab's memory budget
allows (typically 1-2 GB per tab). User can't pick the destination;
file lands in browser's Downloads folder.

The choice is transparent to the caller — `BlobPlaintextDestination`
picks the right path via `navigator.storage` / feature detection.

### Cancellation, errors, browser-tab-close

- **Explicit cancel** (user taps a Cancel button): existing
  `CancelToken` propagates through the pipeline. Any in-flight PUT
  is aborted; `/abort` is POSTed to release R2's in-flight parts.
- **Network error mid-part**: retry the specific part up to N times
  (existing mobile retry logic). If retry fails, `/abort` + surface
  error.
- **Browser tab close**: web has no `beforeunload` guarantee for
  async I/O. We do NOT try to abort on close. The server's TTL
  sweeper (ADR-0012 server-side) cleans up abandoned multipart
  uploads within 6 hours. Same graceful degradation as mobile
  process-kill mid-send.
- **Memory pressure**: web tab getting close to its heap limit will
  throw during allocation. The 8-MiB part buffer is well within any
  modern browser's tab budget. The failure mode is "the specific
  part's PUT throws" → caught by the retry loop → surfaces as a
  send error.

## Consequences

### Wins

- **True parity**: web can send the same 10 GB file mobile can, with
  the same peak-memory profile.
- **Simpler mobile code path**: retiring the temp-file staging removes
  ~200 lines of `Directory`/`File`/rename dance. Fewer failure modes
  (partial-write cleanup, temp-dir permission issues).
- **Single pipeline to test**: encrypt-to-stream + interleaved upload
  is one path exercised on both platforms, not two forked
  implementations to keep in sync.
- **Cross-platform receive UX** matches paradigm expectations: web
  users get browser downloads; mobile users get their SAF/documents
  save picker.

### Trade-offs knowingly accepted

- **Retiring the mobile temp-file** means a receive-mid-transfer
  crash loses ALL downloaded ciphertext (no partial temp file to
  resume from). This was already the case for practical purposes
  (mobile did resume against R2 pre-signed URLs, not against the
  temp file). Documented in the receive-side ADR follow-up (phase 5).
- **Firefox/Safari can't stream saves**. Users on those browsers
  hit a soft file-size cap around the browser's tab-memory limit
  (~1-2 GB in practice). The UI surfaces this as "Chromium browsers
  support any size; on this browser, downloads over ~1 GB may fail"
  in the settings/help copy. Not a blocker for launch.
- **No resume-after-tab-close on web**. Documented above. If future
  demand justifies, look at `ReadableStream` in a service worker
  as the way in — deferred.
- **Bigger refactor than a web-only workaround**. The temptation
  was to fork the pipeline (mobile stays temp-file-based, web
  streams). Rejected because it creates two crypto paths, doubles
  the test matrix, and makes future changes twice as risky. The
  streaming path is strictly better; taking it as the single path
  everywhere is worth the mobile-side refactor cost.

### Test invariants that must not regress

- **Mobile 152/152 tests pass** at the end of every phase. Non-
  negotiable. If a phase breaks mobile, the phase is not shippable.
- **Ciphertext byte-equivalence**: for the same plaintext input +
  key, the new `encryptToStream` produces the same OS4S container
  bytes as the old `encryptFileToTempFile`. Locked in by a
  round-trip test at phase 2.
- **Receive-decrypt across platforms**: a file encrypted on mobile
  can be decrypted on web, and vice versa. Test in phase 6.

## Alternatives considered

### Web-only fork of the pipeline (mobile keeps temp files)

Rejected. Two implementations to maintain, doubled test matrix,
future crypto changes have to land twice. The streaming path is a
strict improvement on mobile too — the temp-file dance was a
workaround for the sodium API's earlier lack of a stream-out variant,
which it now has.

### Cap web at ~250 MB, use in-memory buffer

Rejected — this was the "Ultra-minimal v1" option in the scoping
discussion. Ships faster (~1.5 weeks) but leaves the biggest web
use case (send someone a big video / archive) as "install the
mobile app." Undercuts the whole reason to have a web app.

### `WebWorker`s + `SharedArrayBuffer` for parallel encrypt+upload

Rejected as v1 scope. Would let encrypt and upload run in parallel
threads, hiding CPU-bound sodium work behind network. Interesting
optimisation once we know throughput matters; sodium at ~70 MiB/s
on web is already fast enough that a 1 GB send takes ~15 s of
crypto (network typically slower). Revisit if profiling on real
devices shows the crypto is the bottleneck.

### Server-side proxy for web (server decrypts + sends)

Rejected — violates zero-knowledge. Non-starter.

### Native File System Access API only (Chromium-only web app)

Rejected. Firefox + Safari together are ~30% of desktop web browser
share; shipping "Chromium only" would exclude a meaningful
audience for no crypto-architecture reason. The `<a download>`
fallback works everywhere and is fine for the size range most
users hit.

## Open follow-ups

- **Phase 1** (`feat/web-send-1-plaintext-source`): introduce
  `PlaintextSource` abstraction; refactor mobile to use it. Zero
  behavior change. Existing tests green.
- **Phase 2** (`feat/web-send-2-encrypt-stream`): `FileCrypto.encryptToStream`.
  Ciphertext byte-equivalence test vs the existing temp-file variant.
- **Phase 3** (`feat/web-send-3-transfer-service`): interleaved
  encrypt+multipart-upload pipeline. Retire `encryptFileToTempFile`
  from the send path. Mobile flow switches to streaming.
- **Phase 4** (`feat/web-send-4-web-implementations`): `BlobPlaintextSource`,
  web send screen, first working web upload.
- **Phase 5** (`feat/web-receive-1-decrypt-stream`): mirror shape
  for receive. `FileCrypto.decryptToStream`, `PlaintextDestination`.
- **Phase 6** (`feat/web-receive-2-blob-save`): Chromium FSA vs
  `<a download>` fallback. Web receive screen. Cross-platform
  encrypt-on-mobile-decrypt-on-web test.
- **Phase 7** (`feat/web-send-receive-polish`): cross-browser QA,
  progress accuracy, cancel-in-flight, oversized-file error copy.
- **Batch send on web** — deferred. Revisit if a design partner
  asks for it.
- **Web tab-close resume** — deferred. `ReadableStream` in a
  service worker is the way in.
- **`WebWorker` parallel encrypt+upload** — deferred profiling
  exercise. Only worth it if crypto shows as the bottleneck on
  real devices.
