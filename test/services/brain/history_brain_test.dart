import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/brain/history_brain.dart';
import 'package:plezy/services/history/history_models.dart';
import 'package:plezy/services/history/history_service.dart';

HistoryPlay _film(String at) => HistoryPlay(
  kind: HistoryKind.movie,
  watchedAt: DateTime.parse(at),
  title: 'Film',
  imdb: 'tt1',
  sources: {HistorySource.plex},
);

void main() {
  test('republishing the same history schedules no sync; a new watch schedules one', () {
    final brain = HistoryBrain()..listenForTests();
    addTearDown(brain.stop);
    final state = HistoryService.instance.state;
    void publish(List<HistoryPlay> plays) => state.value = HistoryState(
      history: mergeHistory(trakt: const [], plex: plays),
    );

    publish([_film('2025-01-01T20:00:00Z')]);
    expect(brain.scheduledSyncs, 1);
    // Every load publishes a fresh copy of the same history (the brain's own
    // loads included): nothing to do.
    publish([_film('2025-01-01T20:00:00Z')]);
    publish([_film('2025-01-01T20:00:00Z')]);
    state.value = state.value.copyWith(loading: true);
    expect(brain.scheduledSyncs, 1);

    publish([_film('2025-01-01T20:00:00Z'), _film('2025-02-01T20:00:00Z')]);
    expect(brain.scheduledSyncs, 2);
  });
}
