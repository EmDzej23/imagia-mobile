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
    this.baseImageUrl,
    this.baseImageName,
  });

  final String id;
  final String name;
  final bool hasBase;
  final int tileCount;
  final String createdAt;
  final String updatedAt;

  /// Private blob URL of the base photo (fetch via the authenticated
  /// thumbnail endpoint — it is not publicly loadable).
  final String? baseImageUrl;
  final String? baseImageName;

  factory ProjectSummary.fromJson(Map<String, dynamic> j) => ProjectSummary(
        id: j['id'] as String,
        name: j['name'] as String? ?? 'Untitled',
        hasBase: j['hasBase'] as bool? ?? false,
        tileCount: (j['tileCount'] as num?)?.toInt() ?? 0,
        createdAt: j['createdAt']?.toString() ?? '',
        updatedAt: j['updatedAt']?.toString() ?? '',
        baseImageUrl: j['baseImageUrl'] as String?,
        baseImageName: j['baseImageName'] as String?,
      );
}

class ProjectTileRef {
  ProjectTileRef(this.blobUrl, this.fileName, {this.tileId});
  final String blobUrl;
  final String fileName;

  /// The id this tile was saved under, when the project has one. Crops are keyed by
  /// tile id, so honouring a saved id is what lets a crop set in the WEB studio apply
  /// here — web tiles carry an explicit id, and deriving our own would miss it.
  /// Absent (older projects, collab tiles) → both clients fall back to the same
  /// URL-derived id, so they still agree.
  final String? tileId;
}

class ProjectDetail {
  ProjectDetail({
    required this.id,
    required this.name,
    this.baseImageUrl,
    this.baseImageName,
    required this.tiles,
    this.settings,
    this.texts,
    this.tileCrops = const {},
  });

  final String id;
  final String name;
  final String? baseImageUrl;
  final String? baseImageName;
  final List<ProjectTileRef> tiles;
  final MosaicSettings? settings;

  /// Word-art phrases — the raw newline-separated blob (server `texts` column,
  /// same format as [StudioState.textInput]). Shared with the web app.
  final String? texts;

  /// Manual per-tile crops, keyed by the URL-derived tile id. Written by both
  /// clients, so a crop set in the web studio arrives here already applied.
  final Map<String, TileCrop> tileCrops;

  factory ProjectDetail.fromJson(Map<String, dynamic> p) {
    return ProjectDetail(
      id: p['id'] as String,
      name: p['name'] as String? ?? 'Untitled',
      baseImageUrl: p['baseImageUrl'] as String?,
      baseImageName: p['baseImageName'] as String?,
      tiles: _parseTiles(p['tileUrls']),
      settings: _parseSettings(p['settings']),
      texts: p['texts'] as String?,
      tileCrops: _parseCrops(p['tileCrops']),
    );
  }

  /// Crops arrive as `{tileId: {x,y,w,h}}`, possibly double-encoded like the tile
  /// refs. A malformed entry is dropped rather than failing the whole restore — a
  /// lost crop is recoverable, a project that will not open is not.
  static Map<String, TileCrop> _parseCrops(dynamic raw) {
    final decoded = _deepDecode(raw);
    if (decoded is! Map) return const {};
    final out = <String, TileCrop>{};
    decoded.forEach((k, v) {
      if (k is String && v is Map) {
        try {
          out[k] = TileCrop.fromJson(v.cast<String, dynamic>());
        } catch (_) {}
      }
    });
    return out;
  }

  /// Tile refs are stored server-side as a (possibly double-encoded) JSON array
  /// of {blobUrl, fileName}. Decode defensively until we reach a list.
  static List<ProjectTileRef> _parseTiles(dynamic raw) {
    final decoded = _deepDecode(raw);
    if (decoded is! List) return [];
    return decoded
        .whereType<Map>()
        .map((e) => ProjectTileRef(
            e['blobUrl'] as String? ?? '', e['fileName'] as String? ?? 'tile',
            tileId: e['tileId'] as String?))
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
      tiles
          .map((t) => {
                'blobUrl': t.blobUrl,
                'fileName': t.fileName,
                // Saved so the web studio keys crops by the same id we do.
                if (t.tileId != null) 'tileId': t.tileId!,
              })
          .toList();

  /// Same rule as [_tilePayload]: send a plain map, never a pre-encoded string —
  /// the server stringifies it itself.
  static Map<String, dynamic> _cropPayload(Map<String, TileCrop> crops) =>
      {for (final e in crops.entries) e.key: e.value.toJson()};

  Future<ApiResult<String>> create({
    required String name,
    String? baseImageUrl,
    String? baseImageName,
    required List<ProjectTileRef> tiles,
    MosaicSettings? settings,
    String? texts,
    Map<String, TileCrop>? tileCrops,
  }) async {
    final res = await _client.post<Map<String, dynamic>>('/api/projects', body: {
      'name': name,
      if (baseImageUrl != null) 'baseImageUrl': baseImageUrl,
      if (baseImageName != null) 'baseImageName': baseImageName,
      'tileUrls': _tilePayload(tiles),
      if (tileCrops != null && tileCrops.isNotEmpty) 'tileCrops': _cropPayload(tileCrops),
      if (settings != null) 'settings': settings.toJson(),
      if (texts != null && texts.isNotEmpty) 'texts': texts,
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
    String? texts,
    Map<String, TileCrop>? tileCrops,
  }) async {
    final res = await _client.put<Map<String, dynamic>>('/api/projects/$id', body: {
      if (name != null) 'name': name,
      if (baseImageUrl != null) 'baseImageUrl': baseImageUrl,
      if (baseImageName != null) 'baseImageName': baseImageName,
      if (tiles != null) 'tileUrls': _tilePayload(tiles),
      // Sent even when empty: {} is how a cleared crop is persisted.
      if (tileCrops != null) 'tileCrops': _cropPayload(tileCrops),
      if (settings != null) 'settings': settings.toJson(),
      'texts': ?texts,
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
