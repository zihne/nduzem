# ADR-0014 — Defer per-transfer crypto metadata from `/initiate` to `/commit`

Status: Accepted
Date: 2026-07-27
Amends: [ADR-0013](0013-web-send-receive-streaming.md)

## Context

ADR-0013 committed to a unified streaming pipeline for send across
mobile and web — encrypt-stream-per-chunk interleaved with multipart
upload, peak memory ≈ 8 MiB regardless of file size. The ADR sketched
the pipeline as:

```
Source → sodium.pushChunked → part accumulator → PUT to R2 → /commit
```

Implementation of Phase 3 (refactoring `TransferService.send` to use
`encryptToStream`) surfaced a constraint the ADR-0013 draft did not
account for: **the server's `/initiate` endpoint requires
`blob_sha256`, `enc_header`, `signature`, and (for app mode)
`wrapped_key` all up-front**. Concretely, `TransfersApi.initiate`
takes these as required parameters, the server stores them on the
`Transfer` row at initiate time, and the server's admin-blocklist
check (server ADR-0017) fires against `blob_sha256` at that point.

With streaming encryption, none of those four values is known until
the ciphertext stream has drained:

- **`blob_sha256`** — hash of the emitted ciphertext, computed
  incrementally as chunks emit. Undefined until the stream ends.
- **`enc_header`** — encrypted metadata blob that *contains*
  `blob_sha256`. So enc_header can only be built after the ciphertext
  stream drains. It's not just correlated with `blob_sha256`; it
  encloses it.
- **`signature`** — Ed25519 signature over `blob_sha256`. Same
  dependency chain.
- **`wrapped_key`** — actually independent of ciphertext hash; sealed
  to the recipient's `identity_pub`. Could theoretically stay at
  `/initiate`. But moving it alongside the other three keeps the
  contract symmetric.

The three viable strategies were considered:

1. **Move the four fields from `/initiate` to `/commit`.** Preserves
   the ADR-0013 streaming architecture and full parity with mobile.
   Requires server contract change.
2. **Web-only in-memory buffer** (mobile keeps temp-file). Retreats
   from full parity — web caps at ~250-500 MB. Faster to ship but
   contradicts ADR-0013's stated goal.
3. **Two-pass encryption** (encrypt once to compute hash, encrypt
   again to upload). Does not work — sodium's `init_push` uses a
   random header per call, so pass 2's ciphertext bytes differ from
   pass 1's, and the recipient's hash-check against `enc_header`
   fails. Off the table.

Two-pass being non-viable narrows the real choice to 1 vs 2.

## Decision

**Adopt strategy 1: move `blob_sha256`, `enc_header`, `signature`,
and `wrapped_key` from `/initiate` to `/commit`.** ADR-0013's
streaming pipeline stands; the API contract adjusts to accommodate it.

New `/initiate` payload:
```
POST /v1/transfers/initiate
{
  "mode": "app" | "link",
  "byte_count": <ciphertext size, computed from plaintext length>,
  "crypto_suite": 1,
  "max_downloads": 1,
  "recipient_id": "<uuid>",         // app mode only
  "recipient_email": "<blind-idx>",  // link mode only, optional
  "link_password": "...",            // link mode only, optional
}
```

New `/commit` payload:
```
POST /v1/transfers/{id}/commit
{
  "blob_sha256": "<hex>",
  "enc_header": "<b64>",
  "signature": "<b64>",
  "wrapped_key": "<b64>",   // app mode only
  "parts": [{"part_number": N, "etag": "..."}, ...]  // multipart only
}
```

**Ciphertext byte count at initiate.** The client precomputes
`byte_count` from `plaintext_length` using the deterministic
secretstream overhead formula:

```
ciphertext_len = magic_prefix (4)
               + secretstream_header (24)
               + ceil(plaintext_len / 64 KiB) * (64 KiB + 17 bytes)
               - (64 KiB - final_chunk_plaintext_bytes)  // last chunk shorter
```

The server uses this to size the multipart plan (number of parts,
per-part size) at initiate. If the actual uploaded object's byte
count doesn't match at `/commit`, commit rejects — same
integrity check that already exists today, just verified at
commit instead of initiate.

**Blocklist check moves from `/initiate` to `/commit`.** Server
ADR-0017's ciphertext-blocklist check happens after the ciphertext
is uploaded. Trade-off: a banned-content re-upload wastes R2
storage temporarily (until the sweeper reclaims), where today it's
rejected before the upload even starts. Acceptable because
blocklist hits are rare in practice and the temporary storage
cost is bounded.

**No signature-verification semantics change on the recipient side.**
The recipient's flow is unchanged:
1. Download ciphertext + enc_header + signature via `/download`.
2. Decrypt enc_header with K_file, read blob_sha256 out.
3. Compute sha256 of downloaded ciphertext, compare to enc_header's
   blob_sha256.
4. Verify signature against blob_sha256 with sender's signing_pub.

All four fields still flow through the server (stored on the
Transfer row, surfaced at `/download`) — just written at commit
instead of initiate.

**No client key-management change.** Sender still holds `signing_priv`
device-locally (client ADR-0011). Signature is still Ed25519 over
`blob_sha256`. Only the *timing* of that signature moves: computed
after the ciphertext stream drains (in the client's send pipeline)
rather than before `/initiate`.

## Consequences

### Wins

- **ADR-0013 streaming pipeline is fully achievable** — the "8-MiB
  peak memory on any platform" contract holds.
- **Web can send the same 10 GB files mobile can.** No web-specific
  size cap, no "install the app for large files" nudge.
- **Symmetric client-server contract.** `/initiate` = "reserve space,
  give me part URLs"; `/commit` = "here's what I actually
  uploaded, verify + persist." Cleaner mental model than the mixed
  responsibility today.

### Costs

- **Server API is a breaking change.** Old clients hitting the new
  server would fail; new clients hitting the old server would fail.
  Requires coordinated deploy.
- **Server ADR-0017 blocklist enforcement is best-effort at commit
  rather than eager at initiate.** Banned re-uploads consume R2
  bandwidth + storage briefly before rejection. Documented
  regression from today's behaviour; blocklist frequency in
  practice is low enough that this is acceptable.
- **Client Phase 3 depends on the server change landing first.**
  Adds ~1-2 weeks of server work (schema, endpoints, tests,
  deploy) before Phase 3 can be implemented.
- **In-flight transfers during the deploy window** — if a client
  calls the new `/initiate` against the old server, or vice versa,
  they fail. TTL is 6h; a rolling deploy in maintenance-window
  cadence keeps this small. Documented in the server ADR's rollout
  section.

### Explicitly non-goals of this amendment

- **No change to the recipient (`/download`) contract.** All four
  metadata fields still exit the server the same way.
- **No change to the sodium cryptographic primitives** — same
  secretstream, same signing algorithm, same key derivation.
- **No change to R2 storage keys or object naming.** Server still
  mints a random `storage_key` at `/initiate`; the object lands
  there regardless of when metadata arrives.

## Revised phase plan (supersedes ADR-0013's phase list for phases 3+)

- **Phase 2.5** (`fix/api-metadata-at-commit`, server repo):
  server contract change. `/initiate` schema drops the four fields;
  `/commit` schema gains them. Blocklist check moves. Tests. New
  server ADR-0037 documenting the change. **Blocking dependency for
  Phase 3.**
- **Phase 3** (`feat/web-send-3-transfer-service`, client): as
  originally scoped — refactor `TransferService.send` to use
  `encryptToStream` + interleaved multipart, but now with the
  metadata-at-commit call shape. Mobile's temp-file staging
  retires.
- **Phases 4-7**: unchanged from ADR-0013.

## Alternatives considered

### In-memory buffer on web only

Rejected — see decision above. Retreats from full parity; leaves
web as a "small files only" surface which undercuts the roadmap's
Workstream 3 goal.

### Two-pass encryption

Rejected — non-viable. sodium's `init_push` chooses a fresh random
header per encryption, so encrypting the same plaintext twice
produces different ciphertext. Any scheme that computes hash on
pass 1 and uploads on pass 2 would send bytes that don't match the
hash the recipient verifies against.

### Keep `blob_sha256` at `/initiate` but let it be a *promise* verified at `/commit`

Rejected. Would require the client to *pre-compute* `blob_sha256`
without doing the actual encryption — i.e., a deterministic
ciphertext hash without sodium. Not possible with the random-header
secretstream. Could theoretically be done with a plaintext-derived
"content hash" (client-side sha256 of the plaintext, unrelated to
ciphertext) but that's a different security property with different
implications for the recipient verification. Not worth the ADR
churn to invent a new integrity contract.

### Web-only fork of the server API (`/v2/transfers/initiate` for
web streaming, `/v1/...` unchanged for mobile)

Rejected. Would fork the contract, doubling the server test matrix
and the client's send-pipeline branches. Since mobile benefits from
streaming (retires the temp-file dance), moving both to the new
contract is strictly better than forking.

## Open follow-ups

- **Server ADR-0037** drafted alongside the server implementation
  branch. Documents the wire change + rollout plan + blocklist
  timing change.
- **Update ADR-0013's "phased branches" table** to insert Phase 2.5
  in front of Phase 3. Kept ADR-0013 as-is (append-only history)
  and reference this amendment from Phase 3 work items.
- **Deploy coordination**: the server change and the first client
  release that uses the new contract need to ship in a specific
  order (server first, wait for TTL grace, then client). Documented
  in the server ADR-0037 rollout section.
