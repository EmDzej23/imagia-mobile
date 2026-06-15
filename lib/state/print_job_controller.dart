import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/haptics.dart';
import 'print_providers.dart';

enum PrintJobPhase { idle, processing, done, failed }

/// State of the in-flight print-order finalisation (render + submit to Prodigi),
/// held globally so it survives leaving the order screen — like the mosaic
/// render. A tappable indicator can bring the user back to the processing view.
class PrintJobState {
  const PrintJobState({
    this.phase = PrintJobPhase.idle,
    this.orderId,
    this.productName,
    this.step = '',
    this.error,
    this.prodigiOrderId,
  });

  final PrintJobPhase phase;
  final String? orderId;
  final String? productName;
  final String step;
  final String? error;
  final String? prodigiOrderId;

  bool get isProcessing => phase == PrintJobPhase.processing;

  PrintJobState copyWith({
    PrintJobPhase? phase,
    String? orderId,
    String? productName,
    String? step,
    String? error,
    String? prodigiOrderId,
  }) =>
      PrintJobState(
        phase: phase ?? this.phase,
        orderId: orderId ?? this.orderId,
        productName: productName ?? this.productName,
        step: step ?? this.step,
        error: error,
        prodigiOrderId: prodigiOrderId ?? this.prodigiOrderId,
      );
}

class PrintJobController extends Notifier<PrintJobState> {
  @override
  PrintJobState build() => const PrintJobState();

  /// Finalises a paid order (server renders the print mosaic, then submits to
  /// Prodigi). Idempotent on the server, so it's safe to call again to retry.
  Future<void> start({
    required String orderId,
    required String productName,
  }) async {
    if (state.isProcessing) return;
    state = PrintJobState(
      phase: PrintJobPhase.processing,
      orderId: orderId,
      productName: productName,
      step: 'Rendering & placing your order…',
    );
    try {
      final res = await ref.read(printApiProvider).fulfill(orderId);
      if (!res.isOk) {
        state = state.copyWith(
          phase: PrintJobPhase.failed,
          error: res.error ?? 'Could not place your order.',
        );
        return;
      }
      Haptics.success();
      ref.invalidate(printOrdersProvider);
      state = state.copyWith(
        phase: PrintJobPhase.done,
        prodigiOrderId: res.data,
      );
    } catch (e) {
      state = state.copyWith(phase: PrintJobPhase.failed, error: '$e');
    }
  }

  void reset() => state = const PrintJobState();
}

final printJobControllerProvider =
    NotifierProvider<PrintJobController, PrintJobState>(PrintJobController.new);

/// True while the order-processing screen is mounted, so the global indicator
/// hides itself there (it's the screen it would link to).
class OnPrintProcessingScreen extends Notifier<bool> {
  @override
  bool build() => false;
  set value(bool v) => state = v;
}

final onPrintProcessingScreenProvider =
    NotifierProvider<OnPrintProcessingScreen, bool>(
        OnPrintProcessingScreen.new);
