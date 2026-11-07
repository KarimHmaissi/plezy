/// The Comfort Shows Trakt list keeps which shows are paused (out of the
/// random-episode pool) in its own description, so the state follows the user
/// across devices with a single list and no VIP-only list-item notes:
///
///     Paused in Plezy: Star Relay, Island Hours [plezy:paused=trakt:1234,trakt:5678]
///
/// The bracketed marker is what the app reads; the names are for humans
/// looking at the list on trakt.tv. Any other description text is preserved.
library;

final RegExp _marker = RegExp(r'\[plezy:paused=([^\]]*)\]');
final RegExp _traktId = RegExp(r'^trakt:(\d+)$');

/// Trakt ids of the shows marked paused in [description].
Set<int> parsePausedTraktIds(String? description) {
  final match = description == null ? null : _marker.firstMatch(description);
  if (match == null) return {};
  return {
    for (final token in match.group(1)!.split(','))
      if (_traktId.firstMatch(token.trim()) case final m?) int.parse(m.group(1)!),
  };
}

/// [description] with its paused line replaced to record [paused] (Trakt id
/// to show title, in display order). Drops the line entirely when nothing is
/// paused. Every other line is kept as-is.
String writePausedTraktIds(String? description, Map<int, String> paused) {
  final kept = [
    for (final line in (description ?? '').split('\n'))
      if (!_marker.hasMatch(line)) line,
  ];
  while (kept.isNotEmpty && kept.last.trim().isEmpty) {
    kept.removeLast();
  }
  if (paused.isNotEmpty) {
    final names = paused.values.map((name) => name.replaceAll(RegExp(r'[\[\]\n]'), ' ').trim()).join(', ');
    final ids = paused.keys.map((id) => 'trakt:$id').join(',');
    kept.add('Paused in Plezy: $names [plezy:paused=$ids]');
  }
  return kept.join('\n');
}
