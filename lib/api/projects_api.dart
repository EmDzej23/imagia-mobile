import 'dart:convert';

import '../mosaic/types.dart';
import 'api_client.dart';

class ProjectSummary {
  ProjectSummary({
    required this.id,
    required this.name,
    required this.hasBase,
    required this.tileCount,
    required this.createdAt,
    required this.updatedAt,
    this.baseImageName,
  });

  final String id;
  final String name;
  final bool hasBase;
  final int tileCount;
  final String createdAt;
  final String updatedAt;
  final String? baseImageName;

  factory ProjectSummary.fromJson(Map<String, dynamic> j) => ProjectSummary(
        id: j['id'] as String,
        name: j['name'] as String? ?? 'Untitled',
        hasBase: j['hasBase'] as bool? ?? false,
        tileCount: (j['tileCount'] as num?)?.toInt() ?? 0,
        createdAt: j['createdAt']?.toString() ?? '',
        updatedAt: j['updatedAt']?.toString() ?? '',
        baseImageName: j['baseImageName'] as String?,
      );
}

class ProjectTileRef {
  ProjectTileRef(this.blobUrl, this.fileName);
  final String blobUrl;
  final String fileName;
}

class ProjectDetail {
  ProjectDetail({
    required this.id,
    required this.name,
    this.baseImageUrl,
    this.baseImageName,
    required this.tiles,
    this.settings,
  });

  final String id;
  final String name;
  final String? baseImageUrl;
  final String? baseImageName;
  final List<ProjectTileRef> tiles;
  final MosaicSettings? settings;

  factory ProjectDetail.fromJson(Map<String, dynamic> p) {
    return ProjectDetail(
      id: p['id'] as String,
      name: p['name'] as String? ?? 'Untitled',
      baseImageUrl: p['baseImageUrl'] as String?,
      baseImageName: p['baseImageName'] as String?,
      tiles: _parseTiles(p['tileUrls']),
      settings: _parseSettings(p['settings']),
    );
  }

  /// Tile refs are stored server-side as a (possibly double-encoded) JSON array
  /// of {blobUrl, fileName}. Decode defensively until we reach a list.
  static List<ProjectTileRef> _parseTiles(dynamic raw) {
    final decoded = _deepDecode(raw);
    if (decoded is! List) return [];
    return decoded
        .whereType<Map>()
        .map((e) => ProjectTileRef(
            e['blobUrl'] as String? ?? '', e['fileName'] as String? ?? 'tile'))
        .where((t) => t.blobUrl.isNotEmpty)
        .toList();
  }

  static MosaicSettings? _parseSettings(dynamic raw) {
    final decoded = _deepDecode(raw);
    if (decoded is! Map) return null;
    try {
      return MosaicSettings.fromJson(decoded.cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  }

  static dynamic _deepDecode(dynamic v) {
    var cur = v;
    var guard = 0;
    while (cur is String && guard++ < 4) {
      try {
        cur = jsonDecode(cur);
      } catch (_) {
        return cur;
      }
    }
    return cur;
  }
}

/// Saved studio projects (base + tiles + settings). Mirrors the RN reference
/// `lib/api/projects.ts`; the server wraps responses in `{projects}` / `{project}`.
class ProjectsApi {
  ProjectsApi(this._client);
  final ApiClient _client;

  Future<ApiResult<List<ProjectSummary>>> list() async {
    final res = await _client.get<Map<String, dynamic>>('/api/projects');
    if (!res.isOk || res.data == null) {
      return ApiResult.fail(res.error ?? 'Failed to load projects.', res.status);
    }
    final list = (res.data!['projects'] as List? ?? [])
        .map((e) => ProjectSummary.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
    return ApiResult.ok(list, res.status);
  }

  Future<ApiResult<ProjectDetail>> get(String id) async {
    final res = await _client.get<Map<String, dynamic>>('/api/projects/$id');
    if (!res.isOk || res.data == null) {
      return ApiResult.fail(res.error ?? 'Failed to load project.', res.status);
    }
    final project = (res.data!['project'] as Map).cast<String, dynamic>();
    return ApiResult.ok(ProjectDetail.fromJson(project), res.status);
  }

  /// tileUrls must be sent as a real JSON array — the server wraps it with
  /// `JSON.stringify(...)`, so sending a pre-encoded string double-encodes it
  /// and the list route then counts characters instead of tiles.
  static List<Map<String, String>> _tilePayload(List<ProjectTileRef> tiles) =>
      tiles.map((t) => {'blobUrl': t.blobUrl, 'fileName': t.fileName}).toList();

  Future<ApiResult<String>> create({
    required String name,
    String? baseImageUrl,
    String? baseImageName,
    required List<ProjectTileRef> tiles,
    MosaicSettings? settings,
  }) async {
    final res = await _client.post<Map<String, dynamic>>('/api/projects', body: {
      'name': name,
      if (baseImageUrl != null) 'baseImageUrl': baseImageUrl,
      if (baseImageName != null) 'baseImageName': baseImageName,
      'tileUrls': _tilePayload(tiles),
      if (settings != null) 'settings': settings.toJson(),
    });
    if (!res.isOk || res.data == null) {
      return ApiResult.fail(res.error ?? 'Failed to save project.', res.status);
    }
    final project = (res.data!['project'] as Map?)?.cast<String, dynamic>();
    return ApiResult.ok(project?['id'] as String? ?? '', res.status);
  }

  /// Updates an existing project (PUT). Only provided fields are written.
  Future<ApiResult<bool>> update(
    String id, {
    String? name,
    String? baseImageUrl,
    String? baseImageName,
    List<ProjectTileRef>? tiles,
    MosaicSettings? settings,
  }) async {
    final res = await _client.put<Map<String, dynamic>>('/api/projects/$id', body: {
      if (name != null) 'name': name,
      if (baseImageUrl != null) 'baseImageUrl': baseImageUrl,
      if (baseImageName != null) 'baseImageName': baseImageName,
      if (tiles != null) 'tileUrls': _tilePayload(tiles),
      if (settings != null) 'settings': settings.toJson(),
    });
    if (!res.isOk) {
      return ApiResult.fail(res.error ?? 'Failed to update project.', res.status);
    }
    return ApiResult.ok(true, res.status);
  }

  Future<ApiResult<bool>> delete(String id) async {
    final res = await _client.delete<Map<String, dynamic>>('/api/projects/$id');
    if (!res.isOk) {
      return ApiResult.fail(res.error ?? 'Failed to delete.', res.status);
    }
    return ApiResult.ok(true, res.status);
  }
}
