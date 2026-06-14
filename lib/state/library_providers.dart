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

/// Base-photo thumbnails for the project cards, keyed by [projectThumbKey] (a
/// newline-joined list of base blob URLs). Base images are private, so we fetch
/// them resized through the authenticated batch endpoint (one batched request
/// covers every card).
///
/// Deliberately a *family* keyed by the URL string rather than chained off
/// `projectsListProvider`: a provider that `ref.watch`es another provider can
/// self-invalidate *during build* when Riverpod resumes paused subscriptions on
/// a TickerMode change (route transition), which throws "setState during
/// build". This provider only depends on the stable [tilesApiProvider].
final projectThumbnailsProvider = FutureProvider.autoDispose
    .family<Map<String, Uint8List>, String>((ref, urlsKey) async {
  if (urlsKey.isEmpty) return const <String, Uint8List>{};
  final urls = urlsKey.split('\n');
  final tiles = ref.watch(tilesApiProvider);
  final out = <String, Uint8List>{};
  for (var i = 0; i < urls.length; i += TilesApi.thumbBatchMax) {
    final end = (i + TilesApi.thumbBatchMax).clamp(0, urls.length);
    out.addAll(await tiles.tileThumbBatch(urls.sublist(i, end), maxSize: 300));
  }
  return out;
});

/// Stable family key for [projectThumbnailsProvider] — the projects' base blob
/// URLs joined by newline (changes only when the project set changes).
String projectThumbKey(List<ProjectSummary> projects) => [
      for (final p in projects)
        if (p.baseImageUrl != null) p.baseImageUrl!
    ].join('\n');

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
