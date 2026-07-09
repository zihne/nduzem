# Compliance & store-submission documentation

Living record of the answers, categorisations, and decisions we've
given to app-store review processes (Play Console, App Store, etc.)
and to third-party questionnaires (data safety forms, content
ratings, tax profiles).

Two reasons this lives in-repo rather than a wiki:

1. **Provenance.** If a submission is ever challenged or a category
   changes upstream, we can point at the exact wording + rationale
   we used at the time. Git history serves as the audit log.
2. **Continuity.** These files answer "why did we say X on the
   Play Console rating?" for a future contributor or successor
   operator without them having to re-derive the answer from first
   principles.

Files here are **narrative documents**, not scripts or code. Update
them via PR when a store form changes upstream OR when we make a
different call than before — always with the reason recorded.

## Contents

| File | Covers |
|---|---|
| [play-console-content-rating.md](play-console-content-rating.md) | Google Play Console content-rating questionnaire answers + rationale |

More to come as we complete other store forms (Play Console Data
Safety, App Store privacy nutrition labels, payment-profile business
categorisation, etc.).
