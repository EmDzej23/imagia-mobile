import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/auth_controller.dart';

/// Records one conversion-funnel step on the server (web `app/api/funnel`, table
/// `funnel_events`) — the same events as the web studio:
/// download_click · purchase_modal_shown · purchase_modal_closed · checkout_click ·
/// free_download · export_done.
///
/// Fire-and-forget: never awaited, never throws. The endpoint always answers 204,
/// so it can't trip the client's 401 sign-out either.
void trackFunnel(
  WidgetRef ref,
  String event, {
  String? mode,
  Map<String, Object?>? meta,
}) {
  try {
    unawaited(
      ref
          .read(apiClientProvider)
          .post<dynamic>(
            '/api/funnel',
            body: {
              'event': event,
              'mode': ?mode,
              'meta': {...?meta, 'client': 'app'},
            },
          )
          .then((_) {}, onError: (_) {}),
    );
  } catch (_) {
    /* tracking must never break anything */
  }
}
