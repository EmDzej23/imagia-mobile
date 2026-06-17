import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';

/// One section of a legal document: a heading, body paragraphs, and optional
/// bullet points.
class LegalSection {
  const LegalSection(this.heading,
      {this.paragraphs = const [], this.bullets = const []});
  final String heading;
  final List<String> paragraphs;
  final List<String> bullets;
}

/// Renders a legal document natively (no webview), mirroring the web content so
/// it stays readable offline and on-brand.
class LegalScreen extends StatelessWidget {
  const LegalScreen({
    super.key,
    required this.title,
    required this.sections,
    this.lastUpdated,
  });

  final String title;
  final List<LegalSection> sections;
  final String? lastUpdated;

  /// Privacy Policy (content mirrored from the web, adapted for the app).
  factory LegalScreen.privacy() => const LegalScreen(
        title: 'Privacy Policy',
        lastUpdated: 'Last updated: June 2026',
        sections: [
          LegalSection('What We Collect', paragraphs: [
            'Account information — your email and name — to create and manage '
                'your account, including when you sign in with Google or Apple.',
            'The photos you upload (base and tile images) and the mosaics you '
                'create, used to build and render your mosaic.',
            'If you order a print: the recipient name, shipping address, and '
                'phone number you provide.',
            'A push notification token, so we can alert you when a mosaic is '
                'ready or an order ships, plus minimal anonymous usage '
                'analytics to improve the service.',
          ]),
          LegalSection('How We Use It', paragraphs: [
            'Only to provide the service: authenticate your account, build and '
                'render mosaics, deliver downloads, fulfil and ship print '
                'orders, and send service notifications. We do not use your '
                'data for advertising or cross-app tracking.',
          ]),
          LegalSection('Sharing', paragraphs: [
            'We share data only with the providers needed to run the service: '
                'cloud hosting and storage; payment processors (which handle '
                'card details — we never receive them); and, if you order a '
                'print, our print provider, which receives your finished mosaic '
                'and shipping details to produce and ship your order.',
            'We do not sell your data or share it with advertisers.',
          ]),
          LegalSection('Data Retention', paragraphs: [
            'Photos and mosaics are kept while your account is active and as '
                'long as needed to provide downloads and complete orders. '
                'Account data is kept until you delete your account.',
          ]),
          LegalSection('Deleting Your Account', paragraphs: [
            'You can permanently delete your account and its data anytime from '
                'Account → Delete account, or by request through our website at '
                'studio.imagiastore.com.',
          ]),
          LegalSection('Tracking', paragraphs: [
            'We do not use tracking technologies and we do not share your data '
                'with advertisers.',
          ]),
          LegalSection('Contact', paragraphs: [
            'For privacy-related questions, reach out through our website at '
                'studio.imagiastore.com.',
          ]),
        ],
      );

  /// Terms of Service (content mirrored from the web, adapted for the app).
  factory LegalScreen.terms() => const LegalScreen(
        title: 'Terms of Service',
        lastUpdated: 'Last updated: June 2026',
        sections: [
          LegalSection('Service Description', paragraphs: [
            'Imagia is an app that generates photo mosaics from images you '
                'provide. Tile matching runs on your device, and the app '
                'provides high-resolution export.',
          ]),
          LegalSection('User Responsibilities', paragraphs: [
            'You must have the right to use all images you upload. You are '
                'responsible for ensuring you have proper permissions, licenses, '
                'or ownership of all photos used to create mosaics. Do not '
                'upload images that infringe on others’ intellectual '
                'property or privacy rights.',
          ]),
          LegalSection('Prohibited Content', paragraphs: [
            'You may not use Imagia to create, process, or distribute any of '
                'the following:',
          ], bullets: [
            'Sexually explicit, pornographic, or adult content (NSFW)',
            'Content depicting the sexual exploitation or abuse of minors',
            'Content that promotes violence, terrorism, or hate speech',
            'Content that violates any applicable law or regulation',
          ]),
          LegalSection('', paragraphs: [
            'Violation of this policy may result in immediate termination of '
                'access to the service without refund. We reserve the right to '
                'refuse service to anyone at our sole discretion.',
          ]),
          LegalSection('Intellectual Property', paragraphs: [
            'You retain all rights to your uploaded images and generated '
                'mosaics. We do not claim ownership of any content you create '
                'using our service.',
          ]),
          LegalSection('Payments and Refunds', paragraphs: [
            'Physical print orders are paid and processed through a third-party '
                'payment provider; we do not store your card details. Because '
                'prints are made to order, refunds are handled on a '
                'case-by-case basis — contact us if there is any issue with '
                'your order.',
          ]),
          LegalSection('Limitation of Liability', paragraphs: [
            'The service is provided “as is” without warranties of any '
                'kind. We are not liable for any damages arising from the use or '
                'inability to use the service, including but not limited to loss '
                'of data or images.',
          ]),
          LegalSection('Changes to Terms', paragraphs: [
            'We reserve the right to modify these terms at any time. Continued '
                'use of the service after changes constitutes acceptance of the '
                'new terms.',
          ]),
        ],
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.screen),
          children: [
            if (lastUpdated != null) ...[
              Text(lastUpdated!, style: AppTypography.caption),
              const SizedBox(height: AppSpacing.x4),
            ],
            for (final s in sections) ...[
              if (s.heading.isNotEmpty) ...[
                Text(s.heading, style: AppTypography.title),
                const SizedBox(height: AppSpacing.x2),
              ],
              for (final p in s.paragraphs) ...[
                Text(p,
                    style: AppTypography.body
                        .copyWith(color: AppColors.textSecondary, height: 1.5)),
                const SizedBox(height: AppSpacing.x3),
              ],
              for (final b in s.bullets)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.x2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 7, right: 10),
                        child: Container(
                          width: 5,
                          height: 5,
                          decoration: const BoxDecoration(
                              color: AppColors.accent, shape: BoxShape.circle),
                        ),
                      ),
                      Expanded(
                        child: Text(b,
                            style: AppTypography.body.copyWith(
                                color: AppColors.textSecondary, height: 1.4)),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: AppSpacing.x4),
            ],
          ],
        ),
      ),
    );
  }
}
