# ADR-0007: Client-side local transfer history

- **Status**: Accepted
- **Date**: 2026-07-04
- **Related**: [ADR-0005](0005-m5-link-mode-sender.md) (link sender
  UX referenced the "no history" gap in the completion dialog),
  [ADR-0006](0006-m4-streaming-receive.md) (receive UX)

## Context

Today the client has no persistent record of past transfers. The
send-complete and receive-ack dialogs both included a "here's the
transfer id, we don't remember it for you" hedge because there was
no history surface to defer to. Users who want to answer "did that
5.7 GiB send actually succeed?" or "what was the URL I created for
Bob last Tuesday?" have no path.

A local, on-device history plugs that gap. Two design questions:

1. **What do we persist for each entry?** Enough to answer
   "what happened, when, to what file, with whom" — without
   redundantly storing content-key material.
2. **Where does the history live?** Options: sqlite via `sqflite`
   (proper DB, real dependency), a JSON file in app-documents,
   or `SharedPreferences`. Trade off durability, dependency
   surface, and query needs.

## Decision

### Data model: sealed `TransferHistoryEntry` with two variants

```dart
sealed class TransferHistoryEntry {
  String transferId;
  DateTime timestamp;
  String filename;
  int sizeBytes;
}

class SentHistoryEntry extends TransferHistoryEntry {
  String mode;               // 'app' | 'link'
  String? recipientLabel;    // email/handle typed by sender, null for link
  int maxDownloads;          // link mode; 1 for app mode
  bool hasPassword;          // link mode
}

class ReceivedHistoryEntry extends TransferHistoryEntry {
  String? senderIdShort;     // 8-char UUID prefix, null in link mode
  String? senderHandle;      // if server surfaced one
  bool signatureVerified;    // recorded per ADR-0031
  String? savedPath;         // where the user actually saved it
}
```

### Explicitly NOT persisted

- **K_file / URL fragment for link sends.** The URL fragment IS the
  decryption key. Persisting it means an attacker who compromises the
  device gets replay access to every past link transfer. Sender is
  prompted to copy the URL at send time (ADR-0005) — that's the
  single point where it exists in cleartext outside encrypted
  storage. History records "you sent this file as a link" without
  the key.
- **`recipient_email` (link mode invite target).** Blind-indexed
  server-side; would need to be plaintext locally to be useful. Not
  worth the disclosure risk for a UI feature no one's asked for yet.
- **The full sender pubkey / signing pub.** Fingerprint and
  short-id give the same identifiable value with much less on-disk
  surface.

### Storage: JSON file in app-documents dir

`getApplicationDocumentsDirectory()/transfer_history.json`, one write
per mutation, atomic-replace pattern (write to `.tmp`, rename over
the target).

Why JSON over sqflite:

- Query needs are trivial: chronological list, filter by direction,
  optional cap. No joins, no indexes, no aggregations.
- Dependency surface: `sqflite` pulls in native SQLite plus a
  plugin. `path_provider` is already a dep.
- Volume: capped at 200 entries × ~500 bytes each ≈ 100 KB — well
  under any reasonable JSON parse hot-path.
- Migration story: adding a field means bumping a schema version
  int in the file header and defaulting missing fields. Simpler
  than an sqflite migration.

Why JSON over `SharedPreferences`:

- SharedPreferences is a single-blob key-value store, and on Android
  it's synchronous on the Java side, prone to ANR on writes. Using
  it for a growing JSON blob works but wastes ergonomics.
- `path_provider` is here already; one more file is trivial.

### 200-entry rolling cap

New entries pushed to the front; oldest evicted when count exceeds
200. Two hundred entries ≈ 100 KB of JSON — negligible. A settings
screen (M9.x) can later expose "clear history" and a knob for the
cap.

### Where the write happens

Screens (not the service) call the repository:

- `SendScreen` on successful `send()`: appends a `SentHistoryEntry`
  before showing the completion dialog.
- `ReceiveScreen` on successful `_ack()`: appends a
  `ReceivedHistoryEntry` after the burn.

Rationale: the service is transport / crypto; the screen owns the
"and now log it in the user's history" concept. Keeps the service
free of another repository dependency, keeps the write conditional
on user-visible success (not just server-accepted).

### `AsyncNotifierProvider<TransferHistory, List<TransferHistoryEntry>>`

Riverpod provider that:

- On `build`, reads the JSON file and returns the sorted list.
- Exposes `log(entry)`, `remove(transferId)`, and `clearAll()`
  imperatively.
- Emits fresh state after each mutation so the history screen
  rebuilds.

### UI: one merged chronological screen

Route `/history`. Home screen gets a "Transfer history" button
between "Verify a contact" and "Storage & credits". The screen
shows all entries sorted newest-first, icon differentiating
sent (`Icons.upload`) vs received (`Icons.download`). Tap → detail
dialog with the transfer_id (selectable) and any variant-specific
fields.

Not in v1:

- Filter/search UI. With ≤ 200 entries, scrolling suffices.
- Grouping by day / week.
- Re-send / restore-link actions.
- Export to CSV.

## Consequences

- **Users can answer "did that transfer land"** without checking
  their inbox on the recipient's device or asking the operator.
- **Fingerprint of past behaviour lives on-device.** If the device
  is stolen and unlocked, the attacker learns filenames and
  recipient labels for the last 200 transfers. Acceptable —
  the device already stores the private key + email + handle;
  history is not the top-of-list disclosure.
- **`SendScreen` / `ReceiveScreen` grow one repository dep each.**
  Small; matches the pattern used for `verifiedContactsRepo`.
- **The completion dialogs' "transfer_id shown so you can debug"
  wording can be softened** in a follow-up — the id is now
  recoverable from history.
- **No K_file / URL is on disk.** If a user loses the URL they
  copied, the sent file becomes irretrievable until re-shared. This
  is the same as before; history doesn't degrade or improve that
  posture.

## Alternatives considered

- **sqflite.** Overkill; the query surface is trivially served by
  a JSON list.
- **`SharedPreferences`.** Works but wastes the growing-blob pattern
  it's not designed for.
- **`hive`.** Popular Flutter key-value store; adds a dependency
  for no query benefit over a raw file.
- **Persist the link-mode share URL** so users can re-paste. Real
  usability win, real disclosure risk. Deferred until user demand
  proves it worth the tradeoff.
- **Log in the service.** Would give us a `TransferService`
  guarantee that every completed send appears in history — but
  couples transport to storage, complicates testing, and doesn't
  meaningfully improve the outcome given the screen path is the
  only path to user-visible success.
- **Group by day / week UI.** Nice to have. Skipped for v1 — one
  simple list is easier to reason about and matches "how big is
  this actually going to be" (≤ 200 rows).

## Open follow-ups

- **Settings-driven cap + clear-history button** on the M9.x
  settings screen.
- **Link-mode URL persistence with an explicit opt-in** ("save
  this link for later — keeps the decryption key on this device").
- **Export / import history** for cross-device continuity (needs
  the "sign in on a new device" story too).
- **Search / filter** if history grows past what's comfortably
  scrollable.
