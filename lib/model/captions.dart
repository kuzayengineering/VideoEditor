/// Auto captions: recognised words, and grouping them into short caption
/// lines that are easy to read.
library;

/// One recognised word and when it was said (in the clip's own time or on
/// the timeline, depending on where it is used).
class SpokenWord {
  const SpokenWord(this.startUs, this.endUs, this.text);

  final int startUs;
  final int endUs;
  final String text;

  @override
  String toString() => '$text@${startUs ~/ 1000}';
}

/// One caption on the timeline.
class CaptionLine {
  const CaptionLine(this.startUs, this.endUs, this.text);

  final int startUs;
  final int endUs;
  final String text;

  @override
  bool operator ==(Object other) =>
      other is CaptionLine &&
      other.startUs == startUs &&
      other.endUs == endUs &&
      other.text == text;

  @override
  int get hashCode => Object.hash(startUs, endUs, text);

  @override
  String toString() => '[$startUs–$endUs] $text';
}

bool _endsSentence(String w) => RegExp(r'[.?!…]["”’)]*$').hasMatch(w);

bool _endsClause(String w) => RegExp(r'[,;:]["”’)]*$').hasMatch(w);

/// Punctuation or a contraction ("'s") that joins the word before it.
bool _joinsBefore(String w) =>
    RegExp(r'''^([,.?!;:…%)\]}”’]|'\w)''').hasMatch(w);

/// Joins words into a line of text.
String joinWords(Iterable<String> words) {
  final b = StringBuffer();
  for (final w in words) {
    if (b.isNotEmpty && !_joinsBefore(w)) b.write(' ');
    b.write(w);
  }
  return b.toString();
}

/// Groups [words] (in time order) into caption lines: a new line starts at
/// the end of a sentence, after a pause, or when the line would be longer
/// than [maxChars] letters or [maxUs]. Each line stays up a little after its
/// last word ([holdUs]) and at least [minUs], without running into the
/// next one. Lines appear a moment ([leadUs]) before their first word, as
/// is usual for captions.
List<CaptionLine> groupCaptions(
  List<SpokenWord> words, {
  int maxChars = 32,
  int maxUs = 4000000,
  int pauseUs = 700000,
  int holdUs = 200000,
  int minUs = 800000,
  int leadUs = 100000,
}) {
  final groups = <List<SpokenWord>>[];
  var current = <SpokenWord>[];
  for (final w in words) {
    final text = w.text.trim();
    if (text.isEmpty) continue;
    final word = SpokenWord(w.startUs, w.endUs, text);
    if (current.isNotEmpty) {
      final last = current.last;
      final length = joinWords([...current.map((x) => x.text), text]).length;
      final breakHere =
          (_endsSentence(last.text) && !_joinsBefore(text)) ||
          word.startUs - last.endUs > pauseUs ||
          (length > maxChars && !_joinsBefore(text)) ||
          (word.endUs - current.first.startUs > maxUs && !_joinsBefore(text)) ||
          // A comma is a good place to break a line that's getting long.
          (_endsClause(last.text) && length > maxChars * 0.6);
      if (breakHere) {
        groups.add(current);
        current = [];
      }
    }
    current.add(word);
  }
  if (current.isNotEmpty) groups.add(current);

  final lines = <CaptionLine>[];
  for (var i = 0; i < groups.length; i++) {
    final g = groups[i];
    final early = g.first.startUs - leadUs;
    final start = lines.isEmpty
        ? (early < 0 ? 0 : early)
        : (early < lines.last.endUs ? lines.last.endUs : early);
    final nextStart = i + 1 < groups.length
        ? groups[i + 1].first.startUs
        : null;
    var end = g.last.endUs + holdUs;
    if (end - start < minUs) end = start + minUs;
    if (nextStart != null && end > nextStart) {
      end = nextStart > g.last.endUs ? nextStart : g.last.endUs;
    }
    if (end <= start) end = start + 100000;
    lines.add(CaptionLine(start, end, joinWords(g.map((w) => w.text))));
  }
  return lines;
}
