import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../../services/app_prefs.dart';
import '../../state/auth_controller.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';
import '../../widgets/app_text_field.dart';
import '../../widgets/primary_button.dart';
import '../../widgets/secondary_button.dart';
import '../onboarding/onboarding_screen.dart';

class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // First-run onboarding — sign-in is where new (signed-out) users land.
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeOnboard());
  }

  Future<void> _maybeOnboard() async {
    final prefs = ref.read(appPrefsProvider);
    if (await prefs.onboardingSeen()) return;
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => const OnboardingScreen(),
    ));
    await prefs.setOnboardingSeen();
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signInEmail() => _run(() async {
        await ref
            .read(authControllerProvider.notifier)
            .signInEmail(_email.text, _password.text);
      });

  Future<void> _signInGoogle() => _run(() async {
        await ref.read(authControllerProvider.notifier).signInWithGoogle();
      });

  Future<void> _signInApple() => _run(() async {
        await ref.read(authControllerProvider.notifier).signInWithApple();
      });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.x6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Imagia', style: AppTypography.display),
                const SizedBox(height: AppSpacing.x2),
                Text('Sign in to build mosaics.',
                    style: AppTypography.body
                        .copyWith(color: AppColors.textSecondary)),
                const SizedBox(height: AppSpacing.x8),
                AppTextField(
                  label: 'Email',
                  controller: _email,
                  hintText: 'you@example.com',
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.email],
                  enabled: !_busy,
                ),
                const SizedBox(height: AppSpacing.x4),
                AppTextField(
                  label: 'Password',
                  controller: _password,
                  obscureText: true,
                  keyboardType: TextInputType.visiblePassword,
                  textInputAction: TextInputAction.done,
                  autofillHints: const [AutofillHints.password],
                  autocorrect: false,
                  enableSuggestions: false,
                  enabled: !_busy,
                  onSubmitted: (_) => _signInEmail(),
                ),
                if (_error != null) ...[
                  const SizedBox(height: AppSpacing.x3),
                  Text(_error!,
                      style: AppTypography.caption
                          .copyWith(color: AppColors.error)),
                ],
                const SizedBox(height: AppSpacing.x6),
                PrimaryButton(
                  label: 'Sign in',
                  loading: _busy,
                  onPressed: _busy ? null : _signInEmail,
                ),
                const SizedBox(height: AppSpacing.x3),
                if (Platform.isIOS) ...[
                  SignInWithAppleButton(
                    onPressed: _busy ? () {} : _signInApple,
                    style: SignInWithAppleButtonStyle.white,
                    height: 48,
                    borderRadius:
                        BorderRadius.circular(AppRadius.control),
                  ),
                  const SizedBox(height: AppSpacing.x3),
                ],
                SecondaryButton(
                  label: 'Continue with Google',
                  icon: Icons.g_mobiledata,
                  onPressed: _busy ? null : _signInGoogle,
                ),
                const SizedBox(height: AppSpacing.x6),
                TextButton(
                  onPressed: _busy ? null : () => context.push('/sign-up'),
                  child: Text('Create an account',
                      style: AppTypography.label
                          .copyWith(color: AppColors.primaryBright)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
