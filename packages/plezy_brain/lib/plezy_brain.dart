/// The Plezy fork's content brain: a searchable index of what the user has
/// watched and owns (title profiles, embeddings, history queries), and the
/// parked dialogue pipeline. Kept apart from the app: it reaches the host
/// only through small interfaces ([Embedder], [MediaSource]).
library;

export 'src/brain_indexer.dart';
export 'src/brain_store.dart';
export 'src/briefing_facts.dart';
export 'src/dialogue_chunks.dart';
export 'src/embedder.dart';
export 'src/export_job.dart';
export 'src/history_query.dart';
export 'src/media_source.dart';
export 'src/subtitles.dart';
export 'src/taste_summary.dart';
export 'src/title_profile.dart';
export 'src/wikipedia.dart';
export 'src/wordpiece.dart';
