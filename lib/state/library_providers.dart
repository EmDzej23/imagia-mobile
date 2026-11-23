import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/downloads_api.dart';
import '../api/projects_api.dart';
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
/// them resized through the authenticated batch endpoint.
///
/// A stream of what has arrived so far ([ProjectThumbs.done] once every batch is in),
/// so each card shows its cover as soon as its batch lands. It used to be one future:
/// no card appeared until the slowest of all the batches had finished — and each is
/// the server downloading full-size photos — so the whole grid waited on the worst one.
///
/// Deliberately a *family* keyed by the URL string rather than chained off
/// `projectsListProvider`: a provider that `ref.watch`es another provider can
/// self-invalidate *during build* when Riverpod resumes paused subscriptions on
/// a TickerMode change (route transition), which throws "setState during
/// build". This provider only depends on the stable [tilesApiProvider].
final projectThumbnailsProvider = StreamProvider.autoDispose
    .family<ProjectThumbs, String>((ref, urlsKey) async* {
  if (urlsKey.isEmpty) {
    yield const ProjectThumbs({}, done: true);
    return;
  }
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
  final cached = await Future.wait(urls.map(ThumbCache.read));
  for (var i = 0; i < urls.length; i++) {
    final c = cached[i];
    if (c != null) {
      out[urls[i]] = c;
    } else {
      misses.add(urls[i]);
    }
  }
  if (misses.isEmpty) {
    yield ProjectThumbs(out, done: true);
    return;
  }
  if (out.isNotEmpty) yield ProjectThumbs(Map.of(out), done: false);

  // Small batches, all in flight at once, in grid order: the top cards are in the
  // first ones, and each lands on screen by itself.
  final arrived = StreamController<Map<String, Uint8List>>();
  var pending = 0;
  for (var i = 0; i < misses.length; i += _coverBatch) {
    final end = (i + _coverBatch).clamp(0, misses.length);
    pending++;
    tiles
        .tileThumbBatch(misses.sublist(i, end), maxSize: 300, keep: true)
        .catchError((Object _) => <String, Uint8List>{})
        .then((got) {
      if (!arrived.isClosed) arrived.add(got);
      if (--pending == 0) arrived.close();
    });
  }
  ref.onDispose(arrived.close);
  var left = pending;
  await for (final got in arrived.stream) {
    out.addAll(got);
    for (final e in got.entries) {
      unawaited(ThumbCache.write(e.key, e.value));
    }
    yield ProjectThumbs(Map.of(out), done: --left == 0);
  }
});

/// Covers per request: three rows of the two-column grid.
const _coverBatch = 6;

/// The covers that have arrived, and whether more are still coming.
class ProjectThumbs {
  const ProjectThumbs(this.bytes, {required this.done});
  final Map<String, Uint8List> bytes;
  final bool done;
}

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
