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
        sections: [
          LegalSection('Image Processing', paragraphs: [
            'Tile matching and live preview run entirely on your device. To '
                'create the final high-resolution mosaic, your images are '
                'uploaded to secure cloud storage and rendered on secure '
                'servers, where the result is stored temporarily for download.',
            'We retain images only as long as needed to complete your mosaic '
                'and provide download access. We do not use your images for any '
                'other purpose, and they are never shared with third parties.',
          ]),
          LegalSection('Data We Collect', paragraphs: [
            'We collect minimal, anonymous usage analytics (such as feature '
                'usage) to improve the service. No personally identifiable '
                'information is collected through analytics.',
          ]),
          LegalSection('Payment Information', paragraphs: [
            'When you purchase tokens, payment processing is handled by our '
                'third-party payment provider. We do not store your credit card '
                'details or billing information on our servers.',
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
        lastUpdated: 'Last updated: March 2026',
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
            'Purchases are processed through our third-party payment provider. '
                'Since mosaic exports are delivered instantly as digital '
                'downloads, refunds are handled on a case-by-case basis. '
                'Contact us if you experience any issues with your purchase.',
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
