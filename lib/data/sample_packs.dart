/// Free, server-hosted tile packs the user can import instead of (or in
/// addition to) their own photos. Mirrors the web `SAMPLE_OPTIONS`
/// (components/upload-panel.tsx); each `id` is a valid `/api/sample-tiles`
/// folder.
class SamplePack {
  const SamplePack(this.id, this.label, this.emoji, this.description);
  final String id;
  final String label;
  final String emoji;
  final String description;
}

const List<SamplePack> kSamplePacks = [
  SamplePack('facesSample', 'Faces', '👤', 'Portrait photos'),
  SamplePack('faces2Sample', 'Faces 2', '👥', 'More portraits'),
  SamplePack('butterflySample', 'Butterflies', '🦋', 'Butterfly collection'),
  SamplePack('plantSample', 'Plants', '🌿', 'Nature & plants'),
  SamplePack('animalsSample', 'Animals', '🐾', 'Wildlife photos'),
  SamplePack('barcelonaSample', 'Barcelona', '🏛️', 'Barcelona cityscape'),
  SamplePack('newYorkSample', 'New York', '🗽', 'NYC urban scenes'),
  SamplePack('amsterdamSample', 'Amsterdam', '🚲', 'Amsterdam streets'),
  SamplePack('sanFranciscoSample', 'San Francisco', '🌉', 'Bay Area views'),
  SamplePack('urbanArtSample', 'Urban Art', '🎨', 'Street art & graffiti'),
  SamplePack('urbanArt2Sample', 'Urban Art 2', '🖼️', 'More street art'),
];
