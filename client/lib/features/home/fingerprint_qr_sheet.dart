import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../crypto/fingerprint.dart';

/// Modal bottom sheet that shows the user's fingerprint as a QR code
/// suitable for another device to scan.
///
/// **QR payload:** the plain-text display form
/// (`"12345 67890 12345 67890 12345"`). Chosen because it works with:
///   - any generic QR scanner (Signal, camera app, screenshot-and-decode),
///     which will surface a copyable string the recipient can paste into
///     our verify-contact screen;
///   - a future opaqueshare-native scanner that will detect a 25-digit
///     numeric string and match without any URI-wrapping ceremony.
///
/// The canonical form (no spaces) would be marginally smaller in the QR
/// but harder to read at a glance if the recipient's app just shows the
/// decoded text. 29 characters is small enough to fit in a low-density
/// QR that reads well on a phone screen from ~15 cm away.
class FingerprintQrSheet extends StatelessWidget {
  const FingerprintQrSheet({super.key, required this.fingerprint});
  final Fingerprint fingerprint;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Your fingerprint',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
            Center(
              child: Container(
                padding: const EdgeInsets.all(16),
                color: Colors.white,
                child: QrImageView(
                  data: fingerprint.display,
                  version: QrVersions.auto,
                  size: 260,
                ),
              ),
            ),
            const SizedBox(height: 16),
            SelectableText(
              fingerprint.display,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 18,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Ask the other person to scan this from their device, or '
              'to read the digits back to you over an out-of-band '
              'channel (voice call, in person). If both sides see the '
              'same digits, the keys are the ones you exchanged.',
              style: TextStyle(fontStyle: FontStyle.italic),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }
}
