/// How a typed recipient string maps onto the two modes of
/// `POST /v1/users/lookup` (which accepts exactly one of `email` /
/// `handle`).
///
/// The rule has to cope with the three shapes users actually type, and
/// the "To" field's own label — *Email or @handle* — invites the one
/// that used to break:
///
///   `@alice`             → handle `alice`   (leading `@` stripped)
///   `alice@example.com`  → email
///   `alice`              → handle `alice`
///
/// The previous heuristic was a bare `input.contains('@')`, which sent
/// `@alice` down the *email* branch. The server's `EmailStr` then
/// rejected it with a 422 — so following the label's own suggestion
/// produced a validation error, and the handle branch was only
/// reachable by typing a bare name.
///
/// Handles are stored without the sigil (the server's schema is just
/// `min_length=2, max_length=32`), so the `@` is display sugar and must
/// be stripped before it reaches the API.
class RecipientQuery {
  const RecipientQuery._(this.value, {required this.isEmail});

  /// The value to send, with any display-only `@` sigil removed.
  final String value;

  /// True → send as `email`. False → send as `handle`.
  final bool isEmail;

  /// Classify raw user input. Trims surrounding whitespace; the caller
  /// does not need to pre-trim.
  ///
  /// Returns null when there is nothing to look up, so callers can show
  /// a "type something" message rather than firing an empty request.
  static RecipientQuery? parse(String raw) {
    final input = raw.trim();
    if (input.isEmpty) return null;

    if (input.startsWith('@')) {
      final handle = input.substring(1);
      // A lone `@` carries no handle.
      if (handle.isEmpty) return null;
      return RecipientQuery._(handle, isEmail: false);
    }

    // An `@` anywhere else means they typed an address. Note this stays
    // deliberately loose — validating the address shape is the server's
    // job, and rejecting locally would just teach users that a valid
    // address "doesn't work" when our regex disagrees with theirs.
    if (input.contains('@')) {
      return RecipientQuery._(input, isEmail: true);
    }

    return RecipientQuery._(input, isEmail: false);
  }

  @override
  String toString() =>
      'RecipientQuery(${isEmail ? 'email' : 'handle'}: $value)';
}
