/// Parse a raw multi-line phrase blob into a clean, de-duplicated list of
/// phrases for the word-art renderer. One phrase per line; blanks dropped;
/// case-insensitive de-dupe. (Relocated from the removed text-tile engine.)
List<String> parseTextPhrases(String raw, {bool uppercase = false}) {
  final seen = <String>{};
  final out = <String>[];
  for (var line in raw.split('\n')) {
    var s = line.trim();
    if (s.isEmpty) continue;
    if (uppercase) s = s.toUpperCase();
    final key = s.toLowerCase();
    if (seen.add(key)) out.add(s);
  }
  return out;
}
