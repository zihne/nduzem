# Security policy

Nduzem's entire claim is that you should not have to trust us: files are
encrypted on the sender's device and the server holds ciphertext it
cannot open. A claim like that is only worth anything if people can
challenge it. Reports are genuinely welcome.

## Reporting a vulnerability

**Use GitHub's private vulnerability reporting**: the "Report a
vulnerability" button under this repository's Security tab. It creates a
private thread visible only to the maintainer, so nothing is disclosed
while it is being fixed.

If that is unavailable to you, email **security@nduzem.com** and say only
that you have a security report; wait for a reply before sending
details. Ordinary support goes to support@nduzem.com.

Please do not open a public issue for a security problem.

## What to expect, honestly

Nduzem is maintained by one person. That sets the realistic bounds:

- **Acknowledgement: I aim for five working days.** Sometimes it will be
  longer. If you have heard nothing after two weeks, a nudge is
  reasonable and not rude.
- **No bug bounty.** There is no budget for one. I will credit you in the
  fix and in the release notes if you want that, and say so plainly if
  you would rather stay anonymous.
- **Disclosure timing is yours to set**, within reason. Tell me what you
  intend and I will work to it rather than negotiate for delay. If a fix
  needs an app-store review cycle I will say so; that is typically a few
  days beyond a server fix, and outside my control.

## Scope

**In scope:**

- The Flutter client in this repository: cryptography, key handling,
  local storage, the link-mode decrypt path.
- **The live service at nduzem.com and api.nduzem.com**, even though the
  backend is not open source. A flaw that affects users matters
  regardless of which repository it lives in. Report it here.
- The protocol as described in the [security
  whitepaper](https://nduzem.com/whitepaper), including any place the
  whitepaper and this code disagree. That divergence is itself a finding,
  and one I would rather hear from you than from a reader who quietly
  stops believing the document.

**Out of scope:**

- Third-party dependency CVEs with no demonstrated path to impact here.
  Dependabot already watches those; a report is useful when you can show
  it is reachable.
- Denial of service through ordinary volume, and rate-limit tuning.
- Social engineering, physical access, or a compromised user device.
- Anything requiring a malicious operator. We can already see who sent
  what to whom; see below.

## Things that look like vulnerabilities and are not

These are architectural, documented, and reporting them costs us both
time. Every one is stated in the README's "Honest scope" section and in
the whitepaper:

- **The operator sees metadata.** Sender, recipient, size and timestamps
  are visible to us. Contents, filenames and MIME types are not.
- **"Burn after reading" deletes our copy, not the recipient's.** Once
  someone has your file, they have it.
- **Anyone holding a link-mode URL can open the transfer.** That is what
  a link is. The optional password and download cap exist for exactly
  this reason.
- **Recipient lookup confirms whether an address is registered.** This is
  structural: app-mode sending requires the sender's client to fetch the
  recipient's public key, so the endpoint must reveal that the account
  exists. It is rate-limited per account, and account creation requires a
  verified mailbox.
- **No independent audit has been published.** We say so in the README
  rather than implying otherwise. "Not yet audited" is a known gap, not a
  vulnerability report.

If you think one of these is worse than we have characterised it, that
*is* worth reporting; please say which and why.

## Safe harbour

I will not pursue legal action, or ask a platform to act against you, for
security research conducted in good faith under this policy: testing
against your own accounts, no access to or modification of other
people's data, no denial of service, no social engineering of users or
staff, and giving me a reasonable chance to fix things before publishing.

If you are unsure whether something is in bounds, ask first. I would
rather answer a question than receive an apology.

## Supported versions

The current release on Google Play, and `main` in this repository. There
are no long-term support branches, with one maintainer, backporting to
older versions is not something I can honestly promise.
