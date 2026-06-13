import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/downloads_api.dart';
import '../api/projects_api.dart';
import 'auth_controller.dart';
import 'studio_controller.dart';

/// Saved projects list for the gallery. Invalidate to refresh after save/delete.
final projectsListProvider =
    FutureProvider.autoDispose<List<ProjectSummary>>((ref) async {
  final res = await ref.watch(projectsApiProvider).list();
  if (!res.isOk || res.data == null) {
    throw res.error ?? 'Failed to load projects.';
  }
  return res.data!;
});

final downloadsApiProvider =
    Provider((ref) => DownloadsApi(ref.watch(apiClientProvider)));

final downloadsListProvider =
    FutureProvider.autoDispose<List<DownloadRecord>>((ref) async {
  final res = await ref.watch(downloadsApiProvider).list();
  if (!res.isOk || res.data == null) {
    throw res.error ?? 'Failed to load downloads.';
  }
  return res.data!;
});
