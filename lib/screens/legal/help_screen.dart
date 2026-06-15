import 'package:flutter/material.dart';

import '../../core/config.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';
import '../../widgets/app_card.dart';

/// "How it works" + FAQ. Content mirrors the web landing FAQ so the guidance
/// stays consistent across platforms.
class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});

  List<(String, String)> get _steps => [
        (
          '1. Pick a base photo',
          'Choose the picture your mosaic will recreate — a portrait, pet, or '
              'landscape all work well.'
        ),
        (
          '2. Add tile photos',
          'Add your own photos, or tap “Free sample photos” to start instantly. '
              'More variety in color and content gives a sharper result — aim '
              'for 200+ when using your own.'
        ),
        (
          '3. Tune in the studio',
          'The preview rebuilds live as you adjust density and style. Tap the '
              'preview to zoom in and see the individual tiles.'
        ),
        (
          '4. Export & download',
          AppConfig.freeRenders
              ? 'Render a high-resolution version — free — then save it to your '
                  'photos or share it. You can also create a video.'
              : 'Spend one token to render a high-resolution version, then save '
                  'it to your photos or share it. You can also create a free '
                  'video.'
        ),
      ];

  List<(String, String)> get _faqs => [
    (
      'How does privacy work?',
      'Tile analysis and mosaic matching run entirely on your device — instant '
          'feedback, no server round-trips. Your uploaded photos are private to '
          'your account and never shared.'
    ),
    (
      'How many tile images do I need?',
      'For best results, add at least 200 tile images. The more variety in '
          'color and content, the sharper the result. You can add thousands — '
          'the algorithm selects the best match for each region.'
    ),
    (
      'What resolution is the export?',
      AppConfig.freeRenders
          ? 'Up to 12,000 px on the long side — sharp enough to print a wall '
              'mural at full photographic quality. Preview and download are free.'
          : 'Up to 12,000 px on the long side — sharp enough to print a wall '
              'mural at full photographic quality. Preview is unlimited and '
              'free; you only pay for the high-res download.'
    ),
    if (AppConfig.freeRenders)
      (
        'Is it free to create mosaics?',
        'Yes — designing, tuning, exporting, and downloading your mosaics is '
            'free in the app.'
      )
    else
      (
        'Do tokens expire?',
        'Never. Buy tokens whenever you want and use them at your own pace. No '
            'subscription, no monthly fees.'
      ),
    (
      'What image formats are supported?',
      'JPEG, PNG, WebP, and HEIC for uploads. Exports are high-quality JPEG '
          'files, optimized for print and digital sharing.'
    ),
    (
      'Can I use my mosaic commercially?',
      'Yes. Once you download your mosaic you own it — personal projects, '
          'gifts, prints for sale, social media, commercial products. Just make '
          'sure you hold rights to the original photos you used.'
    ),
    (
      'How long does creation take?',
      'The live preview rebuilds in real time as you adjust settings. High-res '
          'export takes from 30 seconds to a few minutes depending on output '
          'size.'
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('How it works')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.screen),
          children: [
            Text('Make a photo mosaic', style: AppTypography.title),
            const SizedBox(height: AppSpacing.x1),
            Text('A picture built from hundreds of your own photos.',
                style: AppTypography.caption),
            const SizedBox(height: AppSpacing.x6),
            for (final (title, body) in _steps) ...[
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.x3),
                child: AppCard(
                  padding: const EdgeInsets.all(AppSpacing.x4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: AppTypography.label),
                      const SizedBox(height: AppSpacing.x1),
                      Text(body,
                          style: AppTypography.body
                              .copyWith(color: AppColors.textSecondary)),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.x6),
            Text('FAQ', style: AppTypography.label),
            const SizedBox(height: AppSpacing.x2),
            for (final (q, a) in _faqs)
              Theme(
                data: Theme.of(context)
                    .copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  iconColor: AppColors.accent,
                  collapsedIconColor: AppColors.textMuted,
                  tilePadding: EdgeInsets.zero,
                  childrenPadding:
                      const EdgeInsets.only(bottom: AppSpacing.x3),
                  title: Text(q, style: AppTypography.body),
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(a,
                          style: AppTypography.caption
                              .copyWith(color: AppColors.textSecondary)),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
