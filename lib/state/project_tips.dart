import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../api/notifications_api.dart';
import 'auth_controller.dart';
import 'studio_controller.dart';

final notificationsApiProvider =
    Provider((ref) => NotificationsApi(ref.watch(apiClientProvider)));

/// Tips the user dismissed, by tip id, kept on the device.
///
/// By id, not by project: saving new tips in admin replaces the row (new id), so a
/// dismissed project's NEW tips show again — and only those.
class DismissedTips {
  DismissedTips([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  static const _key = 'dismissed_project_tips';
  final FlutterSecureStorage _storage;
  Set<String>? _cache;

  Future<Set<String>> read() async {
    if (_cache != null) return _cache!;
    try {
      final raw = await _storage.read(key: _key);
      final list = raw == null ? const [] : (jsonDecode(raw) as List);
      _cache = list.map((e) => e.toString()).toSet();
    } catch (_) {
      _cache = {};
    }
    return _cache!;
  }

  Future<void> add(String id) async {
    final ids = await read();
    ids.add(id);
    // Keep the newest few hundred — ids of replaced tips never come back anyway.
    final keep = ids.length > 300 ? ids.skip(ids.length - 300).toSet() : ids;
    _cache = keep;
    await _storage.write(key: _key, value: jsonEncode(keep.toList()));
  }
}

final dismissedTipsProvider = Provider((_) => DismissedTips());

/// Tips for the project open in the studio, or null (no project / no tips /
/// dismissed / offline). Re-fetched whenever another project is opened; invalidate
/// after marking read or dismissing.
final currentProjectTipProvider =
    FutureProvider.autoDispose<ProjectTip?>((ref) async {
  final id = ref.watch(studioControllerProvider.select((s) => s.currentProjectId));
  if (id == null) return null;
  try {
    final tip = await ref.watch(notificationsApiProvider).tipFor(id);
    if (tip == null) return null;
    if ((await ref.read(dismissedTipsProvider).read()).contains(tip.id)) return null;
    return tip;
  } catch (_) {
    return null; // tips are a nice-to-have; never break the studio over them
  }
});

/// Projects whose tips the user has NOT dismissed — drives the gallery's "Tips" label,
/// so a dismissed project's label goes too (and returns with new tips).
final visibleTipProjectsProvider =
    FutureProvider.autoDispose<Set<String>>((ref) async {
  try {
    final byProject = await ref.watch(notificationsApiProvider).tipIdsByProject();
    final dismissed = await ref.read(dismissedTipsProvider).read();
    return {
      for (final e in byProject.entries)
        if (!dismissed.contains(e.value)) e.key,
    };
  } catch (_) {
    return const {};
  }
});
