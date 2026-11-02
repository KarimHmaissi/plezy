# Plezy brain (content indexing)

The groundwork for AI features that know what actually happens in a title
(search by memory, scene-accurate recaps, reasons behind picks). It reads
dialogue from subtitles, cleans it and cuts it into scene-sized chunks for
an embedding index.

## Layout

| Piece | Where | Knows about |
| --- | --- | --- |
| `plezy_brain` package | `packages/plezy_brain` | Nothing of Plezy. Pure Dart: subtitle choice and reading, SRT parsing, chunking (about 30–60 s, split at pauses), the export job |
| `MediaSource` | `packages/plezy_brain/lib/src/media_source.dart` | The only way the brain reaches a server: `leaves`, `subtitleStreams`, `fetchSidecar`, `partUrl` |
| Plex adapter | `lib/services/lab/plex_brain_source.dart` | Implements `MediaSource` on an existing `PlexClient` connection, so credentials never leave the app |
| Debug hook | `lib/services/lab/lab_export.dart` | `ext.plezy.labSubtitles`, registered only in debug Mac builds |

Plezy's core gains only the adapter and one line registering the hook
(`main_screen.dart`). Nothing else in the app depends on the brain.

## Getting dialogue

- **Sidecar file** (`/library/streams/{id}.srt?encoding=utf-8`): a small
  download, no playback session. Preferred.
- **Embedded text track**: ffmpeg reads the media part over the LAN and
  decodes only the subtitle stream (`-map 0:{index} -f srt`). It still reads
  much of the file, so it is opt-in (`embedded=true`) and meant for idle
  hours. ffmpeg's errors are dropped, never logged, because the part URL
  carries the token.
- **Image tracks** (PGS, VobSub) and forced (signs-only) tracks are skipped.
  English only for now; plain dialogue is preferred over SDH.

## The export job

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
