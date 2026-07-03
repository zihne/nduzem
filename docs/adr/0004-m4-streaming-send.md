# ADR-0004: M4 client — streaming send from disk

- **Status**: Accepted
- **Date**: 2026-07-03
- **Related**: [ADR-0003](0003-m4-client-multipart.md) (M4 chunked
  secretstream + multipart wire integration), server ADR-0012 (M4
  backend), spec §5.2, §5.4

## Context

ADR-0003 shipped chunked `crypto_secretstream_xchacha20poly1305` +
multipart wire integration, but explicitly kept an in-memory
send model: the whole plaintext and the whole ciphertext are held
in `Uint8List` buffers throughout the send.

That kept the diff small but capped realistic uploads. The 71 MB
zip that OOM-killed the app on Android was the concrete demonstration
— even after `fix/m4-large-file-memory` dropped peak from ~270 MB to
~150 MB (pre-sized ciphertext buffer + `withData: false` on the
picker), a 500 MB or larger send still can't fit the two buffers in
a phone's per-app heap. M4 backend supports 10 GiB transfers; the
client needs to actually reach that ceiling for the milestone to
mean anything.

The follow-up ADR-0003 flagged is streaming send from disk: read
plaintext in 64 KiB chunks, feed through secretstream, write to a
temp file, then read that temp file part-by-part on upload. This
branch delivers exactly that.

Design questions:

1. **Where does the ciphertext go while we compute `blob_sha256`?**
   The wire order is `initiate → PUT parts → commit`, and `initiate`
   needs `blob_sha256` up-front. secretstream is stateful and
   non-deterministic (fresh header per encrypt), so we can't
   "encrypt-then-hash-then-encrypt-again" — the second ciphertext
   won't match.
2. **Where does the temp file live?** `path_provider`'s temp dir is
   the obvious choice, but iOS caches directory may or may not
   survive an app kill, and Android temp behaviour differs across
   OEMs.
3. **How does the UI show progress across two phases (encrypt vs
   upload)?**
4. **What happens if the send fails mid-encryption?**

## Decision

### Encrypt-and-hash into a temp file first

Two-stage flow:

**Stage 1 — encrypt to disk + rolling SHA-256**:
- `FileCrypto.encryptFileToTempFile(plaintextPath, key, tempDir?)`
  opens the source path as `Stream<List<int>>`, feeds through
  `secretStream.pushChunked`, writes each ciphertext chunk to a
  temp file, and feeds each ciphertext chunk into a chunked SHA-256
  hasher.
- Return: `{ciphertextPath, ciphertextLength, blobSha256Hex}`.
- Peak memory: ~64 KiB (one secretstream chunk) + I/O buffers. Zero
  copies of the plaintext or ciphertext held whole.

**Stage 2 — upload the temp file part-by-part**:
- Open the temp file as `RandomAccessFile`.
- For each part in the multipart plan: `setPosition(offset)`,
  `read(partSize)`, PUT, capture ETag.
- For single-shot: `readAsBytes()` — file is < 5 MiB by definition,
  fits in memory trivially.
- Commit with the ETag list.
- Delete the temp file regardless of success or failure.

Peak memory during upload: ~8 MiB (one part buffer). Delete happens
in a `finally` so a crashed process leaves at most one abandoned
temp file, cleaned up by the OS's temp-dir sweep.

### Temp dir: `path_provider.getTemporaryDirectory()`

Real path (`/data/data/<pkg>/cache` on Android, `NSTemporaryDirectory`
on iOS). Both OSes can (and do) reclaim these under storage pressure
— not a concern during an in-flight send since the file is opened
and read-locked for the encryption window, and again for the upload
window.

For tests, `encryptFileToTempFile` takes an optional `tempDir`
override so pytest-style setups pass a controlled directory
(usually `Directory.systemTemp` on Linux). The service passes
`path_provider`'s value in production.

### Two-phase progress: `SendPhase` enum

`onProgress` grows from `(uploaded, total)` to
`(phase, done, total)`:

- `SendPhase.encrypting` — done = plaintext bytes read so far, total
  = plaintext byte count.
- `SendPhase.uploading` — done = ciphertext bytes PUT, total =
  ciphertext byte count.

The UI shows a phase label and a determinate bar per phase. The
"initiating" API call between phases is fast enough (< 1 s
typically) that a phase for it would add UI churn without value —
we surface it as "Preparing…" with an indeterminate bar for the
few frames it takes.

Cancel handling is unchanged: `CancelToken.throwIfCancelled()` is
checked in the stream `.map` of the encrypt-phase plaintext read
AND between part PUTs. Cancel mid-encryption throws → temp file
cleaned in `finally`; cancel mid-upload throws → `/abort` posted
+ temp file cleaned. Either way the process gets back to a clean
state.

### API cutover on `TransferService.send`

Old signature took `plaintext: Uint8List`. New signature takes
`plaintextPath: String, plaintextLength: int`. The screen no
longer reads the file into memory at pick time — it stores the
path and metadata; the send flow does the read from disk directly.

`send_screen.dart` was already using `withData: false` (from
`fix/m4-large-file-memory`), so the pick path never allocates
plaintext. The refactor removes the `File.readAsBytes()` we were
doing after the pick — now it happens streamed inside the service.

### Not in this branch

- **Streaming receive to disk.** `file_picker.saveFile` on Android
  wants `Uint8List bytes` — there's no streaming-write API against
  a SAF-picked destination. A separate follow-up either finds a
  workaround (temp-file + `bytes:`, or plugin-level SAF write) or
  accepts the temporary "keep decrypt in memory" limit on receive.
  See ADR-0003's open follow-ups.
- **Resume from last-good-part.** Presigned URLs live only 1 hour;
  useful for genuinely flaky uploads but not urgent.
- **Per-byte progress within a part.** Would require
  `http.Client.send` + `StreamedRequest` gymnastics for a
  marginal UX gain (parts are 8 MiB — a tick per part is fine).
- **Encryption in an isolate.** For very large files, chunk-by-chunk
  FFI calls on the main isolate can block the event loop. Not seen
  as a practical issue yet at typical file sizes; if it becomes
  one, move `pushChunked` into `Isolate.run`.

## Consequences

- **Multi-GB uploads become physically possible.** Peak memory is
  ~one secretstream chunk + one part buffer + Dart's ambient
  overhead — around 10-15 MiB total. A 5 GiB upload works with the
  same footprint as a 5 MiB upload.
- **Disk usage during a send: ~1× plaintext size** while the
  ciphertext temp file exists. Freed after commit (or abort). On
  Android's cache dir, the OS reclaims automatically under storage
  pressure — the send can fail mid-upload if cache is aggressively
  reclaimed, but that's better than pre-purchase silent OOM.
- **Roundtrip crypto correctness preserved.** The streaming
  encrypt-to-temp-file produces the same ciphertext format as the
  in-memory `encryptFile` — same OS4S container, same secretstream
  chunks, same SHA-256. New tests check that a streaming-encrypt
  round-trips through the in-memory decrypt.
- **`SendPhase` broadens the `onProgress` callback.** UI code that
  ignores the enum keeps working (it's an added parameter, not a
  replacement); UI code that cares gets cleaner separation between
  "encrypting" and "uploading".
- **Temp files are best-effort cleaned.** In-process failures hit
  the `finally` block. A process kill (OS OOM, user force-quit)
  can leave the file behind; the OS's own cache reclamation is the
  backstop. No production issue but worth noting.
- **The old `FileCrypto.encryptFile` stays** as the in-memory path.
  Kept for tests and as a fallback for any future caller that has
  bytes in hand. Callers on the send path use
  `encryptFileToTempFile` exclusively.

## Alternatives considered

- **Streaming through `StreamedRequest` for single-shot upload.**
  Would avoid the `readAsBytes()` on single-shot. Rejected — under
  the 5 MiB threshold the memory difference is trivial and it
  complicates the code.
- **Encrypt-then-upload interleaved (no temp file).** Would use
  even less disk but requires encrypting the entire ciphertext
  before we know the total byte_count for `initiate` — the wire
  order doesn't permit that unless we buffer everything back in
  memory. Rejected.
- **Compute `blob_sha256` speculatively during a first "hash-only"
  pass.** Would let us skip the temp file: hash-only pass to get
  `blob_sha256`, then real encrypt-upload pass. Rejected — as
  noted in Context, secretstream is non-deterministic across
  runs, so the ciphertext of the second pass wouldn't match the
  first pass's hash.
- **Isolate for the whole send pipeline.** Would unblock the UI
  during encryption CPU work but multiplies communication
  complexity. Save for when UI freezes are actually reported.
- **Store the temp file in the app-documents dir** so it survives
  process restarts (enabling resume). Deferred — resume-from-part
  is a separate follow-up with its own state design.
- **Keep the old `encryptFile` as a private helper only.** Kept
  public because tests use it directly, and future callers with
  bytes in hand shouldn't need a temp-file dance.

## Open follow-ups

- **Streaming receive to disk** — the mirror image; solving the
  `file_picker.saveFile` streaming problem is the interesting
  part.
- **Resume from last-good-part** — persist upload state to secure
  storage; on next open, resume from the next unfinished part
  within the 1-hour presign TTL.
- **Encryption in an isolate** — if UI stalls during encryption
  become user-visible on very large files.
