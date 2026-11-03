import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/ai/ai_tools.dart';
import 'package:plezy/services/library_index/index_database.dart';
import 'package:plezy/services/library_index/library_index.dart';

void main() {
  test('a history answer that only names titles in its text gets their cards, in its order', () {
    final tools = AiTools(index: LibraryIndex(openDatabase: Future.value(IndexDatabase.memory())));
    tools.noteHistoryTitles(
      'Total: 3 titles (0 films, 3 shows), 300 watches.\n'
      'srv:1 | The Night Desk (2018) | 129 watches\n'
      'srv:2 | Harbour Lights (2013) | 92 watches\n'
      'srv:3 | Desk | 10 watches\n'
      'not on servers | Lost Signal (2001) | 80 watches',
    );
    final cards = tools.cardsNamedIn(
      'Ranked by episodes: Harbour Lights leads with 92, then The Night Desk (129 in total).',
    );
    expect([for (final c in cards) c.id], ['srv:2', 'srv:1']);
  });
}
