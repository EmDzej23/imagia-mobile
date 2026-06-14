import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/downloads_api.dart';
import '../api/projects_api.dart';
import '../api/tiles_api.dart';
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

/// Base-photo thumbnails for the project cards, keyed by blob URL. Base images
/// are private, so we fetch them resized through the authenticated batch
/// endpoint (one batched request covers every card).
final projectThumbnailsProvider =
    FutureProvider.autoDispose<Map<String, Uint8List>>((ref) async {
  final projects = await ref.watch(projectsListProvider.future);
  final urls = [
    for (final p in projects)
      if (p.baseImageUrl != null) p.baseImageUrl!
  ];
  if (urls.isEmpty) return const {};
  final tiles = ref.watch(tilesApiProvider);
  final out = <String, Uint8List>{};
  for (var i = 0; i < urls.length; i += TilesApi.thumbBatchMax) {
    final end = (i + TilesApi.thumbBatchMax).clamp(0, urls.length);
    out.addAll(await tiles.tileThumbBatch(urls.sublist(i, end), maxSize: 300));
  }
  return out;
});

final downloadsApiProvider =
    Provider((ref) => DownloadsApi(ref.watch(apiClientProvider)));

final downloadsListProvider =
    FutureProvider.autoDispose<List<DownloadRecord>>((ref) async {
  // Full account history (all pages), not just the first.
  final res = await ref.watch(downloadsApiProvider).listAll();
  if (!res.isOk || res.data == null) {
    throw res.error ?? 'Failed to load downloads.';
  }
  return res.data!;
});
