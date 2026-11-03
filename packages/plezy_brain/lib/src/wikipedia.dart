import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// A title's Wikipedia article text: what happens (plot, or premise for
/// shows) and how it was received. Text is CC BY-SA 4.0: keep [url] and
/// [licence] with it, and show them wherever it's quoted.
class WikiText {
  const WikiText({required this.article, required this.url, this.plot, this.reception});

  final String article;
  final String url;
  final String? plot;
  final String? reception;
  static const String licence = 'CC BY-SA 4.0';

  Map<String, Object?> toJson() => {
    'article': article,
    'url': url,
    'plot': ?plot,
    'reception': ?reception,
    'licence': licence,
  };

  static WikiText fromJson(Map<String, Object?> j) => WikiText(
    article: j['article'] as String,
    url: j['url'] as String,
    plot: j['plot'] as String?,
    reception: j['reception'] as String?,
  );
}

/// Fetches [WikiText] for titles by IMDb id: Wikidata maps the id to the
/// exact English article (no title guessing), then the article's plain text
/// gives the Plot / Premise / Synopsis and Reception sections.
///
/// Polite by design: one request at a time, at least [gap] apart, a
/// descriptive User-Agent, backing off on 429 / 5xx and stopping after a
/// few in a row.
class WikipediaClient {
  WikipediaClient({http.Client? client, required this.userAgent, this.gap = const Duration(milliseconds: 500)})
    : _http = client ?? http.Client();

  final http.Client _http;
  final String userAgent;
  final Duration gap;
  int requests = 0;
  DateTime? _last;
  int _busy = 0;

  static const int _maxBusy = 4;
  static final Uri _sparql = Uri.parse('https://query.wikidata.org/sparql');
  static final Uri _api = Uri.parse('https://en.wikipedia.org/w/api.php');

  /// English article titles for IMDb ids (those Wikidata knows), up to 200
  /// ids per request.
  Future<Map<String, String>> articlesFor(List<String> imdbIds) async {
    final out = <String, String>{};
    final ids = [
      for (final id in imdbIds)
        if (RegExp(r'^tt\d+$').hasMatch(id)) id,
    ];
    for (var i = 0; i < ids.length; i += 200) {
      final chunk = ids.sublist(i, i + 200 > ids.length ? ids.length : i + 200);
      final query =
          'SELECT ?imdb ?article WHERE { VALUES ?imdb { ${chunk.map((id) => '"$id"').join(' ')} } '
          '?item wdt:P345 ?imdb . ?article schema:about ?item ; schema:isPartOf <https://en.wikipedia.org/> . }';
      final body = await _get(_sparql.replace(queryParameters: {'query': query, 'format': 'json'}));
      if (body == null) continue;
      for (final b in ((body['results'] as Map?)?['bindings'] as List? ?? const []).whereType<Map>()) {
        final imdb = (b['imdb'] as Map?)?['value'] as String?;
        final url = (b['article'] as Map?)?['value'] as String?;
        if (imdb == null || url == null) continue;
        out.putIfAbsent(imdb, () => Uri.decodeComponent(url.split('/wiki/').last).replaceAll('_', ' '));
      }
    }
    return out;
  }

  /// The plot and reception of [article]; null when it can't be read.
  Future<WikiText?> text(String article) async {
    final body = await _get(
      _api.replace(
        queryParameters: {
          'action': 'query',
          'prop': 'extracts',
          'explaintext': '1',
          'exsectionformat': 'wiki',
          'redirects': '1',
          'format': 'json',
          'formatversion': '2',
          'titles': article,
        },
      ),
    );
    final page = ((body?['query'] as Map?)?['pages'] as List?)?.whereType<Map>().firstOrNull;
    final extract = page?['extract'] as String?;
    if (page == null || extract == null || page['missing'] == true) return null;
    final title = page['title'] as String? ?? article;
    final sections = splitSections(extract);
    String? pick(List<String> names) {
      for (final n in names) {
        final s = sections[n];
        if (s != null && s.trim().length > 80) return s.trim();
      }
      return null;
    }

    return WikiText(
      article: title,
      url: 'https://en.wikipedia.org/wiki/${Uri.encodeComponent(title.replaceAll(' ', '_'))}',
      plot: _clip(pick(['plot', 'synopsis', 'premise', 'plot summary', 'story', 'overview', 'summary']), 6000),
      reception: _clip(pick(['reception', 'critical reception', 'critical response', 'reception and legacy']), 3000),
    );
  }

  /// Top-level `== Heading ==` sections, by lowercased heading (the lead is
  /// under '').
  static Map<String, String> splitSections(String extract) {
    final out = <String, String>{};
    var heading = '';
    final buf = StringBuffer();
    void flush() {
      final text = buf.toString().trim();
      if (text.isNotEmpty) out.putIfAbsent(heading, () => text);
      buf.clear();
    }

    for (final line in const LineSplitter().convert(extract)) {
      final m = RegExp(r'^==\s*([^=].*?)\s*==\s*$').firstMatch(line);
      if (m != null) {
        flush();
        heading = m.group(1)!.toLowerCase();
      } else if (!RegExp(r'^===').hasMatch(line)) {
        buf.writeln(line);
      } else {
        // Subsection headings ("=== Season 1 ===") stay inside their section.
        buf.writeln(line.replaceAll('=', '').trim());
      }
    }
    flush();
    return out;
  }

  static String? _clip(String? text, int max) {
    if (text == null) return null;
    final squeezed = text.replaceAll(RegExp(r'\n{2,}'), '\n');
    if (squeezed.length <= max) return squeezed;
    final cut = squeezed.lastIndexOf('. ', max);
    return squeezed.substring(0, cut > max ~/ 2 ? cut + 1 : max);
  }

  Future<Map<String, dynamic>?> _get(Uri uri) async {
    for (var attempt = 0; ; attempt++) {
      final last = _last;
      if (last != null) {
        final wait = gap - DateTime.now().difference(last);
        if (wait > Duration.zero) await Future<void>.delayed(wait);
      }
      requests++;
      http.Response res;
      try {
        res = await _http
            .get(uri, headers: {'User-Agent': userAgent, 'Accept': 'application/json'})
            .timeout(const Duration(seconds: 60));
      } on TimeoutException {
        res = http.Response('', 504);
      } finally {
        _last = DateTime.now();
      }
      if (res.statusCode == 200) {
        _busy = 0;
        return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      }
      if (res.statusCode == 429 || res.statusCode >= 500) {
        if (++_busy >= _maxBusy) throw const WikiBusyException();
        final retry = int.tryParse(res.headers['retry-after'] ?? '');
        await Future<void>.delayed(Duration(seconds: retry ?? 5 * (1 << attempt)));
        continue;
      }
      return null;
    }
  }

  void close() => _http.close();
}

/// Wikipedia or Wikidata kept saying to slow down: stop for now.
class WikiBusyException implements Exception {
  const WikiBusyException();
}
