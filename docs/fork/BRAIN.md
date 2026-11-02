# Plezy brain (content indexing)

The AI helper's own knowledge, kept apart from Plezy's core:

1. **Watch history brain** (live): a profile and an embedding for every
   title the user has watched or owns, with structured history queries.
2. **Dialogue** (parked): subtitles cleaned and cut into scene-sized chunks,
   for "what did I miss" later. Too costly to fetch for a whole library for
   now.

## Watch history brain

| Piece | Where | Knows about |
| --- | --- | --- |
| `TitleProfile` | `packages/plezy_brain/lib/src/title_profile.dart` | One film or show: details, watch dates, plays, episodes watched / total, rating, Comfort, watchlist. `embedText` holds only what the title *is* (no watch data), so similar titles cluster whatever the user did with them |
| `Embedder` / `TransformerEmbedder` / `WordPieceTokenizer` | `embedder.dart`, `wordpiece.dart` | Tokenising (token-identical to Hugging Face's BERT tokenizer), CLS pooling, normalising. The host supplies only "run this batch through the model" |
| `BrainStore` | `brain_store.dart` | SQLite (`package:sqlite3`): profiles plus 8-bit vectors per model, brute-force search in memory, incremental (only changed profiles and changed text are touched) |
| `BrainIndexer` | `brain_indexer.dart` | Embeds what's missing, watched titles first, a batch at a time; waits while the host says to pause |
| `HistoryQuery`, `historyStats` | `history_query.dart` | Filters (dates, genres, people, collection, rewatched, show progress, rating, Comfort, watchlist) and grouped counts, for exact answers |
| Plezy adapters | `lib/services/brain/` | `history_profiles.dart` (history + library index → profiles, without loading the whole library at once), `trakt_details_cache.dart`, `onnx_embedder.dart` (flutter_onnxruntime, pinned model download), `history_brain.dart` (the host service), `brain_debug.dart` |
| AI tools | `lib/services/ai/ai_history_tools.dart` | `history_query`, `history_stats`, `similar_titles` for the helper |

Runs on hosts only (Mac, PC, Android TV); a phone mirroring a host asks it.
The index lives in the app's support folder (`brain/`), never in the repo.

## Dialogue (parked)

## Layout

| Piece | Where | Knows about |
| --- | --- | --- |
| `plezy_brain` package | `packages/plezy_brain` | Nothing of Plezy. Pure Dart: subtitle choice and reading, SRT parsing, chunking (about 30–60 s, split at pauses), the export job |
| `MediaSource` | `packages/plezy_brain/lib/src/media_source.dart` | The only way the brain reaches a server: `leaves`, `subtitleStreams`, `fetchSidecar`, `partUrl` |
| Plex adapter | `lib/services/lab/plex_brain_source.dart` | Implements `MediaSource` on an existing `PlexClient` connection, so credentials never leave the app |
| Debug hook | `lib/services/lab/lab_export.dart` | `ext.plezy.labSubtitles`, registered only in debug Mac builds |

Plezy's core gains only the adapter and one line registering the hook
(`main_screen.dart`).

### Getting dialogue

- **Sidecar file** (`/library/streams/{id}.srt?encoding=utf-8`): a small
  download, no playback session. Preferred.
- **Embedded text track**: ffmpeg reads the media part over the LAN and
  decodes only the subtitle stream (`-map 0:{index} -f srt`). It still reads
  much of the file, so it is opt-in (`embedded=true`) and meant for idle
  hours. ffmpeg's errors are dropped, never logged, because the part URL
  carries the token.
- **Image tracks** (PGS, VobSub) and forced (signs-only) tracks are skipped.
  English only for now; plain dialogue is preferred over SDH.

### The export job

`DialogueExportJob` writes, per movie or episode, `<id>.srt` and
`<id>.chunks.json`, plus `manifest.jsonl` and `status.json` to an output
folder outside the repo. It is:

- **Resumable and idempotent**: `status.json` records done / no subtitles /
  failed per item; finished items are never fetched again (`retry` redoes
  the others).
- **Gentle**: a gap between items, and it waits while the host says to
  pause (`shouldPause`; to be wired to "something is playing").
- **Safe with errors**: only error types are recorded, never messages.

Embeddings and search live outside the repo for now (a local lab with a
small local model). No titles, subtitles or index data are ever committed.

## Later: running headless

The package needs only a `MediaSource`, so it can run without the app:

1. A small CLI or service (`dart run`, or compiled) with its own Plex
   sign-in (a PIN-link flow for a token, kept in the OS keychain or the
   service's secret store).
2. A `MediaSource` built on plain HTTP with that token: the same four
   calls as the app's adapter.
3. The same export job, on a schedule, writing to the service's own store;
   embeddings beside it (local ONNX or a hosted model).

That is the path to indexing a large catalogue on a server, with an API in
front, without changing the package.
