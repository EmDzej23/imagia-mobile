import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_typography.dart';

/// Ask before destroying something.
///
/// One helper rather than a dialog written out at each call site: destructive
/// actions should look and read the same wherever they happen, and a prompt that is
/// easy to add is a prompt that actually gets added. Returns true only on an
/// explicit confirm — dismissing by tapping outside counts as "no".
///
/// The destructive action is the one tinted [AppColors.error]; Cancel stays neutral
/// and is what a mis-tap lands on.
Future<bool> confirmDestructive(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Remove',
  String cancelLabel = 'Cancel',
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.surfaceRaised,
      title: Text(title, style: AppTypography.title),
      content: Text(message, style: AppTypography.body),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(cancelLabel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(confirmLabel, style: TextStyle(color: AppColors.error)),
        ),
      ],
    ),
  );
  return ok == true;
}
