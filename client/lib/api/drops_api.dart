import 'api_client.dart';

/// `/v1/drops/*` client (ADR-0040, phase 4a). All authenticated: a drop
/// mints an upload endpoint, so creating one requires a verified account.
///
/// **The upload link is composed here, not by the server.** It carries
/// the owner's X25519 `identity_pub` in the URL *fragment*, which the
/// browser never transmits. That is what stops a compromised server
/// substituting its own key and reading everything uploaded — the
/// uploader has no prior relationship with the owner and no fingerprint
/// to check against, so the key has to arrive with the link.
///
/// The API deliberately returns no link and no public key for this
/// purpose. Accepting one from the server would hand back exactly the
/// substitution the fragment exists to prevent. See [dropUploadUrl].
class DropsApi {
  const DropsApi(this._client);
  final ApiClient _client;

  /// `POST /v1/drops` — mint an upload slot.
  ///
  /// The password comes back **once** and is stored server-side only as
  /// an argon2id hash. There is no endpoint that re-displays it: a lost
  /// password means revoking the drop and creating another, which is
  /// the correct outcome for a secret the server should not be able to
  /// reproduce.
  Future<DropCreated> create({
    required String label,
    int? maxUploads,
    int? maxBytes,
    int? expiresInDays,
  }) async {
    final body = await _client.post(
      '/v1/drops',
      authed: true,
      body: <String, dynamic>{
        'label': label,
        if (maxUploads != null) 'max_uploads': maxUploads,
        if (maxBytes != null) 'max_bytes': maxBytes,
        if (expiresInDays != null) 'expires_in_days': expiresInDays,
      },
    );
    return DropCreated(
      dropId: body['drop_id'] as String,
      label: body['label'] as String,
      password: body['password'] as String,
      maxUploads: (body['max_uploads'] as num).toInt(),
      maxBytes: (body['max_bytes'] as num).toInt(),
      expiresAt: DateTime.parse(body['expires_at'] as String),
      createdAt: DateTime.parse(body['created_at'] as String),
    );
  }

  /// `GET /v1/drops` — the caller's drops, newest first, closed ones
  /// included. An expired or revoked drop is still something the owner
  /// needs to see: "did I set one up for this client, and did anything
  /// arrive?" is the question this answers.
  Future<List<DropSummary>> list() async {
    final body = await _client.get('/v1/drops', authed: true);
    final items = (body['items'] as List<dynamic>? ?? const []);
    return items
        .cast<Map<String, dynamic>>()
        .map(DropSummary.fromJson)
        .toList(growable: false);
  }

  /// `GET /v1/drops/{id}/uploads` — what arrived through one link.
  ///
  /// Includes items that have expired or already been collected:
  /// "did anything come in, and did I miss it?" is the question this
  /// answers, and hiding them answers it wrongly.
  Future<DropArrivals> arrivals(String dropId) async {
    final body = await _client.get('/v1/drops/$dropId/uploads', authed: true);
    return DropArrivals(
      dropId: body['drop_id'] as String,
      label: body['label'] as String,
      uploadsUsed: (body['uploads_used'] as num).toInt(),
      maxUploads: (body['max_uploads'] as num).toInt(),
      state: _parseState(body['state'] as String?),
      items: (body['items'] as List<dynamic>? ?? const [])
          .cast<Map<String, dynamic>>()
          .map(DropArrival.fromJson)
          .toList(growable: false),
    );
  }

  /// `DELETE /v1/drops/{id}` — close it to further uploads. Idempotent,
  /// and it keeps the original revocation timestamp: the moment a drop
  /// stopped accepting uploads is a fact about it, not about the last
  /// time someone pressed the button.
  Future<DateTime> revoke(String dropId) async {
    final body = await _client.delete('/v1/drops/$dropId', authed: true);
    return DateTime.parse(body['revoked_at'] as String);
  }
}

/// Where a drop is in its life. Mirrors the server's `state`, which is
/// derived from one predicate (`Drop.closed_reason`) so the two cannot
/// disagree about what "open" means.
enum DropState { open, revoked, expired, full, unknown }

DropState _parseState(String? raw) => switch (raw) {
      'open' => DropState.open,
      'revoked' => DropState.revoked,
      'expired' => DropState.expired,
      'full' => DropState.full,
      _ => DropState.unknown,
    };

class DropCreated {
  const DropCreated({
    required this.dropId,
    required this.label,
    required this.password,
    required this.maxUploads,
    required this.maxBytes,
    required this.expiresAt,
    required this.createdAt,
  });

  final String dropId;
  final String label;

  /// Shown to the owner once. Never persisted by the client either —
  /// holding it on disk would undo the point of the server not holding
  /// it.
  final String password;

  final int maxUploads;
  final int maxBytes;
  final DateTime expiresAt;
  final DateTime createdAt;
}

class DropSummary {
  const DropSummary({
    required this.dropId,
    required this.label,
    required this.state,
    required this.uploadsUsed,
    required this.maxUploads,
    required this.maxBytes,
    required this.expiresAt,
    required this.revokedAt,
    required this.createdAt,
  });

  factory DropSummary.fromJson(Map<String, dynamic> json) => DropSummary(
        dropId: json['drop_id'] as String,
        label: json['label'] as String,
        state: _parseState(json['state'] as String?),
        uploadsUsed: (json['uploads_used'] as num).toInt(),
        maxUploads: (json['max_uploads'] as num).toInt(),
        maxBytes: (json['max_bytes'] as num).toInt(),
        expiresAt: DateTime.parse(json['expires_at'] as String),
        revokedAt: json['revoked_at'] == null
            ? null
            : DateTime.parse(json['revoked_at'] as String),
        createdAt: DateTime.parse(json['created_at'] as String),
      );

  final String dropId;
  final String label;
  final DropState state;
  final int uploadsUsed;
  final int maxUploads;
  final int maxBytes;
  final DateTime expiresAt;
  final DateTime? revokedAt;
  final DateTime createdAt;

  bool get isOpen => state == DropState.open;
}


class DropArrivals {
  const DropArrivals({
    required this.dropId,
    required this.label,
    required this.uploadsUsed,
    required this.maxUploads,
    required this.state,
    required this.items,
  });

  final String dropId;
  final String label;
  final int uploadsUsed;
  final int maxUploads;
  final DropState state;
  final List<DropArrival> items;
}

/// One file that came in through a link.
///
/// [expiresAt] is not optional, and the UI must show it. This view is
/// the closest thing the product has to a folder, and a folder implies
/// its contents will still be there later — these are ordinary
/// transfers that expire and burn on collection.
class DropArrival {
  const DropArrival({
    required this.transferId,
    required this.encHeaderB64,
    required this.cryptoSuite,
    required this.byteCount,
    required this.status,
    required this.createdAt,
    required this.expiresAt,
  });

  factory DropArrival.fromJson(Map<String, dynamic> json) => DropArrival(
        transferId: json['transfer_id'] as String,
        encHeaderB64: json['enc_header'] as String,
        cryptoSuite: (json['crypto_suite'] as num).toInt(),
        byteCount: (json['byte_count'] as num).toInt(),
        status: json['status'] as String,
        createdAt: DateTime.parse(json['created_at'] as String),
        expiresAt: DateTime.parse(json['expires_at'] as String),
      );

  final String transferId;

  /// The filename lives in here, encrypted. The server cannot read it
  /// and neither can this class — the screen decrypts it locally.
  final String encHeaderB64;
  final int cryptoSuite;
  final int byteCount;

  /// `uploaded` = waiting to be collected, `delivered` = already taken.
  /// Anything else has expired or been removed.
  final String status;
  final DateTime createdAt;
  final DateTime expiresAt;

  bool get collectable => status == 'uploaded';
}
