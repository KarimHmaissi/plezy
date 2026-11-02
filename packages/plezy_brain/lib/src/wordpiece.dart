import 'dart:convert';

/// One tokenised batch, padded to its longest row: what a BERT-style ONNX
/// model takes as `input_ids`, `attention_mask` and `token_type_ids`.
class TokenBatch {
  const TokenBatch(this.ids, this.mask, this.rows, this.length);

  /// Row-major, [rows] × [length].
  final List<int> ids;
  final List<int> mask;
  final int rows;
  final int length;

  List<int> get typeIds => List<int>.filled(ids.length, 0);
}

/// The uncased BERT WordPiece tokenizer (as bge, MiniLM and friends use),
/// read from a Hugging Face `tokenizer.json`: clean, lowercase, strip
/// accents, split on spaces and punctuation, then greedy longest-match
/// sub-words with `##` continuations.
class WordPieceTokenizer {
  WordPieceTokenizer(this.vocab, {this.maxLength = 256})
    : _cls = vocab['[CLS]']!,
      _sep = vocab['[SEP]']!,
      _unk = vocab['[UNK]']!,
      _pad = vocab['[PAD]'] ?? 0;

  /// From a `tokenizer.json` (WordPiece model) or a `vocab.txt`.
  factory WordPieceTokenizer.fromJson(String source, {int maxLength = 256}) {
    final model = (jsonDecode(source) as Map)['model'] as Map;
    if (model['type'] != 'WordPiece') throw FormatException('Not a WordPiece tokenizer: ${model['type']}');
    return WordPieceTokenizer({
      for (final e in (model['vocab'] as Map).entries) e.key as String: (e.value as num).toInt(),
    }, maxLength: maxLength);
  }

  factory WordPieceTokenizer.fromVocabTxt(String source, {int maxLength = 256}) {
    final lines = const LineSplitter().convert(source);
    return WordPieceTokenizer({for (final (i, w) in lines.indexed) w: i}, maxLength: maxLength);
  }

  final Map<String, int> vocab;

  /// Tokens per text, [CLS] and [SEP] included; longer texts are cut.
  final int maxLength;
  final int _cls, _sep, _unk, _pad;

  static const int _maxWordChars = 100;

  List<int> encode(String text) {
    final out = <int>[_cls];
    for (final word in _words(text)) {
      if (out.length >= maxLength - 1) break;
      out.addAll(_wordPiece(word));
    }
    if (out.length > maxLength - 1) out.length = maxLength - 1;
    return out..add(_sep);
  }

  TokenBatch batch(List<String> texts) {
    final encoded = [for (final t in texts) encode(t)];
    final length = encoded.fold<int>(0, (m, e) => e.length > m ? e.length : m);
    final ids = <int>[], mask = <int>[];
    for (final e in encoded) {
      ids
        ..addAll(e)
        ..addAll(List.filled(length - e.length, _pad));
      mask
        ..addAll(List.filled(e.length, 1))
        ..addAll(List.filled(length - e.length, 0));
    }
    return TokenBatch(ids, mask, texts.length, length);
  }

  List<int> _wordPiece(String word) {
    if (word.length > _maxWordChars) return [_unk];
    final pieces = <int>[];
    var start = 0;
    while (start < word.length) {
      var end = word.length;
      int? found;
      while (start < end) {
        final piece = start == 0 ? word.substring(start, end) : '##${word.substring(start, end)}';
        found = vocab[piece];
        if (found != null) break;
        end--;
      }
      if (found == null) return [_unk];
      pieces.add(found);
      start = end;
    }
    return pieces;
  }

  /// Lowercased, accent-free words and single punctuation marks.
  static Iterable<String> _words(String text) sync* {
    final buf = StringBuffer();
    Iterable<String> flush() sync* {
      if (buf.isNotEmpty) {
        yield buf.toString();
        buf.clear();
      }
    }

    for (final rune in _normalise(text).runes) {
      if (_isSpace(rune)) {
        yield* flush();
      } else if (_isPunctuation(rune) || _isCjk(rune)) {
        yield* flush();
        yield String.fromCharCode(rune);
      } else {
        buf.writeCharCode(rune);
      }
    }
    yield* flush();
  }

  static String _normalise(String text) {
    final out = StringBuffer();
    for (final rune in text.toLowerCase().runes) {
      if (rune == 0 || rune == 0xfffd || _isControl(rune)) continue;
      final base = _stripAccent(rune);
      if (base != null) out.writeCharCode(base);
    }
    return out.toString();
  }

  static bool _isSpace(int c) => c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d || c == 0xa0 || c == 0x3000;

  static bool _isControl(int c) => (c < 0x20 && c != 0x09 && c != 0x0a && c != 0x0d) || (c >= 0x7f && c < 0xa0);

  static bool _isPunctuation(int c) =>
      (c >= 33 && c <= 47) ||
      (c >= 58 && c <= 64) ||
      (c >= 91 && c <= 96) ||
      (c >= 123 && c <= 126) ||
      (c >= 0x2000 && c <= 0x206f) || // General punctuation (dashes, quotes).
      (c >= 0x3000 && c <= 0x303f) ||
      c == 0xa1 ||
      c == 0xa7 ||
      c == 0xab ||
      c == 0xb6 ||
      c == 0xb7 ||
      c == 0xbb ||
      c == 0xbf;

  static bool _isCjk(int c) =>
      (c >= 0x4e00 && c <= 0x9fff) ||
      (c >= 0x3400 && c <= 0x4dbf) ||
      (c >= 0x20000 && c <= 0x2a6df) ||
      (c >= 0xf900 && c <= 0xfaff);

  /// The letter without its accent (Latin-1 and Latin Extended-A), null for
  /// a combining mark, else the character itself.
  static int? _stripAccent(int c) {
    if (c >= 0x300 && c <= 0x36f) return null;
    if (c < 0xc0 || c > 0x17f) return c;
    return _accentMap[c] ?? c;
  }

  static final Map<int, int> _accentMap = () {
    const groups = {
      'a': 'àáâãäåāăą',
      'c': 'çćĉċč',
      'd': 'ďđ',
      'e': 'èéêëēĕėęě',
      'g': 'ĝğġģ',
      'h': 'ĥħ',
      'i': 'ìíîïĩīĭįı',
      'j': 'ĵ',
      'k': 'ķ',
      'l': 'ĺļľŀł',
      'n': 'ñńņňŉ',
      'o': 'òóôõöøōŏő',
      'r': 'ŕŗř',
      's': 'śŝşš',
      't': 'ţťŧ',
      'u': 'ùúûüũūŭůűų',
      'w': 'ŵ',
      'y': 'ýÿŷ',
      'z': 'źżž',
    };
    return {
      for (final g in groups.entries)
        for (final r in g.value.runes) r: g.key.codeUnitAt(0),
    };
  }();
}
