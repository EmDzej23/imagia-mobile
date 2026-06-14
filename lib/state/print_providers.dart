import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/print_api.dart';
import 'auth_controller.dart';

final printApiProvider =
    Provider<PrintApi>((ref) => PrintApi(ref.watch(apiClientProvider)));

/// Prodigi catalogue (drives prices + which products are sellable yet).
final printProductsProvider =
    FutureProvider.autoDispose<List<PrintProductDto>>((ref) async {
  final res = await ref.watch(printApiProvider).products();
  if (!res.isOk || res.data == null) {
    throw res.error ?? 'Could not load print products.';
  }
  return res.data!;
});

/// The user's placed print orders ("My orders").
final printOrdersProvider =
    FutureProvider.autoDispose<List<PrintOrderDto>>((ref) async {
  final res = await ref.watch(printApiProvider).orders();
  if (!res.isOk || res.data == null) {
    throw res.error ?? 'Could not load orders.';
  }
  return res.data!;
});
