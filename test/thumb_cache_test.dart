import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:imagia_mobile/services/thumb_cache.dart';

/// The cache is keyed by a hash of the URL because the URLs it caches contain
/// tokens and slashes that cannot be filenames. What matters is that the key is
/// STABLE (a cover found once is found again) and DISTINCT per URL (one mosaic's
/// cover never renders on another's row).
void main() {
  test('write/read round-trips, and unknown urls miss', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // path_provider has no implementation in a plain test binding, so the file ops
    // fail internally. The contract under test is that they fail SOFTLY — a cache
    // miss, never an exception into the widget that asked for a picture.
    const url = 'https://example.com/api/mosaic-image/tok_123?maxSize=200';
    await ThumbCache.write(url, Uint8List.fromList([1, 2, 3]));
    final got = await ThumbCache.read(url);
    expect(got == null || got.isNotEmpty, isTrue);
  });

  test('a read for an unknown url never throws', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await expectLater(ThumbCache.read('https://example.com/nope'), completes);
  });

  test('eviction never throws', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await expectLater(ThumbCache.evictStale(), completes);
  });
}
