# Contributing

This repository is public so that the claims Nduzem makes can be
checked. That is its main job, and it shapes what contribution means
here.

**It is maintained by one person.** Pull requests may sit for a while,
and some will be declined for reasons that have nothing to do with their
quality. None of that is meant as discouragement; it is better said in
advance than discovered after you have spent an evening on something.

For anything security-related, stop here and read
[SECURITY.md](SECURITY.md) instead. Do not open a public issue for it.

## What is genuinely useful

In rough order of how much it helps:

1. **A place where the code and the [security
   whitepaper](https://nduzem.com/whitepaper) disagree.** The whitepaper
   is the claim; this repository is the evidence. Any divergence is a
   real finding even when the code is the correct half, because a reader
   who spots it has no way to know which one to believe.
2. **Reproducible-build verification**: once
   `provability/reproducible-build/` is actually implemented. It is not
   yet, and says so: `verify.sh` exits non-zero rather than reporting a
   success it has not earned. When it works, an independent rebuild that
   *disagrees* with a published manifest is the single most valuable
   report this project could receive.
3. **Cross-platform and cross-browser breakage**, with the device,
   browser and version. The web client is tested by hand against Chrome,
   Firefox and Safari; real-world coverage is thinner than that sounds.
4. **Documentation that is wrong**, especially anywhere the honest-scope
   sections overstate what the product does.

## What is unlikely to be merged

Not because it is bad work, but because of what this repository is:

- **New features.** The roadmap is deliberately narrow and mostly
  driven by what a handful of early users actually need.
- **Refactors and style changes.** The code is commented at unusual
  density on purpose; the comments explain why decisions were made, and
  a tidier version that drops them is a net loss here.
- **Dependency bumps** without a reason attached. Dependabot handles the
  routine ones; a bump matters when you can say what it fixes.
- **Anything touching cryptography or key handling** without a written
  argument for why the current construction is wrong. This is the part
  users cannot check for themselves, so the bar is deliberately high.

## What you can and cannot run

Worth knowing before you start, because
[`client/RUNNING.md`](client/RUNNING.md) assumes something you do not
have.

**The backend is not open source.** It lives in a separate, private
repository, so the local-backend setup in `RUNNING.md` is closed to you.
That is a deliberate choice, not an oversight: the client is what has to
be verifiable, because it is where the keys are generated and the
plaintext lives.

You can, without any of that:

```sh
cd client
flutter pub get
flutter analyze
flutter test
```

The unit tests do not need a backend.

To exercise the app end to end, point a debug build at the live service
and use your own account:

```sh
flutter run --dart-define=NDUZEM_API_BASE=https://api.nduzem.com \
            --dart-define=NDUZEM_SHARE_URL_BASE=https://nduzem.com
```

There is nothing confidential about that address: it is compiled into
every released build and visible in the web client's network traffic.
What matters is that **it is production, and there is no staging
environment behind it.** Real accounts, real storage, real quota.

So: your own accounts and your own files, at the volume a person
testing an app would generate. Not load tests, not fuzzing, not
automated runs against the API.

If what you are doing shades into security testing ( probing limits,
trying to reach another account's data, anything you would hesitate to
describe in advance, ...) stop and read [SECURITY.md](SECURITY.md) first.
The safe-harbour terms there set out what is in bounds and cover you
when you stay inside them. They are also the reason to ask before
starting rather than apologise afterwards.

## Licensing of contributions

The client is **Apache-2.0** ([LICENSE-client.md](LICENSE-client.md)),
chosen because verifiable builds and independent audits need a licence
that permits them.

**There is no CLA.** Under Apache-2.0 §5, anything you deliberately
submit for inclusion is licensed under those same terms unless you say
otherwise. This is enough, and keeps a signing step out of the way.

Please confirm in the PR that the work is yours to contribute.

## Practicalities

- Branch from `main`. `main` is protected and its history is not
  rewritten. The published record has to stay fixed for verification to
  mean anything.
- Keep a PR to one concern. A small one gets read; a large one waits.
- CI runs `flutter analyze` and `flutter test` on every pull request. It
  uses no secrets, so it runs on forks without special handling.
- Explain the *why* in the commit message. The reasoning is the part
  that ages well.

## Conduct

Be straightforward and assume good faith. Disagreement about a technical
claim is welcome and is most of the point; personal remarks are not.
Reports to support@nduzem.com.
