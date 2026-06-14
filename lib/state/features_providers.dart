import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/features_api.dart';
import 'auth_controller.dart';

final featuresApiProvider =
    Provider<FeaturesApi>((ref) => FeaturesApi(ref.watch(apiClientProvider)));

/// In-app max output resolution (long side, px). Cached for the session; null
/// if unknown (render then falls back to the plan's default size).
final maxResolutionProvider = FutureProvider<int?>(
    (ref) => ref.watch(featuresApiProvider).maxResolution());
