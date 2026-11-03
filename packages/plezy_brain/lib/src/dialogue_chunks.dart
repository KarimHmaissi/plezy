/// One subtitle cue.
class Cue {
  const Cue(this.startMs, this.endMs, this.text);
  final int startMs;
  final int endMs;
  final String text;
}

/// A stretch of dialogue to index: roughly a scene, 30–60 s.
class DialogueChunk {
  const DialogueChunk(this.startMs, this.endMs, this.text);
  final int startMs;
  final int endMs;
  final String text;

  Map<String, Object?> toJson() => {'start': startMs, 'end': endMs, 'text': text};
}

final _timing = RegExp(r'(\d+):(\d+):(\d+)[,.](\d+)\s*-->\s*(\d+):(\d+):(\d+)[,.](\d+)');
final _tags = RegExp(r'<[^>]+>|\{[^}]+\}');
final _noise = RegExp(r'^\s*[\[(♪].*[\])♪]\s*$');

int _ms(String h, String m, String s, String f) =>
    ((int.parse(h) * 60 + int.parse(m)) * 60 + int.parse(s)) * 1000 + int.parse(f.padRight(3, '0').substring(0, 3));

/// Cues of an SRT, with markup, sound descriptions ("[door slams]", "♪")
/// and dialogue dashes removed.
List<Cue> parseSrt(String srt) {
  final out = <Cue>[];
  for (final block in srt.replaceAll('\r', '').split(RegExp(r'\n\s*\n'))) {
    final lines = block.trim().split('\n').where((l) => l.trim().isNotEmpty).toList();
    for (var i = 0; i < lines.length; i++) {
      final m = _timing.firstMatch(lines[i]);
      if (m == null) continue;
      final text = [
        for (final raw in lines.skip(i + 1))
          if (_unescape(raw.replaceAll(_tags, '')).trim() case final t when t.isNotEmpty && !_noise.hasMatch(t))
            t.replaceFirst(RegExp(r'^-\s*'), ''),
      ];
      if (text.isNotEmpty) {
        out.add(Cue(_ms(m[1]!, m[2]!, m[3]!, m[4]!), _ms(m[5]!, m[6]!, m[7]!, m[8]!), text.join(' ')));
      }
      break;
    }
  }
  return out;
}

String _unescape(String s) => s
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'");

/// Groups cues into chunks: one closes at a pause once it's past [minMs],
/// at [maxMs] regardless, and at any long silence.
List<DialogueChunk> chunkDialogue(
  List<Cue> cues, {
  int minMs = 30000,
  int maxMs = 60000,
  int pauseMs = 6000,
  int silenceMs = 20000,
}) {
  final out = <DialogueChunk>[];
  var current = <Cue>[];
  void close() {
    if (current.isEmpty) return;
    out.add(DialogueChunk(current.first.startMs, current.last.endMs, current.map((c) => c.text).join(' ')));
    current = [];
  }

  for (final c in cues) {
    if (current.isNotEmpty) {
      final span = c.endMs - current.first.startMs;
      final gap = c.startMs - current.last.endMs;
      if (span > maxMs || (span > minMs && gap > pauseMs) || gap > silenceMs) {
        close();
      }
    }
    current.add(c);
  }
  close();
  return out;
}
