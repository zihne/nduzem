# ADR-0009: Multi-file batch send (app mode)

- **Status**: Accepted
- **Date**: 2026-07-04
- **Related**: [ADR-0005](0005-m5-link-mode-sender.md) (link-mode
  sender — deliberately excluded from batch scope in v1),
  [ADR-0007](0007-client-transfer-history.md) (each batch item still
  logs its own history entry)

## Context

The send screen today accepts one file per session: pick a file,
resolve the recipient, send. Users with "these three PDFs" or "a
folder of receipts" have to walk that loop N times, re-typing the
recipient each time and losing continuity if any single one fails.

The primary intent is usually **one recipient, many files**, so
batching the loop under a single recipient resolution captures the
90% case without introducing per-file recipient plumbing.

Several design decisions have real tradeoffs:

1. **Recipient scope** — one per batch or per file?
2. **Mode scope** — app-mode only, or app + link batches?
3. **Failure semantics** — halt the batch on the first failed file
   or skip and continue?
4. **Cancel semantics** — cancel just the current item, or drop the
   whole queue?
5. **Where does the batch progress + completion live?**
6. **History logging** — one entry per file, or one aggregate?

## Decision

### One recipient, one mode per batch — app mode only in v1

The pick step now accepts multiple files (`allowMultiple: true`).
The recipient resolution + fingerprint acknowledgement stays a
single-step gate — the recipient is set once and applies to every
item in the batch.

**Link-mode batches are deferred.** A link-mode batch of N produces
N distinct share URLs, and the completion surface has to list them
all with per-URL copy and per-URL password (if the sender set one).
That's a real product surface. In v1, the mode toggle disables when
the batch has more than one file, with an inline hint. Link-mode
single-file sends are unchanged.

### `SendQueueController` (Riverpod `Notifier`)

New state container holding:

```dart
class QueuedSend {
  String localId;
  PickedFile file;
  QueueItemStatus status;   // pending | encrypting | uploading | done | failed | cancelled
  String? transferId;       // set on success
  int? byteCountOnServer;   // set on success
  String? errorMessage;     // set on failure
  SendPhase? phase;         // during work
  int? phaseDone;
  int? phaseTotal;
}

class SendQueueState {
  UserLookup recipient;
  String recipientLabel;
  List<QueuedSend> items;
  int currentIndex;         // -1 when idle / all done
  bool cancelled;
  CancelToken? currentCancel;
}
```

The controller exposes:

- `start(...)` — snapshot the recipient + files, transition each
  item through the phases, update state after each event.
- `cancel()` — signal the current file's `CancelToken` and mark all
  remaining items `cancelled`.
- `reset()` — drop state after the user leaves the completion
  screen.

### Failure = skip + continue

If a single file fails (network drop, R2 abort, server 4xx that
isn't a batch-wide condition), the controller records the failure
on that item and moves to the next. The completion screen shows a
per-file grid with success ✓ or failure ✗ + reason.

Exception: `QuotaExceededException` (server 402) is treated as a
**batch-wide** failure — the sender's balance is empty; every
subsequent item would fail the same way. The controller marks the
current item failed with the quota message, marks remaining as
cancelled, and surfaces the same "Buy more credit" CTA the
single-file path uses (ADR-0033 paywall).

### Cancel = drop the queue

User taps Cancel → `CancelToken` on the in-flight item fires (the
existing single-file cancel path), and every remaining `pending`
item transitions to `cancelled`. Rationale: cancelling mid-batch
almost always means "I don't want any of this anymore" — the user
who wanted "just skip this one" can retry from the completion
screen (future affordance) or just not cancel and let the failure
land naturally.

### `/send/batch` route + `BatchSendScreen`

Multi-file (N ≥ 2) sends route to a new `BatchSendScreen` at
`/send/batch` after the user taps Send. The screen reads the
queue provider and renders:

- **Header**: "3 / 8 · report.pdf" + the recipient label.
- **Current-file bar**: the existing single-file phase progress
  (encrypt / preparing / upload) — same widget.
- **Item list**: per-item icon (pending / running / done / failed
  / cancelled) + filename + terse status.
- **Cancel button** while any item is running.
- **On completion**: same list morphs into a summary; "Send more"
  and "Done" buttons.

Single-file sends (N = 1) stay on the existing `SendScreen` +
completion dialogs — familiar, uncluttered, no regression.

### History = one `SentHistoryEntry` per successful item

No change to ADR-0007. The controller calls
`transferHistoryProvider.notifier.log(...)` after each successful
`send`. Failed items don't log — history is "what actually happened,"
and a failed send didn't. Cancelled items don't log either. The user
can re-send failed items via the completion screen.

### Sender fingerprint UX stays as-is

The recipient's fingerprint acknowledgement + verification prompt
(ADR-0031) fires once, at recipient-resolution time, and applies to
the whole batch. No per-file re-prompt.

## Consequences

- **The common case ("send these 5 files to Alice") is one recipient
  resolution + one tap Send + one completion screen.** No re-typing,
  no walking back to the home screen five times.
- **`SendScreen` grows a "N files picked" chip cluster** below the
  file-pick button when the batch size is > 1. Small addition.
- **Link mode gets a subtle disabled state** on multi-file picks
  with an inline "Link mode supports one file at a time in this
  version" note.
- **`TransferService.send` is unchanged.** The controller iterates
  the existing single-file API. No coupling, easy to test the
  controller in isolation, and if we ever need to send in parallel
  (probably not — the multipart pipeline saturates the connection)
  the change is local.
- **Batch cancel + failure semantics are opinions, not settings.**
  If a user complains about "I lost the queue when one file failed
  and I hit cancel," we revisit — but every setting we add now is
  more complexity we have to test.
- **History behaves consistently with single-file sends.** Users
  who filter or scroll history see the same entries whether they
  were sent alone or as part of a batch.

## Alternatives considered

- **Per-file recipient.** Would let a user say "send A to Alice, B
  to Bob, C to Carol" in one flow. Real value, real UI cost, and
  most senders don't want this (they picked "share these" as one
  intent). Deferred.
- **Link-mode batches in v1.** Would need a completion surface that
  lists N URLs with per-URL copy + per-URL password inputs. The
  design is real and worth doing when there's demand.
- **Parallel uploads within a batch.** N-way multipart in parallel
  is what R2 optimises for at scale. On a phone the connection is
  the bottleneck and serial + multipart-per-file already saturates
  it; parallel adds progress-bar complexity for no wall-clock win.
- **Halt on first failure.** Simpler UX but hostile — the user
  already committed to sending N things; a single transient failure
  shouldn't force them to redo the queue.
- **Cancel-current, keep queue.** Consistent with "cancel just this
  one" mental model but conflicts with the "I want out of this
  whole thing" case that's the majority of real cancels. Chose
  drop-queue as the higher-value default.
- **A single "batch history" entry per batch.** Would let the
  history screen collapse batches into one row. Cleaner in dense
  history views but complicates the model (batches vs single sends,
  batch-level ack, etc). Keep per-item; UI grouping is a follow-up.
- **Extend `TransferService.send` to accept a list.** Would push
  serial iteration + progress fanout + failure isolation into the
  service, which today does one transport pipeline. Keeping the
  service single-file and moving batching into a controller is
  cleaner separation.

## Open follow-ups

- **Link-mode batches** — with an N-URL completion surface.
- **Per-file retry from the completion screen** — for the failure
  cases. Currently the user picks the file again + resends.
- **Batch grouping in the history screen** — visual only; the
  underlying entries stay per-item.
- **Progress ETA at the batch level** — extrapolate from
  bytes-per-second on completed items. Nice to have.
- **Drag-to-reorder the queue before Send.** Ordering is
  insertion-order today; user can re-pick if they want a different
  order. Follow-up if the request comes up.
