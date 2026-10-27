import 'api_client.dart';

/// Tips the Imagia team left on one of the user's projects (admin → project →
/// tips). Stored server-side as a `project_tip` notification keyed `tip:<projectId>`
/// — the same rows the web's bell and projects list show.
class ProjectTip {
  const ProjectTip({
    required this.id,
    required this.body,
    required this.read,
  });

  final String id;
  final String body;
  final bool read;
}

class NotificationsApi {
  NotificationsApi(this._client);
  final ApiClient _client;

  /// The tips for [projectId], or null when there are none.
  Future<ProjectTip?> tipFor(String projectId) async {
    final res = await _client.get<Map<String, dynamic>>('/api/notifications');
    if (!res.isOk || res.data == null) return null;
    final items = res.data!['items'];
    if (items is! List) return null;
    for (final raw in items) {
      if (raw is! Map) continue;
      if (raw['type'] != 'project_tip' || raw['groupKey'] != 'tip:$projectId') {
        continue;
      }
      final body = (raw['body'] as String? ?? '').trim();
      if (body.isEmpty) return null;
      return ProjectTip(
        id: raw['id'].toString(),
        body: body,
        read: raw['readAt'] != null,
      );
    }
    return null;
  }

  /// Every project that has tips: project id → tip id.
  Future<Map<String, String>> tipIdsByProject() async {
    final res = await _client.get<Map<String, dynamic>>('/api/notifications');
    final out = <String, String>{};
    final data = res.isOk ? res.data : null;
    final items = data == null ? null : data['items'];
    if (items is! List) return out;
    for (final raw in items) {
      if (raw is! Map || raw['type'] != 'project_tip') continue;
      final key = raw['groupKey'] as String? ?? '';
      if (!key.startsWith('tip:')) continue;
      if ((raw['body'] as String? ?? '').trim().isEmpty) continue;
      out[key.substring(4)] = raw['id'].toString();
    }
    return out;
  }

  /// Marks one tip as read (the web's bell stops showing it as new too).
  Future<void> markRead(String id) async {
    await _client.post<Map<String, dynamic>>('/api/notifications', body: {
      'ids': [id],
    });
  }
}
