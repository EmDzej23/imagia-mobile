/// Characters people use to separate items when they paste a list into one line:
/// "Raat Bhar • Biba • Ghagra", "mom | dad | home", "rome; paris; tokyo".
/// Slashes count only with spaces around them, so "AC/DC" and "24/7" stay whole.
/// Hyphens never split ("Dard-E-Disco"), and neither do spaced dashes, which are
/// as common inside a phrase ("love — forever") as between phrases.
/// Kept identical to the web's lib/wordart/parse-texts.ts.
final _separators = RegExp(r'\s*[•·‧∙●○◦▪▫■□◆◇★☆✦✧✶✱|¦;]\s*|\s+/\s+');

/// Leading list markers left on each piece: "- ", "* ", "1. ", "2) ".
final _listMarker = RegExp(r'^(?:[-*–—]\s+|\d{1,3}[.)]\s+)');

final _hashtagRun = RegExp(r'^#\S+(\s+#\S+)+$');
final _spaces = RegExp(r'\s+');

/// Splits raw input into phrases. Newlines always separate; within a line, so do
/// the separators above. Commas separate only when the line is clearly a comma
/// list — at least three commas and every piece at most four words — so a phrase
/// that contains a comma ("CORRINA, CORRINA", "I love you, baby, forever") stays
/// one phrase. Hashtag runs ("#love #family") become one phrase per tag, no #.
List<String> splitPhrases(String raw) {
  final out = <String>[];
  for (final line in raw.split(RegExp(r'\r?\n'))) {
    for (var piece in line.split(_separators)) {
      piece = piece.trim().replaceFirst(_listMarker, '').trim();
      if (piece.isEmpty) continue;
      final commaParts =
          piece.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
      if (commaParts.length >= 4 &&
          commaParts.every((s) => s.split(_spaces).length <= 4)) {
        out.addAll(commaParts);
      } else if (_hashtagRun.hasMatch(piece)) {
        out.addAll(piece
            .split(_spaces)
            .map((tag) => tag.substring(1))
            .where((tag) => tag.isNotEmpty));
      } else {
        out.add(piece);
      }
    }
  }
  return out;
}

/// Parse a raw phrase blob into a clean, de-duplicated list of phrases for the
/// word-art renderer (see [splitPhrases]); case-insensitive de-dupe.
/// (Relocated from the removed text-tile engine.)
List<String> parseTextPhrases(String raw, {bool uppercase = false}) {
  final seen = <String>{};
  final out = <String>[];
  for (var s in splitPhrases(raw)) {
    if (uppercase) s = s.toUpperCase();
    final key = s.toLowerCase();
    if (seen.add(key)) out.add(s);
  }
  return out;
}
