import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../api/api_client.dart';
import 'auth_providers.dart';
import '../../widgets/max_width_content.dart';

/// Two verification paths, matching the server's `VerifyEmailRequest`
/// (spec M1.5):
///
///   - **Link**  : opened via a deep link (`.../verify-email?user_id=…&token=…`).
///     The router matches on the path, extracts params, and this screen
///     auto-submits `{user_id, token}`.
///   - **Code**  : the user types a 6-digit code and their email.
///     The submitted body is `{email, code}` — the server rejects
///     mixed `{user_id, code}` shapes (that's the bug fix we're
///     shipping here).
///
/// The email is prefilled when we arrive here from `RegisterScreen`
/// (which passes `?email=…`), so the common case is one-tap.
class VerifyEmailScreen extends ConsumerStatefulWidget {
  const VerifyEmailScreen({
    super.key,
    required this.userId,
    this.email,
    this.token,
  });

  /// Populated from `?user_id=…`. Used only for the link form + resend UX.
  final String userId;

  /// Populated from `?email=…` when we arrive from register. Falls back
  /// to a text field on this screen if the user landed here directly.
  final String? email;

  /// If non-null, we auto-submit the token form on mount.
  final String? token;

  @override
  ConsumerState<VerifyEmailScreen> createState() => _VerifyEmailScreenState();
}

class _VerifyEmailScreenState extends ConsumerState<VerifyEmailScreen> {
  final _code = TextEditingController();
  late final TextEditingController _emailField;
  bool _busy = false;
  String? _error;
  String? _info;

  @override
  void initState() {
    super.initState();
    _emailField = TextEditingController(text: widget.email ?? '');
    if (widget.token != null) {
      // Auto-verify from the deep link path. Schedule to next frame so the
      // widget tree is stable when we call context.go on success.
      WidgetsBinding.instance.addPostFrameCallback((_) => _verifyToken());
    }
  }

  @override
  void didUpdateWidget(covariant VerifyEmailScreen old) {
    super.didUpdateWidget(old);
    // The deep link usually arrives while this screen is ALREADY on
    // screen: the user registers, lands here waiting for the mail, then
    // taps the link. go_router changes location, but Flutter may reuse
    // this State object rather than building a new one — in which case
    // `initState` does not run again and the token would be received and
    // silently ignored, leaving the user staring at the code form they
    // were already looking at.
    //
    // Firing on the null -> non-null transition covers that. Guarded so
    // an unrelated rebuild cannot re-submit a token already in flight.
    if (widget.token != null && widget.token != old.token && !_busy) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _verifyToken());
    }
  }

  @override
  void dispose() {
    _code.dispose();
    _emailField.dispose();
    super.dispose();
  }

  Future<void> _verifyToken() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final repo = await ref.read(authRepositoryProvider.future);
      await repo.verifyEmail(userId: widget.userId, token: widget.token!);
      if (mounted) context.go('/');
    } on ApiException catch (exc) {
      setState(() => _error = exc.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verifyCode() async {
    final email = _emailField.text.trim();
    if (!email.contains('@')) {
      setState(() => _error = 'Enter the email you registered with.');
      return;
    }
    if (_code.text.trim().length < 4) {
      setState(() => _error = 'Enter the code from the email.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final repo = await ref.read(authRepositoryProvider.future);
      await repo.verifyEmailCode(email: email, code: _code.text.trim());
      if (mounted) context.go('/');
    } on ApiException catch (exc) {
      setState(() => _error = exc.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resend() async {
    final email = _emailField.text.trim();
    if (!email.contains('@')) {
      setState(() => _error = 'Enter your email above, then tap Resend.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });
    try {
      final repo = await ref.read(authRepositoryProvider.future);
      await repo.resendVerification(email: email);
      setState(() => _info = 'Check your email.');
    } on ApiException catch (exc) {
      setState(() => _error = exc.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Verify email'),
        // Deep links arrive on a fresh navigation stack, so there is
        // nothing to pop and Flutter renders no back arrow. Without this
        // the screen is a dead end: when the token is expired, already
        // consumed, or absent, the only controls are "Verify" and
        // "Resend", both of which need a code the user may not have.
        // `go` rather than `pop`, for the same reason — there is no
        // history to return to.
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Leave verification',
          onPressed: () => context.go('/'),
        ),
      ),
      body: MaxWidthContent(
          child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Check your email for a verification link. You can also enter '
              'the 6-digit code below.',
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _emailField,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              decoration: const InputDecoration(labelText: 'Email'),
              readOnly: widget.email != null,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _code,
              keyboardType: TextInputType.number,
              maxLength: 8,
              decoration: const InputDecoration(labelText: 'Code'),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _busy ? null : _verifyCode,
              child: _busy
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Verify'),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: _busy ? null : _resend,
              child: const Text('Resend'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              const SizedBox(height: 4),
              // An expired or already-consumed link is the common case,
              // and it is not something the user can fix from here. Say
              // so with a route out rather than leaving them to discover
              // that the close button applies.
              TextButton(
                onPressed: _busy ? null : () => context.go('/'),
                child: const Text('Continue without verifying'),
              ),
            ],
            if (_info != null) ...[
              const SizedBox(height: 12),
              Text(_info!),
            ],
          ],
        ),
      ),),
    );
  }
}
