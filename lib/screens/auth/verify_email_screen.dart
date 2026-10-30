import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/auth_api.dart';
import '../../state/auth_controller.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';
import '../../widgets/primary_button.dart';
import '../../widgets/secondary_button.dart';

/// "Check your inbox" — shown when an email account exists but isn't verified yet
/// (right after sign-up, or a sign-in the server refused with EMAIL_NOT_VERIFIED).
/// Before this the app showed the raw "Email not verified" error under the form, and
/// half of email sign-ups never got in.
///
/// Pushed on the root navigator over sign-in / sign-up. Once [signInEmail]
/// succeeds the router's auth redirect replaces those pages, which takes this
/// route with them.
class VerifyEmailScreen extends ConsumerStatefulWidget {
  const VerifyEmailScreen({
    super.key,
    required this.email,
    required this.password,
  });

  final String email;

  /// Kept in memory only, so "I've verified" can sign in without retyping.
  final String password;

  @override
  ConsumerState<VerifyEmailScreen> createState() => _VerifyEmailScreenState();
}

class _VerifyEmailScreenState extends ConsumerState<VerifyEmailScreen> {
  static const _cooldown = 30;

  bool _checking = false;
  bool _sending = false;
  String? _message;
  bool _messageIsError = false;
  int _wait = 0;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _say(String text, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _message = text;
      _messageIsError = error;
    });
  }

  Future<void> _continue() async {
    setState(() {
      _checking = true;
      _message = null;
    });
    try {
      await ref
          .read(authControllerProvider.notifier)
          .signInEmail(widget.email, widget.password);
      // Signed in: the router's redirect takes over from here.
    } on AuthException catch (e) {
      _say(
        e.emailNotVerified
            ? 'Not verified yet. Tap the link in the email first, then try again.'
            : e.message,
        error: true,
      );
    } catch (e) {
      _say(e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _resend() async {
    setState(() {
      _sending = true;
      _message = null;
    });
    try {
      await ref
          .read(authControllerProvider.notifier)
          .resendVerification(widget.email);
      _say('Sent again. It can take a minute. Check spam too.');
      _startCooldown();
    } catch (e) {
      _say(e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _startCooldown() {
    _timer?.cancel();
    setState(() => _wait = _cooldown);
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _wait--);
      if (_wait <= 0) t.cancel();
    });
  }

  @override
  Widget build(BuildContext context) {
    final busy = _checking || _sending;
    return Scaffold(
      appBar: AppBar(title: const Text('Verify your email')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.x6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: AppSpacing.x8),
              const Icon(Icons.mark_email_unread_outlined,
                  size: 56, color: AppColors.accent),
              const SizedBox(height: AppSpacing.x6),
              Text('Check your inbox',
                  textAlign: TextAlign.center, style: AppTypography.title),
              const SizedBox(height: AppSpacing.x3),
              Text.rich(
                TextSpan(
                  style: AppTypography.body
                      .copyWith(color: AppColors.textSecondary),
                  children: [
                    const TextSpan(text: 'We sent a link to '),
                    TextSpan(
                      text: widget.email,
                      style: const TextStyle(color: AppColors.textPrimary),
                    ),
                    const TextSpan(
                        text:
                            '. Tap it to confirm your email, then come back here and continue.'),
                  ],
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.x8),
              PrimaryButton(
                label: "I've verified, continue",
                loading: _checking,
                onPressed: busy ? null : _continue,
              ),
              const SizedBox(height: AppSpacing.x3),
              SecondaryButton(
                label: _wait > 0 ? 'Resend email ($_wait s)' : 'Resend email',
                onPressed: busy || _wait > 0 ? null : _resend,
              ),
              if (_message != null) ...[
                const SizedBox(height: AppSpacing.x4),
                Text(
                  _message!,
                  textAlign: TextAlign.center,
                  style: AppTypography.caption.copyWith(
                    color: _messageIsError
                        ? AppColors.error
                        : AppColors.textSecondary,
                  ),
                ),
              ],
              const SizedBox(height: AppSpacing.x6),
              TextButton(
                onPressed: busy ? null : () => Navigator.of(context).pop(),
                child: const Text('Use a different email'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
