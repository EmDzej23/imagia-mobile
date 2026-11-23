import 'dart:async';
import 'dart:isolate';

import 'grid_layout.dart';
import 'layout_batch.dart';
import 'optimal_placement.dart' show PlacementCandidates;

/// Helper isolates for [buildGridLayoutParallel]: work of a plan that does not depend
/// on the passes running meanwhile, done on a phone's spare cores — the same plan,
/// sooner.
///  • The best-of-N annealing seeds (original, blocks, rhombille) are independent, so
///    they run side by side instead of one after another.
///  • The optimiser's candidate lists depend only on the cells and photos, so they are
///    worked out while the annealing, coverage and spacing passes run.
///  • The layout's big scoring batches ([LayoutBatch]: shape candidates, baselines,
///    Vogel's candidate lists) are split across the helpers and the worker.
///
/// A helper only runs the job it is sent. Whoever spawns helpers owns them and kills
/// them (they hold nothing between jobs).

/// Entry point of a helper isolate: announces its port, then runs every seed it is
/// sent and replies with the outcome.
void seedHelperMain(SendPort owner) {
  final inbox = ReceivePort();
  owner.send(inbox.sendPort);
  inbox.listen((msg) {
    final (SendPort reply, Object job, int attempt) =
        msg as (SendPort, Object, int);
    try {
      reply.send((
        attempt,
        job is _SeedMsg
            ? runAnnealSeed(job.unpack(), attempt)
            : job is _CandidatesMsg
            ? job.unpack().run()
            : job is AnnealSeedJob
            ? runAnnealSeed(job, attempt)
            : job is LayoutBatch
            ? job.run()
            : (job as CandidatesJob).run(),
      ));
    } catch (e) {
      reply.send((attempt, '$e'));
    }
  });
}

/// Spawns a helper; completes with the port to send it seeds on.
Future<(Isolate, SendPort)> spawnSeedHelper() async {
  final port = ReceivePort();
  final isolate = await Isolate.spawn(
    seedHelperMain,
    port.sendPort,
    debugName: 'seed',
  );
  final send = await port.first as SendPort;
  return (isolate, send);
}

/// Runs [attempts] of [job], one per helper (the job is copied into each when sent,
/// i.e. now — before the caller moves anything). Outcomes in [attempts] order.
Future<List<AnnealSeedOutcome>> runSeedsOn(
  List<SendPort> helpers,
  AnnealSeedJob job,
  List<int> attempts,
) async {
  if (helpers.length < attempts.length) {
    throw StateError('Not enough seed helpers');
  }
  final replies = ReceivePort();
  // Packed once, copied per helper as plain arrays (the objects took ~0.7 s to copy
  // on a slow phone).
  final Object msg = _SeedMsg.pack(job) ?? job;
  for (var k = 0; k < attempts.length; k++) {
    helpers[k].send((replies.sendPort, msg, attempts[k]));
  }
  final byAttempt = <int, AnnealSeedOutcome>{};
  try {
    await for (final msg in replies) {
      final (int attempt, Object result) = msg as (int, Object);
      if (result is! AnnealSeedOutcome)
        throw StateError('Seed failed: $result');
      byAttempt[attempt] = result;
      if (byAttempt.length == attempts.length) break;
    }
  } finally {
    replies.close();
  }
  return [for (final a in attempts) byAttempt[a]!];
}

/// Works out [job] on [helper] (copied into it now). Null if the helper fails — the
/// optimiser then computes the candidates itself.
Future<PlacementCandidates?> runCandidatesOn(
  SendPort helper,
  CandidatesJob job,
) async {
  final reply = ReceivePort();
  helper.send((reply.sendPort, _CandidatesMsg.pack(job) ?? job, -1));
  try {
    final (int _, Object result) = await reply.first as (int, Object);
    return result is PlacementCandidates ? result : null;
  } finally {
    reply.close();
  }
}

/// Below this many items per part a batch is not worth splitting (sending costs more).
const int _minBatchPart = 48;

/// Computes [batch] split into consecutive parts: one per helper (sent, i.e. copied,
/// now) and one here, then hands the parts to the batch in order — the same result
/// as computing it whole.
Future<void> runBatchOn(List<SendPort> helpers, LayoutBatch batch) async {
  final n = batch.length;
  final parts = helpers.isEmpty
      ? 1
      : (n ~/ _minBatchPart).clamp(1, helpers.length + 1);
  if (parts < 2) {
    batch.computeHere();
    return;
  }
  final per = (n + parts - 1) ~/ parts;
  final replies = ReceivePort();
  // Part 0 here; parts 1.. on the helpers.
  for (var k = 1; k < parts; k++) {
    final a = k * per, b = ((k + 1) * per).clamp(0, n);
    helpers[k - 1].send((replies.sendPort, batch.slice(a, b), k));
  }
  final local = batch.slice(0, per, send: false).run();
  final results = <int, Object>{0: local};
  try {
    await for (final msg in replies) {
      final (int k, Object result) = msg as (int, Object);
      if (result is String) throw StateError('Batch part failed: $result');
      results[k] = result;
      if (results.length == parts) break;
    }
  } finally {
    replies.close();
  }
  batch.take([for (var k = 0; k < parts; k++) results[k]!]);
}

/// An [AnnealSeedJob] as flat data (see [PackedPlacements]).
class _SeedMsg {
  _SeedMsg(this.placements, this.adjacency, this.job);
  final PackedPlacements placements;
  final PackedAdjacency adjacency;

  /// The rest of the job (its placements and adjacency left empty).
  final AnnealSeedJob job;

  static _SeedMsg? pack(AnnealSeedJob job) {
    final p = PackedPlacements.pack(job.placements);
    if (p == null) return null;
    return _SeedMsg(
      p,
      PackedAdjacency(job.adjacency),
      AnnealSeedJob(
        placements: const [],
        tileMap: job.tileMap,
        settings: job.settings,
        adjacency: const [],
        saliency: job.saliency,
        budgetFactor: job.budgetFactor,
        isMobile: job.isMobile,
      ),
    );
  }

  AnnealSeedJob unpack() => AnnealSeedJob(
    placements: placements.unpack(),
    tileMap: job.tileMap,
    settings: job.settings,
    adjacency: adjacency.unpack(),
    saliency: job.saliency,
    budgetFactor: job.budgetFactor,
    isMobile: job.isMobile,
  );
}

/// A [CandidatesJob] as flat data.
class _CandidatesMsg {
  _CandidatesMsg(this.placements, this.job);
  final PackedPlacements placements;
  final CandidatesJob job;

  static _CandidatesMsg? pack(CandidatesJob job) {
    final p = PackedPlacements.pack(job.placements);
    if (p == null) return null;
    return _CandidatesMsg(
      p,
      CandidatesJob(const [], job.tiles, job.settings, job.saliency),
    );
  }

  CandidatesJob unpack() =>
      CandidatesJob(placements.unpack(), job.tiles, job.settings, job.saliency);
}
