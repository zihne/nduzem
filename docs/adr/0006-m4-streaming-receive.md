# ADR-0006: M4 client — streaming receive to disk

- **Status**: Accepted
- **Date**: 2026-07-04
- **Related**: [ADR-0003](0003-m4-client-multipart.md) (chunked
  secretstream + multipart wire), [ADR-0004](0004-m4-streaming-send.md)
  (streaming send from disk), server ADR-0012 (M4 backend)

## Context

ADR-0004 shipped streaming send: plaintext read from disk in 64 KiB
chunks, encrypted through secretstream into a temp ciphertext file,
uploaded from that file part-by-part. Peak memory ~8 MiB regardless
of file size. Multi-GB sends work.

Receive is still the M2/M3 in-memory model:

1. `GET` the presigned URL, receive **whole ciphertext** into a
   `Uint8List` in RAM.
2. Compute SHA-256 over the buffer (fine — walks the buffer).
3. Verify sender signature (unchanged).
4. Decrypt secretstream **whole buffer** → produce a `Uint8List`
   plaintext.
5. Hand the plaintext bytes to the receive screen; screen calls
   `file_picker.saveFile(bytes: X)` for the user's picked destination.

Peak memory: **~2 × file size** (ciphertext + plaintext held
simultaneously). A 3 GB file wants 6 GB of heap — out of reach on any
phone. This is the symmetric gap that streaming send closed on the
sender side.

Two design questions:

1. **How do we hand the plaintext to the OS's document picker
   without buffering it whole?** `file_picker.saveFile` on Android
   still only accepts `bytes: Uint8List` (as of `file_picker` 8.3.7).
   A true zero-memory SAF save requires either a plugin swap or
   native platform-channel work.
2. **What are the phase boundaries for the progress UI?** Send has
   `SendPhase.encrypting → preparing → uploading`. Receive needs
   the same three-phase story.

## Decision

### Streaming download + streaming SHA-256 + streaming decrypt

`TransferService.receive` becomes:

1. `POST /v1/transfers/{id}/download` → get the presigned URL,
   envelope, sender pubkeys, blob_sha256 (unchanged).
2. **Streaming download**: `http.Client.send(GET request)` returns a
   `StreamedResponse`. Iterate `response.stream` chunks, write to a
   temp ciphertext file on disk, feed each chunk into a
   `sha256.startChunkedConversion` hasher. Report progress after
   each read.
3. **Verify the rolling SHA-256** against the server-reported
   `blob_sha256`. Mismatch → hard-fail before any decryption CPU
   is spent.
4. **Verify sender signature** (unchanged, uses the recomputed hash
   from the header).
5. Read `wrapped_key`; unseal to K_file (unchanged, tiny).
6. Decrypt the `enc_header` (unchanged, tiny).
7. **Streaming decrypt**: `FileCrypto.decryptFileToTempFile(ciphertextPath,
   K_file)` — mirror of `encryptFileToTempFile`, reads the ciphertext
   temp file chunk-by-chunk, feeds `secretStream.pullChunked`, writes
   plaintext chunks to a plaintext temp file. Report progress after
   each chunk.
8. Return a `DecryptedTransfer` carrying **`plaintextPath`** (not
   bytes) plus metadata.
9. Delete the ciphertext temp file on the way out; plaintext temp
   file lifetime is owned by the caller (receive screen).

Peak memory during download + decrypt ≈ **one 64 KiB chunk** +
stream overhead. Symmetric to send-side ADR-0004.

### Save step still reads bytes into memory

`ReceiveScreen._saveAs` reads the plaintext temp file into memory
(`readAsBytes`), hands to `file_picker.saveFile(bytes: ...)`. Peak at
save-time = plaintext size.

Deliberate tradeoff, not a design win:

- `file_picker` 8.3.7 has no path-based `saveFile` API. Its Android
  backend accepts `bytes` only.
- True streaming-save-into-SAF-picked-destination requires **either**
  a plugin that exposes `openOutputStream` (none we've evaluated
  meets the bar today) **or** native Kotlin/Swift code we write
  ourselves.
- Both add scope disproportionate to the immediate need. This branch
  fixes the **download + decrypt** OOM (the failure most users hit
  first) and leaves the **save** OOM for a follow-up branch.

**Practical envelope**: on a phone with a 512 MB per-app heap,
plaintext up to ~200 MiB saves reliably via SAF; beyond that, expect
occasional OOM at the save step. Post-fix, users can receive up to
~200 MiB reliably (vs. the current ~50-80 MiB effective cap because
of the double-buffer). Multi-GB safely lands with the future native
SAF stream-write branch.

The receive screen surfaces a warning banner when the incoming
plaintext exceeds a threshold (200 MiB) so the user isn't surprised
by an OOM at the save step.

### `ReceivePhase` enum for progress

```
enum ReceivePhase { downloading, decrypting }
```

`onProgress(phase, done, total)`:

- `downloading`: `done` = ciphertext bytes received, `total` =
  ciphertext length (from `Content-Length` header, falls back to
  `byte_count` from the download response envelope).
- `decrypting`: `done` = plaintext bytes written, `total` =
  `plaintext_length` from the decrypted header.

Rate-limited to ~250 ms callbacks per phase (same as send).

### Temp file management

- **Ciphertext temp file**: created at download start, deleted after
  decrypt completes or fails. `finally` block owns cleanup.
- **Plaintext temp file**: handed to the receive screen; owned by it
  until save-then-ack succeeds. Screen deletes on:
  - Successful ack (canonical happy path).
  - User cancels the save-as dialog after a successful decrypt.
  - Error during save.

If the process is killed between decrypt and ack, the plaintext temp
file survives in the OS temp dir. Not ideal but not a data-loss
event — the transfer is still on the server, user can re-receive.
Android's own temp-dir sweeping is the backstop.

### No functional changes to link-mode receive

Link-mode client-side receive doesn't exist yet in the Flutter app
(the web decrypt page owns that surface). The service's link-mode
check (`wrappedKeyB64 == null → throw`) stays. This branch is
purely about the app-mode receive path.

## Consequences

- **Practical receive ceiling jumps ~5-10×.** From ~50 MB (hard OOM
  cap) to ~200 MB (SAF save cap). The download + decrypt phase is
  effectively unbounded — bounded only by disk space for two temp
  files (ciphertext + plaintext during decrypt).
- **Disk usage during receive** peaks at plaintext + ciphertext =
  ~2 × file size (both temp files live simultaneously during the
  decrypt phase). Reclaimed after ack. Android's cache dir is
  auto-reclaimed under storage pressure.
- **Progress UI is now two-phase** on the receive screen — clear
  "Downloading N%" and "Decrypting M%" states. Same visual pattern
  as send.
- **`DecryptedTransfer.plaintext` (Uint8List) is gone.** Replaced by
  `plaintextPath` (String) and `plaintextLength` (int). Callers that
  need the bytes read them explicitly. Cleaner separation — the
  service delivers a file, not a buffer.
- **Save step is the residual OOM risk.** Documented, banner-warned,
  and slated for a follow-up branch that writes directly through a
  SAF URI.
- **Cleanup discipline is stricter** now that there are two temp
  files per receive. The tests cover the common paths (success,
  cancel, error). A crashed process leaves ≤1 file per killed
  receive; OS temp cleanup handles the accumulation.

## Alternatives considered

- **Ship native SAF stream-write in this branch.** Would eliminate
  the save-time OOM entirely. Rejected for scope — it's a
  platform-channel task that deserves its own branch and test story.
  This branch already delivers the biggest single memory win.
- **Save to `getExternalStorageDirectory()` for big files, SAF for
  small.** Would technically work: streaming decrypt directly into
  `<external>/Downloads/<filename>` sidesteps `file_picker` for
  big files. But the UX asymmetry ("small files ask where to save;
  big files just land somewhere") is confusing. Deferred until we
  have real user data on the size distribution.
- **Add a `share_plus` "Share the file" action** as the exit ramp
  for big files. Nice touch, but requires a plugin dep and doesn't
  address the "user wants to keep this file" case. Save-and-move
  is better UX; skip for v1.
- **Stream decrypt in an isolate** to keep the UI thread free during
  a multi-minute decrypt. Reasonable for very large files; deferred
  until we see UI stalls in the wild. Send didn't need it; receive
  probably won't either.
- **Feed the download stream directly through `pullChunked` without
  a temp file**. Would eliminate the ciphertext temp file. Rejected
  because SHA-256 verification MUST happen BEFORE decrypt (per the
  M4 wire contract), and the streaming hasher only tells us the
  final digest at close time. Two-pass over the stream isn't
  possible without buffering. The temp-file design is correct.
- **`http` package's `readAsBytes()` for backward compat as a
  fallback.** Would mask the migration. Rejected — one code path
  is easier to reason about and the streaming path handles small
  files fine.

## Open follow-ups

- **Native SAF stream-write** on Android + iOS (`URLSession`
  `downloadTask` on iOS or a small platform-channel bridge) for
  true multi-GB save-to-user-picked-destination.
- **Resume from partial-download** on interrupt — presigned GET
  URLs live 10 minutes (`presign_ttl_seconds`); resume within that
  window via HTTP Range headers.
- **Streaming decrypt in an isolate** for very large files if UI
  stalls become visible.
- **In-app link-mode receive** (independent branch — matches the
  web decrypt page but for users who tapped the URL on a device
  with the app installed).
