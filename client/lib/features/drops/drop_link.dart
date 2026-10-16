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
library;

/// Build `https://<host>/drop/<id>#k=<identity_pub>`.
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

  // shareUrlBase may or may not end in `/` — normalise before appending.
  final base = shareUrlBase.replace(
    path: shareUrlBase.path.endsWith('/')
        ? '${shareUrlBase.path}drop/$dropId'
        : '${shareUrlBase.path}/drop/$dropId',
  );
  return '$base#k=$k';
}
