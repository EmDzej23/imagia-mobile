import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/render_api.dart';
import '../wordart/parse_texts.dart';
import '../services/haptics.dart';
import '../services/notifications.dart';
import 'auth_controller.dart';
import 'features_providers.dart';
import 'studio_controller.dart';

final renderApiProvider =
    Provider((ref) => RenderApi(ref.watch(apiClientProvider)));

/// True while the export/render screen is mounted. The app-wide render
/// indicator hides itself when this is true (so it doesn't show on the very
/// screen it would link to). The export screen toggles it on mount/unmount.
class OnRenderScreen extends Notifier<bool> {
  @override
  bool build() => false;
  set value(bool v) => state = v;
}

final onRenderScreenProvider =
    NotifierProvider<OnRenderScreen, bool>(OnRenderScreen.new);

enum RenderPhase { idle, rendering, completed, failed }

class RenderUiState {
  const RenderUiState({
    this.phase = RenderPhase.idle,
    this.message = '',
    this.result,
    this.error,
  });

  final RenderPhase phase;
  final String message;
  final RenderResult? result;
  final String? error;

  bool get isBusy => phase == RenderPhase.rendering;

  RenderUiState copyWith({
    RenderPhase? phase,
    String? message,
    RenderResult? result,
    String? error,
  }) =>
      RenderUiState(
        phase: phase ?? this.phase,
        message: message ?? this.message,
        result: result ?? this.result,
        error: error,
      );
}

final renderControllerProvider =
    NotifierProvider<RenderController, RenderUiState>(RenderController.new);

class RenderController extends Notifier<RenderUiState> {
  @override
  RenderUiState build() => const RenderUiState();

  RenderApi get _api => ref.read(renderApiProvider);

  /// Builds the slim plan + tileUrls from current studio state and runs the
  /// final server render synchronously (the route returns the result directly,
  /// proxying to the Cloud Run render service when enabled).
  Future<void> start() async {
    // Never run two renders at once (re-entering the export screen via the
    // global indicator must not restart an in-flight render).
    if (state.phase == RenderPhase.rendering) return;
    final studio = ref.read(studioControllerProvider);
    final base = studio.base;
    if (base == null) return;

    // Ask for notification permission now, in context, so we can alert the user
    // when the (possibly long) render finishes — even if they background the app.
    NotificationService.instance.requestPermission();

    // Tile-less modes (ancient / word art) have no tile plan — they render
    // server-side from the base + look params via /api/render-generative (free).
    final mode = studio.settings.mosaicMode;
    if (mode == 'ancient' || mode == 'ancient-curved' || mode == 'wordart') {
      await _startGenerative(studio, mode);
      return;
    }

    final plan = studio.plan;
    if (plan == null) return;

    state = const RenderUiState(
        phase: RenderPhase.rendering, message: 'Rendering your mosaic…');

    final tileUrls = {for (final t in studio.tiles) t.id: t.blobUrl};
    // Render at the server's in-app max resolution (the plan default is small).
    final maxRes = await ref.read(maxResolutionProvider.future);
    final res = await _api.render(
      plan: plan,
      tileUrls: tileUrls,
      baseUrl: base.blobUrl,
      fileName: '${base.name}-mosaic.jpg',
      outputLongSide: maxRes,
    );

    if (!res.isOk || res.data == null) {
      state = state.copyWith(
          phase: RenderPhase.failed, error: res.error ?? 'Render failed.');
      return;
    }

    state = state.copyWith(phase: RenderPhase.completed, result: res.data);
    // Celebrate, notify (deep-links to the preview) + refresh the token balance.
    Haptics.success();
    NotificationService.instance.showRenderDone(fileName: res.data!.fileName);
    ref.read(authControllerProvider.notifier).refreshUser();
  }

  /// Server render for the tile-less modes (word art / ancient shapes) via
  /// /api/render-generative. Builds the look params from settings — the same
  /// shape the web sends — and reuses the completed/failed phases + download flow.
  Future<void> _startGenerative(StudioState studio, String mode) async {
    final base = studio.base!;
    final baseUrl = base.blobUrl;
    if (baseUrl.isEmpty) {
      state = state.copyWith(
          phase: RenderPhase.failed,
          error: 'The base photo is still uploading — try again in a moment.');
      return;
    }

    final isWord = mode == 'wordart';
    state = RenderUiState(
        phase: RenderPhase.rendering,
        message: isWord
            ? 'Rendering your word art at 10K…'
            : 'Rendering your mosaic at 10K…');

    final s = studio.settings;
    final Map<String, dynamic> params;
    if (isWord) {
      final phrases =
          parseTextPhrases(studio.textInput, uppercase: studio.textUppercase);
      params = {
        'phrases': phrases.isEmpty ? const ['WORD'] : phrases,
        'density': s.wordartDensity,
        'rotation': s.wordartRotation,
        'contrast': s.wordartContrast,
        'palette': s.wordartPalette.round(),
        'ground': s.wordartGround,
        'vivid': s.wordartVivid,
        'empty': s.wordartEmpty,
        'seedNonce': studio.wordartSeedNonce,
      };
    } else {
      final curved = mode == 'ancient-curved';
      params = {
        'stoneSize': s.ancientStoneSize,
        'grout': s.ancientGrout,
        'irregularity': s.ancientIrregularity,
        'variation': s.ancientVariation,
        'bevel': s.ancientBevel,
        'groutColor': s.ancientGroutColor,
        'curviness': curved ? s.ancientCurviness : 0,
        'shape': curved ? s.ancientShape : 'none',
        'seedNonce': studio.ancientSeedNonce,
      };
    }

    final suffix = isWord ? 'word-art' : 'ancient-mosaic';
    final res = await _api.renderGenerative(
      mode: mode,
      baseUrl: baseUrl,
      params: params,
      fileName: '${base.name}-$suffix',
      longSide: 10000,
    );

    if (!res.isOk || res.data == null) {
      state = state.copyWith(
          phase: RenderPhase.failed, error: res.error ?? 'Render failed.');
      return;
    }

    state = state.copyWith(phase: RenderPhase.completed, result: res.data);
    Haptics.success();
    NotificationService.instance.showRenderDone(fileName: res.data!.fileName);
    ref.read(authControllerProvider.notifier).refreshUser();
  }

  void reset() => state = const RenderUiState();
}
