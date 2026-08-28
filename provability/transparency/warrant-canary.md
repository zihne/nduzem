# Warrant canary — not operating

**Zihne Ltd does not currently publish a warrant canary.** This file
records that deliberately, so that its absence is a stated position rather
than something a reader has to infer.

It previously contained a single line — *"update on schedule.
Absence/staleness is the signal"* — which described a live mechanism. No
such mechanism existed. That wording is the failure mode a canary is
supposed to prevent, inverted: it invited an inference from silence at a
time when silence meant nothing at all.

## What a canary is, and why that makes it hard to start

A warrant canary is a signed statement, republished on a fixed schedule,
that the operator has received no compelled-disclosure order. The
information is carried by the statement **stopping**. Nothing is ever
disclosed; the reader draws a conclusion from an absence.

That design has two consequences, and both argue against starting one
today.

**A canary is a commitment, not a document.** From the moment it is
published, every missed update is a signal. Zihne Ltd is a one-person
operation. Illness, travel, or a busy fortnight would produce a false
alarm indistinguishable from a real one — and a canary that cries wolf
once is finished, because afterwards nobody can read it either way. A
schedule that cannot be kept reliably is worse than no schedule.

**Its legal effect is untested here.** The Investigatory Powers Act 2016
imposes duties of non-disclosure in relation to certain warrants and
notices served on UK operators. Whether deliberately withdrawing a canary
amounts to a prohibited disclosure by omission has not, as far as we are
aware, been tested in a UK court. A canary that turns out not to be
lawful to withdraw is not a safeguard — it is a document that stays
truthful because its author is compelled to keep republishing it, which
is precisely the situation it was meant to reveal.

We would rather say this plainly than publish a mechanism whose value we
cannot vouch for.

## What we do instead, for now

We make no claim, in either direction, about compelled disclosure. This
file is not a statement that no order has been received, and it should
not be read as one.

What can be said without a canary is structural, and it does not depend on
trusting us: **file contents, filenames and MIME types are encrypted on
the sender's device under a key we never receive and cannot derive.** An
order compelling us to hand over a user's file compels us to hand over
ciphertext. That property is described in the published whitepaper and is
checkable against the source in this repository — which is the kind of
assurance a canary cannot give, because a canary only ever tells you
something has gone wrong after the fact.

If there is ever something to report that we are permitted to report, we
will publish it here as a dated transparency report. A report states a
fact; it does not ask anyone to interpret a silence.

## What starting a canary would require

- A signing key held by the person publishing, with the public key
  published here, so a statement cannot be forged or suppressed unnoticed.
- A fixed cadence — quarterly is realistic for an operation this size;
  monthly is not.
- A named fallback who can publish if the primary cannot, since
  single-person availability is the weakness above.
- Legal advice on the position under the Investigatory Powers Act 2016
  before the first statement, not after.

Until all four hold, this file stays as it is. See `../README.md` for the
status of the other provability work.
