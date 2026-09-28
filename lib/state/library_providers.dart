import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/downloads_api.dart';
import '../api/projects_api.dart';
import '../api/tiles_api.dart';
import 'auth_controller.dart';
import 'studio_controller.dart';
import '../services/thumb_cache.dart';

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

  // Survive leaving the screen. `autoDispose` alone threw the whole map away on every
  // navigation, so coming back from a project re-fetched every cover — the covers do
  // not change while the app is open, so that wait was pure repetition.
  final link = ref.keepAlive();
  ref.onDispose(link.close);

  // Served from disk when we have them: the covers are immutable for a given blob
  // URL, so a hit here skips both the request and the server-side resize behind it.
  final out = <String, Uint8List>{};
  final misses = <String>[];
  for (final u in urls) {
    final cached = await ThumbCache.read(u);
    if (cached != null) {
      out[u] = cached;
    } else {
      misses.add(u);
    }
  }

  if (misses.isNotEmpty) {
    // Batches in PARALLEL. They were awaited one after another, so a library needing
    // three batches waited for all three end-to-end before a single card appeared.
    final batches = <Future<Map<String, Uint8List>>>[];
    for (var i = 0; i < misses.length; i += TilesApi.thumbBatchMax) {
      final end = (i + TilesApi.thumbBatchMax).clamp(0, misses.length);
      batches.add(tiles.tileThumbBatch(misses.sublist(i, end), maxSize: 300));
    }
    for (final got in await Future.wait(batches)) {
      out.addAll(got);
      for (final e in got.entries) {
        unawaited(ThumbCache.write(e.key, e.value));
      }
    }
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
