import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/render_api.dart';
import 'auth_controller.dart';
import 'studio_controller.dart';

final renderApiProvider =
    Provider((ref) => RenderApi(ref.watch(apiClientProvider)));

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
    final studio = ref.read(studioControllerProvider);
    final plan = studio.plan;
    final base = studio.base;
    if (plan == null || base == null) return;

    state = const RenderUiState(
        phase: RenderPhase.rendering, message: 'Rendering your mosaic…');

    final tileUrls = {for (final t in studio.tiles) t.id: t.blobUrl};
    final res = await _api.render(
      plan: plan,
      tileUrls: tileUrls,
      baseUrl: base.blobUrl,
      fileName: '${base.name}-mosaic.jpg',
    );

    if (!res.isOk || res.data == null) {
      state = state.copyWith(
          phase: RenderPhase.failed, error: res.error ?? 'Render failed.');
      return;
    }

    state = state.copyWith(phase: RenderPhase.completed, result: res.data);
    // A token was consumed — refresh the balance.
    ref.read(authControllerProvider.notifier).refreshUser();
  }

  void reset() => state = const RenderUiState();
}
