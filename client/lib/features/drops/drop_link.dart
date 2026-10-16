/// Composing the upload link for a file drop (ADR-0040 decision 2).
///
/// Kept in its own file, away from any widget, because this is the
/// security-critical line of the whole feature and it should be
/// readable and testable on its own.
///
/// WHY THE CLIENT BUILDS THIS AND NOT THE SERVER. The link carries the
/// owner's X25519 `identity_pub` in the URL *fragment*. The uploader's
/// browser seals `K_file` to that key, and the uploader has no prior
/// relationship with the owner and no fingerprint to check it against.
/// So whoever supplies the key decides who can read the uploads.
///
/// If the key were fetched from the API, a compromised or compelled
/// server could return its own and read every document uploaded, and no
/// participant could detect it. Taking the key from the owner's own
/// device removes the server from that position entirely — which is why
/// `POST /v1/drops` deliberately returns no link and no public key, and
/// why this function takes `identityPub` from local key material rather
/// than from any response.
///
/// The fragment is also never transmitted by the browser, so the server
/// does not learn it even incidentally. Same property link mode relies
/// on for `K_file`, and the same one `privacy.html` and the whitepaper
/// mean by "a fragment we never see".
///
/// WHY THE KEY IS A QUERY PARAMETER *INSIDE* THE FRAGMENT. The web app
/// has no `usePathUrlStrategy()`, so Flutter web uses the default hash
/// strategy and go_router takes the route itself from the fragment. A
/// link of the form `/drop/<id>#k=...` therefore asks go_router to
/// treat `k=...` as the route and it fails an assertion before the
/// screen is ever built.
///
/// So the route and the key share the fragment:
///
///     https://app.nduzem.com/#/drop/<id>?k=<owner identity pub>
///
/// The security property is unchanged, and this is the part worth being
/// sure about: browsers transmit nothing after `#`, so a `?k=` sitting
/// inside the fragment is as invisible to the server as a bare
/// fragment was. It is a query parameter of the client-side route, not
/// of the HTTP request — the server sees `GET /`.
///
/// Link mode does not hit this because its web decrypt page is a static
/// page in `infra/www` that reads `location.hash` itself, rather than a
/// go_router route.
library;

import 'dart:convert';
import 'dart:typed_data';

/// Build `https://<host>/#/drop/<id>?k=<identity_pub>`.
///
/// [identityPubB64] must be the owner's own X25519 public key, read from
/// this device. [shareUrlBase] is the bare host, not the `api.`
/// subdomain — same reasoning as link mode.
String buildDropUploadUrl({
  required Uri shareUrlBase,
  required String dropId,
  required String identityPubB64,
}) {
  if (dropId.isEmpty) {
    throw ArgumentError.value(dropId, 'dropId', 'must not be empty');
  }
  if (identityPubB64.isEmpty) {
    throw ArgumentError.value(
      identityPubB64,
      'identityPubB64',
      'must not be empty. A drop link without the owner key is unusable, '
          'and silently producing one would look like it worked',
    );
  }

  // base64url without padding, matching link mode's K_file encoding so
  // the web side has one decoding path rather than two.
  final k = identityPubB64
      .replaceAll('+', '-')
      .replaceAll('/', '_')
      .replaceAll('=', '');

  // Everything after `#` is the client-side route plus its parameters.
  // The host part keeps any path the deployment is served under.
  final trimmed = shareUrlBase.path.endsWith('/')
      ? shareUrlBase.path.substring(0, shareUrlBase.path.length - 1)
      : shareUrlBase.path;
  final origin = shareUrlBase.replace(path: trimmed).toString();
  return '$origin/#/drop/$dropId?k=$k';
}


/// Recover the owner's X25519 public key from the `k` parameter of a
/// drop link.
///
/// The inverse of [buildDropUploadUrl], kept beside it so the two
/// cannot drift — a parser that silently disagrees with the builder
/// produces uploads nobody can open.
///
/// Returns **null** rather than throwing or guessing when the value is
/// absent or malformed. That happens for real: some mail clients and
/// chat apps strip URL fragments, and a hand-retyped link loses
/// everything after the `#`. The uploader page must say the link is
/// incomplete, because the alternative is encrypting a document to
/// nothing and reporting success.
Uint8List? decodeOwnerKeyParam(String? value) {
  if (value == null || value.isEmpty) return null;
  try {
    var b64 = value.replaceAll('-', '+').replaceAll('_', '/');
    b64 += '=' * ((4 - b64.length % 4) % 4);
    final bytes = base64Decode(b64);
    return bytes.isEmpty ? null : Uint8List.fromList(bytes);
  } on FormatException {
    return null;
  }
}
