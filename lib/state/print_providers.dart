import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/print_api.dart';
import 'auth_controller.dart';

final printApiProvider =
    Provider<PrintApi>((ref) => PrintApi(ref.watch(apiClientProvider)));

/// Gelato client — same shape, different base path. Drives the poster catalogue.
final gelatoApiProvider = Provider<PrintApi>((ref) => PrintApi(
      ref.watch(apiClientProvider),
      base: '/api/print/gelato',
      provider: 'gelato',
    ));

/// Prodigi catalogue (drives prices + which products are sellable yet).
final printProductsProvider =
    FutureProvider.autoDispose<List<PrintProductDto>>((ref) async {
  final res = await ref.watch(printApiProvider).products();
  if (!res.isOk || res.data == null) {
    throw res.error ?? 'Could not load print products.';
  }
  return res.data!;
});

/// Gelato poster catalogue — live Creem prices per size/orientation.
final gelatoProductsProvider =
    FutureProvider.autoDispose<List<PrintProductDto>>((ref) async {
  final res = await ref.watch(gelatoApiProvider).products();
  if (!res.isOk || res.data == null) {
    throw res.error ?? 'Could not load poster products.';
  }
  return res.data!;
});

/// The user's placed print orders across BOTH providers ("My orders"), newest
/// first. A failure from one provider doesn't hide the other's orders.
final printOrdersProvider =
    FutureProvider.autoDispose<List<PrintOrderDto>>((ref) async {
  final results = await Future.wait([
    ref.watch(printApiProvider).orders(),
    ref.watch(gelatoApiProvider).orders(),
  ]);
  final merged = <PrintOrderDto>[
    for (final r in results)
      if (r.isOk && r.data != null) ...r.data!,
  ];
  if (merged.isEmpty && results.every((r) => !r.isOk)) {
    throw results.first.error ?? 'Could not load orders.';
  }
  merged.sort((a, b) => (b.createdAt ?? '').compareTo(a.createdAt ?? ''));
  return merged;
});
