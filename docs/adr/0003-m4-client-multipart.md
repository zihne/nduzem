# ADR-0003: M4 client — chunked secretstream encryption + multipart upload

- **Status**: Accepted
- **Date**: 2026-07-03
- **Related**: server ADR-0012 (M4 backend multipart), spec §5.2, §5.4
  (chunked encryption), [ADR-0001](0001-m1-client-architecture.md)
  (client stack)

## Context

M2 shipped the single-shot transfer loop. Any file larger than
`MULTIPART_THRESHOLD_BYTES` (5 MiB, the R2 minimum) causes the server
to return a `multipart` plan on `/initiate` instead of an
`upload_url`; the M2 client hard-errored with
`"Server returned a multipart plan; M2 client only handles single-shot
PUT uploads"`. This blocked every real-world use case (photos,
videos, exports).

M4 backend (server ADR-0012) shipped the presigned per-part URLs, the
`/commit` parts-list contract, and `/abort` for client-initiated
cleanup. All we need on the client is:

1. Stop rejecting multipart responses.
2. Split the ciphertext into part-sized chunks, PUT each, capture the
   ETag Play returns per part.
3. Send the ETag list on `/commit`.
4. POST `/abort` when the user cancels or the flow errors mid-upload.
5. Progress reporting so multi-minute uploads don't look frozen.

The current ciphertext format is `nonce || crypto_secretbox_easy(plaintext)`
— the whole file in a single AEAD message. libsodium's secretbox
recommends splitting messages above ~1 GB, and future streaming
decrypt (spec §5.4) requires per-chunk authentication anyway. So we
also swap the file body's format to `crypto_secretstream_xchacha20poly1305`
(the streaming AEAD libsodium designed exactly for this use case) as
part of the same branch — receive path has to change to match.

Design questions:

1. **Chunk size for secretstream?** Trade off ciphertext framing
   overhead against per-chunk memory + CPU.
2. **How does the receiver know the format?** With M2's raw
   secretbox and M4's secretstream both on the wire, a running
   receiver could see either.
3. **Where's the natural progress-reporting seam?** Per-part PUT is
   the coarsest signal; per-byte-uploaded is nice-to-have but
   requires `http` package internals.
4. **What breaks if the user cancels mid-upload?** R2 charges for
   in-flight multipart parts indefinitely until `abort` or the
   server's 6-hour orphan-sweeper (server ADR-0012) reclaims them.
5. **What's still buffered in memory in this branch?**

## Decision

### Chunked secretstream for the file body

Switch `FileCrypto.encryptFile` / `decryptFile` to
`crypto_secretstream_xchacha20poly1305`. Ciphertext layout:

```
[4-byte magic "OS4S"] [24-byte secretstream header] [chunk_1_ct] ... [chunk_N_ct]
```

- **Magic prefix** `OS4S` (OpaqueShare 4 Streaming) is a
  self-identifying byte marker so the receiver can hard-fail cleanly
  ("this looks like an M2-secretbox ciphertext, not M4-secretstream")
  rather than emit a mysterious decryption error. The 4 bytes are
  effectively free relative to a >5 MiB file.
- **Chunk size**: 64 KiB plaintext per chunk (65536 bytes → 65553
  bytes ciphertext, +17 bytes AEAD overhead per chunk). 64 KiB is
  small enough to keep the memory footprint per chunk trivial and
  large enough that the overhead ratio (0.026%) is negligible on
  multi-GB files.
- Last chunk carries `SecretStreamMessageTag.finalPush`; all others
  carry `.message`. Receiver hard-fails if the last chunk isn't tagged
  final (defence against truncation).
- `enc_header` (the JSON metadata blob: filename, mime, size,
  blob_sha256) stays on `crypto_secretbox_easy`. It's a few hundred
  bytes; streaming buys nothing there.

### Format cutover, no M2 backward compat

New sends emit the OS4S format; new receives expect it. An M2 client
receiving an M4 ciphertext gets a decryption failure (they don't know
about the magic prefix). An M4 client receiving an M2 ciphertext gets
a clear `"ciphertext missing OS4S magic — was this uploaded by an
older client?"` error rather than a mysterious AEAD failure.

Cutting over rather than dual-supporting M2 keeps the receive path
simple. In-flight M2 transfers in dev environments will fail; in prod
there are no M2 users yet.

### Multipart send: chunk ciphertext to part boundaries

`TransferService.send` now:

1. Encrypts the whole plaintext into a single in-memory ciphertext
   buffer (streaming-ready format, but the buffer itself is not
   streamed in this branch — see "Not in this branch" below).
2. Calls `/initiate`, gets either single-shot or multipart response.
3. **Single-shot** (M2 path, byte_count ≤ 5 MiB): unchanged, one PUT
   to `upload_url`, then `/commit` with no body.
4. **Multipart** (byte_count > 5 MiB): sequentially PUTs each part
   from a byte range of the ciphertext buffer to
   `multipart.parts[i].url`. Captures the response `ETag` header per
   part. Emits progress callbacks after each part. Then `/commit`
   with the parts list.

Part boundaries fall wherever `multipart.part_size` (8 MiB) says —
they don't align with the 64 KiB secretstream chunk boundaries and
they don't need to (each part is opaque bytes to R2; the receiver
gets the full concatenated ciphertext back on GET).

### Send-side abort discipline

If the user cancels, or any step after `/initiate` throws, we POST
`/abort` before propagating. This tells the server to
`AbortMultipartUpload` on R2 immediately rather than waiting for the
6-hour orphan-sweeper. Idempotent per server ADR-0012, so a
double-abort on race conditions is safe.

The service exposes cancel as a `CancelToken` object the UI holds
and can flip; the send loop checks between part PUTs (coarse but
sufficient — user-triggered cancels don't need per-byte reaction).

### Progress reporting: per-part callback

`send()` takes an optional `TransferProgress? Function(int
uploadedBytes, int totalBytes) onProgress` callback. Fires after each
part upload with `(sum_of_uploaded_parts, ciphertext_length)`.

Per-byte progress within a part would require reaching into the
`http` package's streamed request body — worth doing eventually but
not in this branch. Per-part granularity gives us at least ~1000 tick
updates for a 10 GiB upload with 8 MiB parts, which is fine.

### Receive: streaming decrypt

`FileCrypto.decryptFile` now:

1. Checks the magic prefix. Non-`OS4S` → clear error.
2. Extracts the 24-byte header.
3. Iterates remaining bytes in fixed 65553-byte ciphertext chunks
   (final chunk may be smaller). Feeds through
   `SecretStream.pullChunked` for chunked authenticated decryption.
4. Concatenates the plaintext chunks into a single `Uint8List`.

The download itself is still one HTTP GET of the whole ciphertext —
streaming the download to disk while decrypting is a future
optimization once we ship `path_provider`-backed temp files. See
"Not in this branch" below.

### Not in this branch (future work)

- **True streaming send from disk**: `file_picker` gives us
  `PlatformFile.bytes` for small files or `.path` for larger ones.
  A future branch reads the path in 64 KiB chunks, feeds
  `SecretStream.pushChunked`, and streams the ciphertext directly
  into per-part PUT bodies without ever holding the whole ciphertext
  in memory. Requires per-part progress + `http.Client.send`
  gymnastics.
- **True streaming receive to disk**: mirror image on the receive
  side — GET the ciphertext into a temp file, streaming-decrypt to
  the user-picked SAF destination.
- **Resume-from-last-good-part on interrupt**: persist the parts-so-far
  list to secure storage, resume from the next unfinished part on
  next app open. Presigned part TTL is 1 hour (server ADR-0012), so
  interrupts beyond that require re-`/initiate`.
- **Per-byte upload progress within a part**.

## Consequences

- **Large files work.** Any file up to the server's 10 GiB cap now
  uploads successfully; receive-side decryption reads the same
  streaming format regardless of size.
- **Streaming-ready ciphertext format.** The OS4S container matches
  what a fully-streaming send/receive would emit, so future memory
  optimizations don't change the wire format again.
- **Memory usage in this branch: still O(plaintext + ciphertext).**
  A 500 MiB upload uses ~1 GiB of RAM peak — plaintext + secretstream
  output buffer. This is enough for the phone-camera-photo use case;
  multi-GiB uploads from a phone need the "streaming from disk"
  follow-up.
- **Per-chunk authenticated integrity.** A ciphertext with a
  corrupted byte fails cleanly at the affected 64 KiB chunk instead
  of after decrypting the whole file with M2's monolithic Poly1305
  tag.
- **Cancels are cheap.** POST /abort promptly frees R2 in-flight
  storage on the server side; the 6-hour orphan sweeper becomes a
  belt-and-braces backstop rather than a required cleanup path for
  the common case.
- **Progress bar UX.** The send screen shows a per-part progress
  indicator. On the fast local dev backend this is instant; on real
  network it'll show meaningful ticks for anything > ~40 MiB
  (~5 parts).
- **M2 in-flight transfers break.** Only relevant to dev
  environments; no production users on M2 format.
- **~0.026% ciphertext overhead vs M2** (17 bytes AEAD tag per 64
  KiB chunk plus a 24-byte header plus a 4-byte magic prefix).
  Insignificant relative to network variance.

## Alternatives considered

- **Per-part re-initialize the secretstream.** Would let us align
  encryption boundaries with multipart part boundaries, so a
  per-part upload could stream through the AEAD in one pass.
  Rejected: it breaks the AEAD contract (part 2's chunks
  authenticated against a fresh key + header would let an attacker
  reorder parts undetected). The single secretstream + arbitrary
  part chunking is the correct construction.
- **Variable-length chunk framing** (`u32 chunk_len || chunk_ct` per
  chunk). Cleaner protocol at ~4 bytes per chunk overhead, but the
  fixed-size scheme costs nothing extra when the receiver knows the
  chunk size and can slice directly. Skipped for simplicity.
- **Drop the magic prefix.** Would save 4 bytes per transfer.
  Rejected — the debuggability of "clear error on M2/M4 mismatch"
  vastly outweighs the byte cost.
- **Use `sodium_libs`' `pushChunked` / `pullChunked` stream helpers
  directly in `TransferService`.** They're the "right" async API but
  the stream plumbing makes the send/receive code much more
  branching-heavy than a synchronous encrypt-then-multipart. We
  reserve the stream API for the "streaming from disk" follow-up
  when it's actually load-bearing. In this branch, `pushChunked`
  wraps an in-memory single-shot plaintext feed and we gather the
  ciphertext.
- **Ship multipart wire-integration only, defer secretstream to a
  later branch.** Simpler diff but leaves the file format on
  secretbox — the receive path would have to switch formats again
  when secretstream lands, breaking any in-flight transfers a second
  time. Doing both together is one migration for users.
- **Encrypt each multipart part as its own crypto_secretbox message.**
  Rejected for the same reason as "per-part re-initialize
  secretstream": breaks the ordered-AEAD contract that stops part
  reordering / dropping attacks.
- **Ed25519 sign each part instead of the whole `blob_sha256`.**
  Would let us verify each part on arrival, at the cost of N
  signatures instead of 1 and per-part sender-pubkey wire changes.
  Rejected — the SHA-256 of the concatenated ciphertext already
  authenticates the whole blob, and secretstream's per-chunk AEAD
  detects any byte-level corruption anyway.

## Open follow-ups

- **Streaming send from disk** — read `file_picker`'s path in
  chunks, feed `pushChunked`, stream ciphertext into part PUT
  bodies. Enables multi-GB uploads from phones without a giant RAM
  spike.
- **Streaming receive to disk** — mirror image on the recipient
  side.
- **Resume from last good part** — persist multipart upload state
  locally; on next app open resume from the last successful part.
- **Per-byte progress within a part** — via `http.Client.send` +
  streamed body.
- **`/refresh-parts` on part-URL expiry** — server ADR-0012's
  deferred endpoint for re-presigning specific part numbers
  mid-upload without restarting the multipart.
