/// Local transfer-history models (ADR-0007). Two disjoint shapes:
/// [SentHistoryEntry] and [ReceivedHistoryEntry]. Sealed base so
/// consumers can pattern-match exhaustively.
///
/// The JSON on disk uses a `kind` discriminator (`sent` / `received`)
/// so a mixed list serializes and reads back correctly.
sealed class TransferHistoryEntry {
  const TransferHistoryEntry({
    required this.transferId,
    required this.timestamp,
    required this.filename,
    required this.sizeBytes,
  });

  final String transferId;
  final DateTime timestamp;
  final String filename;
  final int sizeBytes;

  Map<String, dynamic> toJson();

  /// Dispatch on the `kind` discriminator to the right factory.
  /// Unknown kinds → null so a future format bump doesn't crash old
  /// clients on read.
  static TransferHistoryEntry? fromJson(Map<String, dynamic> m) {
    switch (m['kind']) {
      case 'sent':
        return SentHistoryEntry.fromJson(m);
      case 'received':
        return ReceivedHistoryEntry.fromJson(m);
      default:
        return null;
    }
  }
}

/// Persisted at the end of a successful send.
class SentHistoryEntry extends TransferHistoryEntry {
  const SentHistoryEntry({
    required super.transferId,
    required super.timestamp,
    required super.filename,
    required super.sizeBytes,
    required this.mode,
    required this.recipientLabel,
    required this.maxDownloads,
    required this.hasPassword,
  });

  /// `'app'` or `'link'`.
  final String mode;

  /// What the sender typed in the recipient field (email or `@handle`).
  /// Null for link-mode transfers.
  final String? recipientLabel;

  /// Sender-chosen download cap. 1 for app mode. 1/3/10 for link mode
  /// per ADR-0005's UI.
  final int maxDownloads;

  /// True iff the sender set an out-of-band password on a link-mode
  /// transfer.
  final bool hasPassword;

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'sent',
        'transfer_id': transferId,
        'timestamp': timestamp.toUtc().toIso8601String(),
        'filename': filename,
        'size_bytes': sizeBytes,
        'mode': mode,
        'recipient_label': recipientLabel,
        'max_downloads': maxDownloads,
        'has_password': hasPassword,
      };

  static SentHistoryEntry fromJson(Map<String, dynamic> m) =>
      SentHistoryEntry(
        transferId: m['transfer_id'] as String,
        timestamp: DateTime.parse(m['timestamp'] as String),
        filename: m['filename'] as String,
        sizeBytes: (m['size_bytes'] as num).toInt(),
        mode: m['mode'] as String,
        recipientLabel: m['recipient_label'] as String?,
        maxDownloads: (m['max_downloads'] as num?)?.toInt() ?? 1,
        hasPassword: m['has_password'] as bool? ?? false,
      );
}

/// Persisted at the end of a successful receive + ack.
class ReceivedHistoryEntry extends TransferHistoryEntry {
  const ReceivedHistoryEntry({
    required super.transferId,
    required super.timestamp,
    required super.filename,
    required super.sizeBytes,
    required this.senderIdShort,
    required this.senderHandle,
    required this.signatureVerified,
    required this.savedPath,
  });

  /// First 8 chars of the sender's UUID for a compact display when
  /// no handle was surfaced. Null for link-mode receives (no sender
  /// identity).
  final String? senderIdShort;

  /// Sender's decrypted handle (per ADR-0031) if the server
  /// surfaced one. Null when the sender was erased or in link mode.
  final String? senderHandle;

  /// Whether the recipient's client verified the Ed25519 detached
  /// signature over `blob_sha256` — recorded here so the history
  /// screen can render the same badge the receive screen showed.
  final bool signatureVerified;

  /// Where the user actually saved the plaintext. Can be a real
  /// filesystem path (large-file fallback) or a `content://` URI
  /// (SAF). Null when we haven't saved yet — but a
  /// [ReceivedHistoryEntry] is only ever logged post-save, so in
  /// practice this is set.
  final String? savedPath;

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'received',
        'transfer_id': transferId,
        'timestamp': timestamp.toUtc().toIso8601String(),
        'filename': filename,
        'size_bytes': sizeBytes,
        'sender_id_short': senderIdShort,
        'sender_handle': senderHandle,
        'signature_verified': signatureVerified,
        'saved_path': savedPath,
      };

  static ReceivedHistoryEntry fromJson(Map<String, dynamic> m) =>
      ReceivedHistoryEntry(
        transferId: m['transfer_id'] as String,
        timestamp: DateTime.parse(m['timestamp'] as String),
        filename: m['filename'] as String,
        sizeBytes: (m['size_bytes'] as num).toInt(),
        senderIdShort: m['sender_id_short'] as String?,
        senderHandle: m['sender_handle'] as String?,
        signatureVerified: m['signature_verified'] as bool? ?? false,
        savedPath: m['saved_path'] as String?,
      );
}
