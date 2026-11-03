# Shield Experience — fork changelog

Features and changes in [KarimHmaissi/plezy](https://github.com/KarimHmaissi/plezy)
on top of upstream [edde746/plezy](https://github.com/edde746/plezy). The target
is the NVIDIA Shield (Android TV); development happens on a Windows PC in TV
mode. Newest first. Each entry lists its commit(s) on `dev`.

## Done so far

- [x] Shield remote works on the Windows PC
- [x] Libraries at the bottom of the side nav
- [x] Netflix-style multi-row home, calmer backdrop
- [x] Watchlist page with genre rows (6+ titles per genre)
- [x] PC previews the Shield's real 960×540 layout
- [x] Comfort shows + Random episode (and a dice button on every show)
- [x] Smarter Continue Watching: Continue Watching + Pick back up, older
      on-deck films, 1-year cut-off
- [x] Trakt Lists in Explore: charts, liked lists, Discover lists
- [x] Watchlist Plex / Trakt switch; Comfort "Carry on watching"
- [x] Local database for our customisations, with Backup & transfer in
      Settings (replaces storing them on Trakt)
- [x] Home builder: Home shows only the rows you add, in your order; any
      row anywhere in Plezy can be added; same-title rows merge (synced via
      Trakt)

### AI (merged to `main` on 2026-11-02)
- [x] Library index of every film and show (built on first open, updated
      every 6 hours)
- [x] AI helper core: Sonnet 5.5 for requests, Haiku 5.5 for background
      jobs, tools over the index, history and Trakt ratings, monthly spend
      tracking, key stored encrypted and sent over the home network
- [x] AI tab: Tonight picks, Ask / Follow up, up to 50 picks sized to the
      requests
- [x] Saved answers (up to 200) with Load more; Add to Home, Refresh picks,
      Delete on every AI row
- [x] Requests run in the background with a pulsing chip and nav icon
- [x] "More like this" in any title's long-press menu
- [x] AI rows on Home auto-refresh twice a day on Haiku (max 10 AI rows on
      Home; Settings toggle). Not yet tried on the TV
- [x] Darker, calmer overlay on the TV spotlight backdrop
- [x] Phone as a thin client: AI requests run on the TV, and Play anywhere
      on the phone casts to the TV ("This phone" toggle)
- [x] Now playing on the phone: auto-reconnect, mini bar and a full
      player screen controlling the TV
- [x] Phone mirrors the TV: AI answers as rows, Home and lists, edits go
      to the TV
- [x] Phone on its own: its own key, library index, history brain, Ask
      and Tonight, no TV or Mac needed (mirroring the TV is a switch)
- [x] Google Cast from the phone to any Chromecast, Cast TV or the Shield,
      no Plezy needed on the receiver
- [x] Media notification on the phone for what the TV is playing
- [x] Mac: surround sent to the receiver as Dolby Digital
- [x] Watch history brain: a local index of what you've watched and own,
      with embeddings, for history questions and "like this" picks
- [x] History page with insights, and sending Plex watches to Trakt
- [x] AI page on phones: each answer is a tile at the start of its row,
      opening an answer page; Tonight cards at the top (once a day)
- [x] Phone restyle: style guide, Plex-like side drawer, calmer motion;
      companion link survives sleep

Details of each are in the dated entries below.

## Backlog (not built yet)

### AI
- **Phone remote, v2** — the TV's saved AI answers on the phone, Find more
  from the phone, and play/pause/seek controls for what's casting; maybe
  mirror the TV's Home layout on the phone.
- **Voice requests** — speak a request on the AI tab instead of typing it
  (typed requests are built).
- **Richer context per title (later)** — add more about each title to the
  library index, such as reviews or subtitles (possibly as embeddings), so
  the helper can match on mood, themes and dialogue, not just genre, cast
  and summary.
- **Ask about this title** — from a title's detail page or its hold-OK
  menu, ask the AI about that title ("is it scary?", "do I need to have
  seen the first one?", "more like this but lighter"), with the answer and
  any picks shown on the spot.
- **"Previously on"** — when you go back to a show after a break, a short,
  spoiler-free AI recap of what's happened up to the episode you're on.

### Features
- **Continue Watching from Trakt progress (phase 2)** — use Trakt watch
  progress so "next up" is right even for episodes watched outside these Plex
  servers, and so old shows beyond Plex's On Deck window can appear in "Pick
  back up".
- **Trakt smart lists / saved filters as rows** — the API works on the free
  account; add rows once there are some to show.
- **"On your server" badge** on Watchlist and Explore cards, so you can see at
  a glance what's playable without opening the detail page.
- **Multi-row view on show and movie detail pages** (they still use the
  single-row layout).
- **Shield remote volume buttons on Windows** (currently unmapped).

### Shield & infrastructure
- **Run it on the real Shield** — confirm the layout (`adb shell wm density` /
  `wm size`, expected 320 and 1920x1080) and check playback and the remote.
- **Deployment pipeline to the Shield** — build and push changes from the PC
  to the Shield over adb, with hot reload where possible (the project's
  original goal).
- **Trakt sign-in on auth.trakt.tv** — required by Trakt before 2027-02-01;
  consider registering our own Trakt app instead of upstream's.

## 2026-11-03

### Better Tonight and Suggested picks (Sonnet chooses)
- Tonight's pick and library card were chosen by similarity alone, which
  can match on surface words (Girlfriends for someone who loved Friends).
  Now the brain finds up to 15 candidates for each card and **Sonnet
  chooses** the one that truly fits by genre, tone, story and audience,
  then writes the lines. Titles shown in the last 5 days still wait their
  turn (`AiBriefing.rotate`). About 1 to 2 cents a day.
- Suggested for you lists are now made by **Sonnet** instead of Haiku
  (a few cents per set: once a day, or on New lists).
- Fixed straight after: Sonnet 5.5 refuses `thinking: disabled` (it
  takes `between_tools`, `ClaudeModel.noThinking`), so new Tonights and
  lists failed. Failures now say so ("Couldn't make a new Tonight"), and
  the Tonight cards shimmer while a new set is made.

### AI tab polish
- **Starter prompts:** with a key but no answers yet, the AI tab shows the
  mood chips, Suggested and a few things to ask ("Something cosy for a
  Sunday afternoon"), one tap each, instead of an empty message.
- **Posters slide in:** a new answer's first cards rise in one after
  another; cards built later while scrolling just appear
  (`HubSection.staggerIn`, `ForkEntrance.play`).
- **Pull to refresh** in the app's own colours, without Material's raised
  accent disc.

### Smoothness: no more jumping while things load
- Measured on the Galaxy Fold (120 Hz) with a profile build: scrolling
  Home, the AI tab and grids holds 120 fps, with frames at 1 to 2 ms of the
  8.3 ms budget. The stutter came from debug builds, so test builds on
  phones are now profile builds (`flutter build apk --profile`; release
  needs `android/key.properties`).
- **AI tab appears in one piece:** the saved answers, Tonight, the
  Suggested shelf, the key check (for the mood chips) and the week card
  are read together before the page shows, instead of each popping in
  above the last. No more empty-state flash while the answers are read.
  The week card keeps space for its posters while they load.
- **Home reveals rows top to bottom:** a row shows once every row above it
  in your layout has loaded or come back empty, so a slow row never pushes
  down what you're reading. A placeholder row sits below while more load,
  and after 4 seconds everything shows.

### Voice requests (AI v2)
- **Speak instead of typing:** in Ask, while the field is empty, the send
  button is a mic. A tap opens the system's speech recogniser (Google voice
  input on phones and Android TV) and what you say is sent straight away.
  The recogniser owns the microphone, so Plezy asks for no audio
  permission. Android only; elsewhere the button stays a send button.
- Code: `android/.../VoiceInputChannel.kt`, `lib/services/ai/voice_input.dart`,
  the composer's `_listen`.

### Moods and Your week in watching (AI v2, phase 2)
- **Moods:** a row of chips at the top of the AI page (Cosy, Edge of my
  seat, Something short, Make me laugh, Mind-bending, Background noise).
  A tap asks straight away with a request worded to get a good answer, and
  starts a new conversation. Touch screens and desktop.
- **Your week in watching:** from Sunday to Tuesday, a card at the top of
  the AI page with the week's hours, films and episodes, the shows you
  finished and started, a pattern ("Thursday was your big night", or the
  genre you watched most) and the week's posters. Counted on the device
  from the history brain, so no AI call. The close button hides it until
  next week.
- Code: `lib/screens/ai_moods.dart`, `lib/services/ai/ai_week.dart`,
  `lib/screens/ai_week_card.dart`.

### Suggested for you (AI v2, phase 2)
- **A shelf of ready-made lists** between Tonight and your answers: up to
  6 lists the AI thinks of from your watching ("90s heist films",
  "Short anime to finish this week"), each three posters and a name, so
  you don't have to ask. No tabs: the AI's ideas stay on one row and your
  own lists stay as they are.
- Haiku names the lists and says how to fill each (genres, years, a theme
  word, "like" a title you loved); the app fills them from the library
  index and the history brain, unwatched titles only, so one small call
  makes the whole shelf and a tap opens a list at once.
- **Keep** saves a list into your answers (then Add to Home as usual);
  **Not for me** hides it, and later sets steer away from hidden themes.
- **Cadence:** a new set arrives once a day; the shelf ends in **New
  lists** for a fresh set now; each list's picks are topped up every 12
  hours for free (watched titles drop out, new arrivals that fit come in).
- Lists keep kids' and animated titles out unless they're meant for them
  (a "Sci-fi epics like Dune" list was filling with animated films): the
  prompt asks for it, and a list "like" a live-action title never takes
  animation. Titles to keep out now apply to theme searches too, and a
  list's page says why it suits you once instead of twice.
- Haiku ignored the prompt's advice, so each list now has to say whether
  it is for animation (`none`, `allowed` or `only`), and anything else
  keeps Animation, Family and Kids titles out in code.
- Code: `lib/services/ai/ai_suggestions.dart`, `lib/screens/ai_suggested.dart`.

### AI answers you can act on (v2, phase 1)
- **History answers always bring their cards.** "My most watched shows"
  came back as text only. The answer tool now asks for every listed title
  in order with its count as the note ("129 episodes"), and if the model
  still only names titles in its text, the cards are filled in from the
  titles the history tools returned, in the order the text names them.
- **Saved answers show without a key.** The "add your key" page only
  appears when there's nothing saved; otherwise Ask leads to Settings ▸ AI.
- **A slow server can't hold up a row.** Each pick (and each Tonight card)
  gets 8 s to load; one that doesn't answer is dropped.
- **Motion:** answer rows rise in one after another as the page opens and
  as a new answer lands; Tonight deals its cards in one by one, with a
  light haptic tick when a new set arrives; a request's tile has a soft
  light sweeping across it while it works, and each step ("Checking your
  history") rises in over the last. Shared pieces: `ForkEntrance` and
  `ForkShimmer` (`lib/widgets/fork_motion_widgets.dart`), all still when
  the system asks for less motion.

### Tonight changes from day to day
- Tonight always showed the same titles: each card took the single best
  match, so a refresh only re-worded the lines. Now each card is drawn from
  the best 8 candidates (the best still likeliest), and a title shown in
  the last 5 days waits its turn while there are others. Pull to refresh
  brings different titles.

### Google Cast from the phone
- **A Cast button in the phone's top bar** (Android phones with Google Play
  services), next to Search. It lists the Chromecasts, Cast-enabled TVs,
  Google TVs and the Shield on the Wi-Fi; pick one and every Play casts
  there until you stop casting. Nothing has to be installed on the
  receiver: it plays in Google's own Cast player (the Default Media
  Receiver).
- **The stream comes from the Plex server**, made for Cast: HLS with H.264
  video and AAC stereo. A file that already fits (H.264, up to 1080p) is
  only repackaged; anything else (HEVC, 4K, 10-bit, surround) is
  transcoded to 1080p. Subtitles: the one selected for the file in Plex is
  burned in. No server settings change.
- **Plex stays in step.** The phone reports the Cast device's progress to
  Plex every 10 s and when it pauses or stops, so resume points, Continue
  Watching and watched state are right, and the stream shows on the Plex
  dashboard. Closing Plezy keeps it casting; reopening it picks the
  session back up.
- **Controls:** a mini bar over the bottom bar while casting (play/pause,
  tap for more) and a full screen with seek, back 10 s, forward 30 s,
  Stop and Stop casting. The Cast SDK adds its own notification and
  lock-screen controls.
- A Google Cast device wins over the companion "Play on TV" while both are
  connected.
- Code: `android/.../plezy/cast/` (official Cast SDK 22.3.1; 23.x needs
  compileSdk 37), `lib/services/google_cast/`,
  `lib/providers/google_cast_provider.dart`,
  `lib/widgets/google_cast_sheet.dart`, `PlexClient.buildCastStreamUrl`.

### The phone works on its own
- **Phones are hosts now, by default.** The phone has its own API key,
  library index, watch history brain (embeddings included), Home, lists
  and saved AI answers. Ask, Follow up, Tonight, More like this, Ask about
  this title and Home auto-refresh all run on the phone, with no Mac or TV
  needed. Casting, Now playing and the remote still work when it's
  connected to a TV.
- **First start copies what it mirrored.** A phone that used to mirror a
  TV copies the last snapshot it kept (Home, lists, AI answers) into its
  own database once, only if that database is empty.
- **Settings ▸ AI ▸ Use the TV's AI** (phones only, off by default) brings
  back the old thin client: the TV's AI, Home and lists, edits sent to the
  TV. It switches straight away, without a restart.
- **The embedding model waits for Wi-Fi** on phones (it's 66 MB). History
  questions work meanwhile; similarity search starts once it's in.
- **Receive key from another device on a phone:** the one-time page picks
  the Wi-Fi address, never a private mobile data address, so it opens from
  the Mac's browser. Its wording no longer assumes the other device is a
  phone.
- New `PhoneMode` (`lib/services/companion_remote/phone_mode.dart`) is the
  one place that decides; the AI tab, Ask about, the index start on Home
  and mirroring all ask it.

## 2026-11-02

### Tonight on the AI page (phones and desktop)
- Three wide cards at the top: **New episode** (a show you're partway
  through with episodes you haven't seen, newest additions first),
  **Tonight's pick** (the strongest unwatched match for what you love,
  rated 7+, a film of 80-150 minutes or a show) and **From your library**
  (rated 8+, critics 7.5+ when known, on the server a year or more).
- Titles come from the history brain and the local library index, with no
  server crawl; Haiku writes one line per card. Made on the host once a
  day (about 2 s, well under a cent) and mirrored to the phone.
- Pull to refresh reloads saved answers for free, then asks "Make a new
  Tonight?" (No / Yes) before spending a model call. A phone asks the host.
- Replaces the daily briefing; the TV keeps its Tonight row.

### AI answers as a tile and a page (phones and desktop)
- The answer text left the page: each answer row starts with a tile (the
  top pick's art under a scrim, what you asked, the headline, "Read" and
  the pick count). Running and failed requests show as the same tile.
- The tile, or the row's title, opens the answer page: the question, the
  headline, the overview, Top picks and Worth a closer look (poster, title,
  year, why), notes, follow-up chips, every pick as a grid, and the row's
  actions under ⋯.
- Reasons that start with their own title drop it ("It has…").

### AI answers on the AI page (first version, replaced by the tile above)
- Each answer is one block on phones and desktop: the row title, what you
  asked, a 3-4 sentence overview, the top pick(s) and a few spotlighted
  titles, "worth knowing" notes and follow-up chips, then the posters.
  Older answers fold to their first sentence. A hairline separates blocks.
- Answers stream: the block appears as soon as you send, shows what the
  helper is doing, and writes the overview as it comes. Failures say so
  with Retry. The phone gets the same progress from the TV.
- Posters carry "Top pick" and Watched / In progress / Rewatch badges (from
  the history brain).
- Long-press a pick on the phone for a peek: why it was picked (written on
  demand with a small Haiku call for picks past the first ten, saved with
  the answer), Play, Watchlist and Details.
- Faster: your watching is summarised in the first prompt, lookups run in
  parallel, tool results use short title handles, and only the first ten
  picks get reasons. A broad ask fills 30+ picks in about 15-20 s (it was
  30-60 s); short rows are topped up from what the lookups found.
- The brain's heavy work (embedding, vector search, building profiles) runs
  off the app's isolate, and warms up 30 s after start.

### Watch history brain (branch `feature/ai-helper`)
- A local index of everything you've watched and everything on your servers,
  built on the host (Mac, PC, TV) and kept up to date as watches arrive.
- One profile per film or show, from the merged Plex + Trakt history the
  History page shows: watch dates (imports and "mark as watched" bursts
  counted as undated), plays, rewatches, episodes watched against the total
  (finished, in progress, dropped), your Trakt rating, Comfort and watchlist.
  Details come from the library index; only titles not on the servers ask
  Trakt (once, cached, at most one request a second, backing off on 429).
- Unwatched library titles get profiles too, so "like this" finds things
  you own.
- Embeddings run in the app with ONNX Runtime (bge-small-en-v1.5, 384
  dimensions, downloaded once and checked by SHA-256), stored in SQLite as
  8-bit vectors and searched in memory. Indexing pauses while something
  plays. Phones don't index; they ask the host.
- The engine lives in `packages/plezy_brain` (tokenizer, embedder
  interface, store, indexer, history queries); Plezy supplies the adapters
  in `lib/services/brain`. Debug builds expose `ext.plezy.brain` for raw
  queries.

### Content brain groundwork (debug only)

- New `packages/plezy_brain`: picks and reads a title's English dialogue
  (sidecar subtitle files; embedded text tracks via ffmpeg, opt-in), cleans
  and chunks it into scene-sized pieces, and runs a resumable, idempotent
  export job. It reaches a server only through its `MediaSource` interface.
- Plezy supplies one adapter (`PlexBrainSource`, on the app's existing
  connection, so credentials stay in the app) and a debug-only Mac hook,
  `ext.plezy.labSubtitles`, that exports to a lab folder outside the repo.
  Release builds never register it. See `docs/fork/BRAIN.md`.

### More air under the top bar on phones

- Every page with the standard top bar (AI, Comfort, Explore, Watchlist,
  Libraries, History, Search, Downloads, View all, Settings) gets
  `ForkSpacing.headerGap` below it, so the first row isn't cramped. Home's
  hero header is unchanged.

### Phone navigation like Plex: side drawer

- Every phone tab's top bar is the same: its own primary action, then
  Search, the companion remote and the avatar. The avatar opens a side
  drawer from the right (profile, Libraries, History, Downloads, Watch
  Together, Refresh, Profiles, Settings, Log out, plus the tab's extras).
- Bottom bar: Home, Comfort, Explore, Watchlist, AI. Libraries moves into
  the drawer; Comfort is always there on phones.
- Comfort without Trakt: the Trakt-connected device keeps a copy of its
  comfort list locally (setting `comfort.shows`), which mirroring phones
  receive with the snapshot; a phone shows those shows, Random episode and
  pausing work. Connect Trakt is offered only when there's no list at all.
- Configure on a phone without Trakt: while connected, adding (searched in
  the phone's own catalog) and removing shows goes to the TV/Mac, which
  changes its Trakt list and sends the new list back; read-only offline.

### Calmer motion and Plex-like card text

- Ask opens with a short fade-and-rise (260 ms in, 200 ms out, Material 3
  emphasized curves) instead of the camera-iris expand; the keyboard opens
  once the motion has settled. Shared motion tokens in `ForkMotion`; Android
  page pushes use one explicit transition (fade forwards).
- Card captions on touch and desktop follow Plex: a regular-weight 15 title
  8 dp below the artwork and a 13 muted subtitle with room to breathe; rows
  size their cards from the measured caption band. TV unchanged.
- Row titles are smaller and semibold (17 phone, 19 tablet, 20 desktop);
  icon and chevron match. History and AI section titles follow.
- Style guide: motion tokens and caption metrics.

### One visual language: style guide, AI and History restyled (branch `feature/ai-helper`)
- `docs/fork/STYLE-GUIDE.md`: where styling lives (theme, palette tokens,
  ForkSpacing, TV constants), colour roles, type per role, spacing and
  radii, which component to use for what, and do/don't. New screens use
  theme values only, no colour or font literals.
- History and the AI screens (composer, answers, Ask about this, Previously
  on) now use the theme font and text styles, the palette's colours and
  accent (no amber, no Bebas, no pure black), the standard tab header and
  spacing, and the standard chips, cards and buttons. Their motion (iris,
  film strip, Pressable, haptics) is unchanged.
- Phone: History no longer appears as a sixth bottom-nav tab while open; it
  opens from Home's top bar and Home stays highlighted.
- History: a season or show marked watched at once (4+ watches within 2
  minutes) now counts as a bulk date too, so it no longer fills the
  timeline with "random" episodes.

### History: send Plex watches to Trakt (branch `feature/ai-helper`)
- A "Send Plex watches to Trakt" button under the History hero (Trakt
  connected) opens a preview first: how many films and episodes would be
  added, by year, the first few, and what's skipped (already on Trakt,
  mark-as-watched dates, no IMDb/TMDB/TVDB id). Nothing is written until
  "Send to Trakt" is tapped.
- Only Plex watches with real dates that Trakt lacks are sent, each with
  its Plex date to the minute (Trakt deduplicates item + date, so a resend
  adds nothing). Batches of 100, about one write a second, waiting out
  rate limits.
- The history entries a send created are recorded on the device, and
  "Undo last send" removes exactly those (by history id), nothing else.

### History page: insights (branch `feature/ai-helper`)
- Between the month strip and the timeline: the longest binge (episodes of
  one show in a day), top genres as bars, directors and actors as cards with
  a fanned stack of their posters, "Watched again" with ×N badges, and films
  by release decade. All follow the year chips; tapping opens the title.

### History page, v1 (branch `feature/ai-helper`)
- **Where:** a History item in the TV/Mac side nav, and a clock icon in the
  phone's Home top bar.
- **Data (read-only):** Trakt's full watch log plus Plex's last-viewed date
  of every watched film and episode (one filtered request per library page,
  paced), cached on the device; Trakt updates incrementally, Plex every 6 h.
- **Merging:** one entry per watch, matched by IMDb/TMDB/TVDB ids (Plex
  episodes without show ids borrow a same-named Trakt show's). Dates that
  aren't viewings are detected: bulk imports and mark-all-watched (15+
  watches within 10 minutes) and Trakt's "watched on release day". When one
  side has such a date and the other a real one, they're the same watch on
  the real date. Bulk-dated watches count in All time only.
- **Page:** year chips (and All time); a hero with hours, films, episodes
  (and shows), day streak and best; a films-vs-TV hours bar; a month-by-month
  (or year-by-year) bar strip; then a timeline by month with posters and
  Plex/Trakt badges. Tapping opens the title (library copy first, else its
  catalog page). Notes say what's approximate (Plex keeps only the latest
  watch per title; estimated runtimes; bulk and undated watches).

### Library rows to Home on the phone (branch `feature/ai-helper`)
- Long-press any card in a library's Recommended rows (Rediscover, Recently
  added, …) for "Add to Home" / "Manage Home", as the TV already had.

### Companion link survives sleep (branch `feature/ai-helper`)
- **Cause:** after the Mac slept, its remote server kept listening but the
  LAN beacon the phone uses to find it was gone (no UDP sockets left in the
  process), and the phone only ever looked for that beacon for 12 s, so it
  never reconnected. A fresh app process brought the beacon back.
- **Host:** the beacon now re-binds and re-advertises by itself when the OS
  closes its sockets, a send fails, the LAN address changes, connectivity
  changes, the app resumes, or a wake is detected (a beacon tick arriving
  late), with a 30 s address check as a backstop. Each re-bind logs why.
  The shown host addresses follow a new IP.
- **Phone:** auto-connect falls back to the host's last working ip:port
  (saved per host, checked against its id) when no beacon is heard, then
  retries with backoff (15 s doubling to 2 min) while the app is open, and
  starts again on resume and on Wi-Fi changes.

## 2026-11-01

### Phone: tap a row's title for See all (branch `feature/ai-helper`)
- **Android phones:** tapping the title of any row with items (Home,
  Discover, AI tab, Watchlist, Comfort, Explore, Trakt lists) opens the
  full-screen See all grid of that row, with the title and a back button.
  Before, only rows the server pages had a tappable title; now every row
  shows the › chevron. Cast rows excepted. A selection tick on tap.
- **AI rows:** the See all page keeps the row's Load more as a button
  under the grid, and follows the row as new picks land (also in mirror
  mode). Picks open like they do in the row (the phone's pick rule), and
  the row's long-press entries (Add to Home, Play on TV…) carry over.
- `HubDetailScreen` gains `liveHub`, `footer` and `onItemTap`. TV and Mac
  unchanged.
- One Back leaves See all on phones and tablets (before, the first Back
  only scrolled the grid to the top). TV keeps its app-bar-first Back.

### Previously on (branch `feature/ai-helper`, backlog #42)
- **Where:** a "Previously on" button on a show's page (for the episode
  Play would start) and on an episode's page, and in the long-press menu
  of any episode (Continue Watching, Pick back up, episode lists). Hidden
  at S1 E1, where there's nothing to recap. Optional, never automatic.
- **What:** the cinema composer opens with "<show> · S2 E5" and starts the
  recap straight away; the answer card is headed "Previously on". Quick
  follow-ups: Shorter, Just the last episode, Who's who?, or type one.
- **Spoiler line:** every request, follow-ups included, states that only
  up to the episode before is known and forbids anything from the next
  episode on (events, deaths, reveals, characters, hints), and to leave
  out anything it's unsure about. Tested in
  `test/screens/ai_previously_on_test.dart`.
- **Phone:** runs on the connected TV app like Ask about this.

### Ask about this title (branch `feature/ai-helper`, backlog #43)
- **Where:** an "Ask about this" button on film and show pages, and in
  every film/show/episode long-press menu (episodes and seasons ask about
  their show), on phone, TV and Mac.
- **What:** the cinema composer opens over the page with an "About: …"
  chip and its own quick questions: Is it worth watching?, Anything like
  this?, Who's in it?, Is it scary or kid-friendly?, and Where should I
  start? for shows. Or type anything.
- **Answer:** after the film strip, a "Programme notes" card with a short,
  spoiler-free answer (the helper looks the title up in the library index
  and its Plex details), with Done and Ask another. Recommendation
  questions also save a row of picks to the AI tab and freeze on the top
  one first; other questions save nothing.
- **Phone:** the question runs on the connected TV app (its key and
  index), which answers on the AI channel with the text (`text`) or the
  saved row (`done`).

### Highest-bitrate copy by default (branch `feature/ai-helper`)
- **Opening a title** that's in the library from Explore (and its related
  rows) goes straight to its library page on the copy with the highest
  bitrate (then resolution) on a server that's online, instead of the
  copy list. Titles not in the library, or a lookup slower than 3 seconds,
  still open the Explore page. The long-press menu's "Details and all
  copies" opens the full list to choose by hand.
- **AI picks on the phone** open the highest-bitrate reachable copy (no
  "Which copy?" sheet).
- **Play** uses the highest-bitrate version when nothing is chosen or
  remembered; a saved version preference, a download or "Play version"
  still win.
- `bestLibraryCopy` / `bestVersionIndex` in `media_item_merge.dart`, with
  tests.

### Phone: compact bottom bar and solid headers (branch `feature/ai-helper`)
- **Bottom bar** about 58dp (was ~84): 24dp icons over 12sp labels, the
  current tab in the accent colour and the rest muted, no pill.
- **Mini cast bar** about 52dp (was ~66): smaller art, tighter lines,
  compact buttons.
- **Headers** that float over content (Discover, Watchlist, Comfort,
  Explore…) are solid on phones, so rows scrolled under them no longer show
  through; Discover keeps its artwork under the header until you scroll.
- TV unchanged.

### AI composer: Continue browsing (branch `feature/ai-helper`)
- While the film strip runs, an amber "Continue browsing" button under it
  closes the composer like ✕ (focused on TV, a tick on the phone); the
  request keeps running and lands in the AI tab.

### Fix: TV playback notification lost when paused (branch `feature/ai-helper`)
- The phone's link to the TV can drop for a moment while its screen is
  off; that cleared what's playing and with it the notification, and on
  reconnecting to a paused TV the media service never started (it only
  starts on a playing state, then keeps its notification through pauses).
  Now a dropped connection keeps the notification for 45 seconds, and one
  first shown paused starts the service with a playing beat, so a paused
  film keeps its notification and lock-screen controls with a Play button.

### Phone: AI picks open their page (branch `feature/ai-helper`)
- Tapping a pick on the phone's AI tab (mirror mode and the plain remote
  AI screen) now opens the title's page like a card anywhere else, instead
  of playing it on the TV at once. The pick is looked up on the phone's own
  server connections by its Plex guid; a title on more than one server
  asks "Which copy?" first. Play on that page casts while connected, or
  plays on the phone.
- "Play on TV" stays as a quick option in the pick's long-press menu
  (`ItemMenuEntries`: per-item menu entries a screen can add).
- TV and Mac AI rows already opened the page; unchanged.

### Touch polish, round two (branch `feature/ai-helper`)
- **Play / Resume** (film and show pages, and Play Version): presses in
  and ticks.
- **Seasons and episodes:** season chips press in (with the long-press
  sink and tick before their menu) and tick when chosen; episodes tick on
  tap on top of their press-in.
- **Settings:** every switch, segmented choice and other setting write
  ticks; sliders tick at each step as you drag (every 5% without steps).
- **Adding:** a light tap when a Comfort show is added; adding rows to
  Home already taps through its success message.
- **Pull to refresh** (Watchlist, Comfort, Explore, library tabs): a
  tick when you let go past the threshold (`ForkMotion.refreshing`).
- All phone-only, through `ForkMotion` and `Pressable`.

### Load more at the end of AI rows (branch `feature/ai-helper`)
- **Load more card:** every AI answer row (not Tonight's pick) ends in a
  poster-sized "Load more" card, on TV (D-pad), Mac and the phone
  (including mirror mode, where the TV runs it). Activating it ticks
  (phone), turns the card into a "Finding more…" spinner and asks the
  same request again without the titles already shown; the new picks are
  added to the end of the row (no repeats, capped at 200). It runs in the
  background: scroll, open other rows or leave the screen meanwhile.
- When nothing new fits the card says "No more matches"; on a failure it
  becomes Retry. Long-press "Find more" still puts its batch in front.
- The phone's request carries an id and the TV answers `done` / `none` /
  `error` on the AI channel; the picks arrive with the mirror snapshot.
- `HubSection.trailingCard` and `TvRailTrailing.loadMore` / `findingMore`
  / `noMore` are the reusable parts.

### AI composer on short screens; keyboard gap fix (branch `feature/ai-helper`)
- **Fold cover screen:** below ~620dp of height (the cover screen, or any
  phone with the keyboard up) the composer anchors above the keyboard: a
  one-line headline (36-46sp), no "Quick start" label, chips fully
  visible; under ~470dp the eyebrow and mark go too. Close moved to the
  top right (48dp) clear of the text. The send key is solid amber with
  text and an amber outline on black when empty, never see-through. The
  poster wall is mostly desaturated and dimmed with a darker scrim behind
  the content. The film strip scales to a third of the height.
- **Stale keyboard gap:** switching apps with the composer's keyboard up
  could bring the app back with the bottom bar and cast bar pushed
  halfway up. The main shell no longer resizes for the keyboard (screens
  with fields resize themselves), and the composer puts the keyboard away
  when the app pauses and when it closes (test added).
- **Press feedback fix:** `Pressable` passes its child's constraints
  through unchanged (it had loosened them, shrinking the composer chips).

### AI composer, cinema cut 2 (branch `feature/ai-helper`)
- **Iris from the Ask button:** the iris now opens centred on the button
  you pressed, sized to clear the furthest corner.
- **Self-drawing mark:** next to the eyebrow an amber aperture ring draws
  itself, then six blade lines, then a play triangle that fills in
  (about 400 ms, traced along the paths).
- **Clapper:** on send a clapperboard beside the slate snaps shut with a
  haptic tick, and claps again (silently) on each new take.
- **Jam and Retry:** a failed request (or the TV not answering in three
  minutes) stops the strip dead with a decaying shudder and a firm haptic;
  the gate and slate turn red ("FILM JAMMED") with the reason, Retry
  (focused, so the remote's select retries) and Edit. A retry replaces
  the failed attempt's chip in the AI tab.

### AI composer, cinema cut (branch `feature/ai-helper`)
- **Iris open:** Ask opens the composer through a seven-bladed camera iris
  (260 ms, light haptic); the poster wall fades in a beat later, then the
  headline, input and quick starts rise in turn. Closing shuts the iris.
- **Type:** Bebas Neue (OFL, `assets/fonts/bebas_neue`) for a big tight
  headline ("What are we watching?"), amber the only accent; the input is
  big type on an amber rule with a play-key send; quick starts are ticket
  stubs. The aurora glow and orb are gone.
- **Thinking:** a 35mm strip of your own posters (sprocket holes, soft at
  speed, no live blur) races through a projector gate, with slate lines
  Take 1 / Take 2 / Take 3 as time passes.
- **Landing:** when the answer arrives the strip slows from its running
  speed and stops with the answer's top pick sharp in the gate, a
  freeze-frame flash and a haptic, its title underneath, then closes onto
  the new row. Reduced motion skips to fades.

### Touch polish: press feedback and haptics (branch `feature/ai-helper`)
- **Cards press in:** posters and episodes sink slightly and dim on touch,
  sink further with a haptic tick when a long press lands (the context menu),
  and spring back on release. Scrolling a row cancels it. Off on TV.
- **Haptics:** a selection tick on bottom tabs, the cast bar's play/pause
  and open, and the phone remote's buttons; a light tap on adding to the
  watchlist and on success messages; a firm one on errors. Phones only.
- Shared timings and curves in `lib/theme/fork_motion.dart`, the press
  wrapper in `lib/widgets/pressable.dart`.

### Full-screen AI composer (branch `feature/ai-helper`)
- **Ask opens a full-screen composer** on TV, Mac and phone instead of a
  small text dialog: a slowly drifting mosaic of your own posters (fetched
  tiny and scaled up, so it's soft without a live blur), an accent-coloured
  glow, a large headline and input, and example asks that type themselves
  into the placeholder.
- **Quick starts:** Tonight's pick, Based on my history, Hidden gems,
  Feel-good, Random film, plus your last five asks. One tap or select sends.
- **Thinking orb:** on send the input turns into a pulsing orb with rotating
  status lines until the answer lands. Closing (Back, ✕ or swipe down) keeps
  the request running; it lands in the AI tab as before. On the phone the
  request runs on the TV as usual.
- D-pad: the input is focused on open, Right goes to Send, Down to the
  chips. Reduced motion stops the drift, glow and typing.

### Fix: phone AI tab's Ask did nothing (branch `feature/ai-helper`)
- Top-bar actions drawn with a custom label (Ask, Follow-up, retry chips)
  had no tap handler, only D-pad select, so on a touch screen they did
  nothing. They now take taps too.
- On the phone, Ask is never a dead button: when not linked to the TV it
  says so and reconnects.

### Mac: surround as Dolby Digital (branch `feature/ai-helper`)
- **Why.** On the MacBook's HDMI port, 8-channel PCM reached the receiver
  with its channels rotated by a whole slot or more (centre on a front
  speaker, two channels on one surround), and the offset changed whenever
  the HDMI link re-synced. No speaker layout on the Mac can fix that.
- **What.** On macOS Plezy now re-encodes decoded audio to Dolby Digital
  5.1 at 640 kb/s (mpv `lavcac3enc`) and sends it as a bitstream; the
  receiver places each channel itself. Stereo and up go this way; 7.1 is
  folded to 5.1. Setting: Playback ▸ "Send surround as Dolby Digital",
  on by default on macOS only.
- **Passthrough is off on macOS.** It never bitstreamed there, and each
  try switched the HDMI output's format and back, re-syncing the link.

### Notification for what the TV is playing (branch `feature/ai-helper`)
- **Pause from the shade.** While the TV app the phone is connected to is
  playing, the phone shows a media notification (shade, lock screen,
  Samsung's quick panel player): artwork, title, progress, play/pause,
  ±10 s, previous/next episode and seek. The buttons send remote commands
  to the TV; it goes when playback stops or the phone disconnects.
- **Same session as the phone's own playback.** It uses the media session
  and foreground service the video and music players already use. When
  the phone plays something itself, that takes over the notification
  (`LocalMediaSession`), and the TV's comes back after.
- Tapping it opens Plezy, where the mini player is.

### Phone mirrors the TV (branch `feature/ai-helper`)
- **The TV is the one copy.** While connected, the phone shows the TV's
  customisation data: AI answers, Home layout, Comfort pauses, Shortlist
  and the fork's content settings (AI auto-refresh, Watchlist source). The
  TV sends it all on connect and again after every change (about 500 KB,
  versioned). Device settings (playback, quality, theme, subtitles,
  downloads) stay per device.
- **Edits from the phone go to the TV**, which applies them and sends the
  new data to every connected phone: deleting an AI answer, Add to Home /
  remove / reorder on Home, Comfort pauses. The phone shows each edit at
  once rather than waiting for the round trip.
- **AI tab on the phone** now looks like the TV's: one horizontal row per
  saved answer, newest first, with Load more. Ask sends the request to the
  TV (a chip shows it running); its row appears on both devices. Find more
  and Refresh picks run on the TV. A request started on the TV shows a
  "TV is working…" chip on the phone, then its row. Tapping a film or
  episode plays it (on the TV while casting); a show opens its page.
- **Offline:** the phone keeps the last copy in its own cache file
  (`tv_mirror.json`, never its own database) and shows it read-only with
  "Not connected to <TV>"; Ask and row actions are off until it reconnects.
  A phone that has never connected to a TV keeps using its own data.
- New remote commands, appended: `mirrorRequest`, `mirrorSnapshot`,
  `mirrorWrite`, `aiAction`, `aiActivity`.

### Now playing on the phone (branch `feature/ai-helper`)
- **Auto-reconnect:** the phone remembers the TV app it last connected to
  and reconnects quietly when Plezy opens or comes back to the front, if
  the TV is on the network. The Disconnect button on the remote screen
  turns this off until you connect again.
- **Live state from the TV:** while it plays, the TV sends what's playing,
  the position (every second; every 5 s when paused), play/pause/buffering,
  the audio and subtitle tracks, whether Skip intro / Skip credits is up,
  and whether there's a previous/next episode; "stopped" when it ends.
- **Mini bar:** the bar above the phone's nav becomes a mini player with
  the episode still (or the film's backdrop), title, a thin progress line,
  a cast toggle and play/pause. Tap it for the full screen.
- **Now-playing screen:** large artwork, title and "S1 · E5 · name", a
  scrubber with elapsed/remaining that seeks when you let go, play/pause,
  back/forward (Plezy's skip step, 10 s by default), previous/next episode,
  Skip intro / Skip credits when the TV shows them, audio and subtitle
  pickers, and Stop. Artwork and controls sit side by side on the unfolded
  screen and stack on the cover screen.
- Play/pause from the phone now controls the TV's player directly instead
  of simulating a key press, so it works whatever has focus.
- The TV shows under its device name instead of "Desktop" after a
  reconnect.
- New remote commands, appended: `nowPlaying`, `seekTo`, `selectTrack`.
  Skip intro/credits use the existing commands, which now do something.

### Phone as a thin client: AI on the TV, casting everywhere (branch `feature/ai-helper`)
- **AI tab on the phone** talks to the TV app it's connected to: "AI on
  <TV name>", a text box (keyboard dictation works), a working indicator,
  then the picks with poster, year and reason. The request runs on the TV
  with its key and library index and is saved in the TV's AI history (it
  shows up as a new row on the TV's AI tab). The phone never asks for an
  API key; not connected, it says "Connect to your TV to use AI".
  Tap a pick to play it on the TV; hold for "Show on TV" (opens its page
  there) or "Play on this phone". "More like this" on the phone goes to the
  TV too.
- **Casting from any tab:** while the phone is connected, Play anywhere
  (Home, Libraries, Search, Comfort, Watchlist, Continue Watching, detail
  pages, episodes) plays on the TV instead, resuming from the same point;
  "play from start" and explicit positions travel with it. Detail pages
  stay browsable on the phone. A bar above the phone's nav shows "Playing
  on <TV>" and the last title started; tap it to switch to "This phone"
  and back. Failures (title not on the TV's servers) show as a message.
- New remote commands, appended so older builds ignore them: `aiAsk`,
  `playMedia`, `openItem`, `castResult`, `aiAnswer`.
- The phone's Home is still its own (empty) layout; the customisations
  live in each device's local database.

### Find more on AI answers, bigger lists (branch `feature/ai-helper`)
- **Find more** in the hold-OK menu of any saved AI answer (AI tab). It
  re-asks the same request on Sonnet for *different* titles and puts the
  new batch at the start of the row, keeping the old picks below. It runs in
  the background like any request (pulsing chip, retry on failure), and if
  nothing new fits it says "No more matches". Repeats are filtered out in
  code too; an answer keeps at most 200 picks. Saved like any answer, so it
  survives restarts and backups and shows on Home if the row is pinned.
- **Home auto-refresh adds to extended rows.** A pinned answer that's been
  grown with Find more isn't replaced twice a day: Haiku adds up to 10 new
  picks in front instead (same 200 cap). Other rows are replaced as before.
- **Bigger lists by default:** broad requests now aim for about 30–40 picks
  and list-style asks ("every…", "all…") for 40–50. Narrow requests still
  return only the true matches. Tonight (6–10) and Home auto-refresh (≤20)
  are unchanged.

### AI answers sized to the request, up to 50 (branch `feature/ai-helper`)
- **The AI decides how long a list should be**, up to 50 picks: 30–50 for
  big list-style asks (a whole genre, an era, a franchise, "all the X on my
  server"), about 15–25 for typical broad requests, and only the true
  matches for narrow ones ("a random X", a specific title). It never pads a
  list. 50 is a hard cap in code.
- `find_titles` now checks up to 50 titles per call, so big lists don't need
  extra steps.
- **Unchanged:** Tonight stays at 6–10 picks, and auto-refreshed Home AI rows
  are kept to 20 or fewer so refresh costs stay small.

### Auto-refreshing AI rows on Home (branch `feature/ai-helper`) — `48aee5ba2`
- **AI rows on Home refresh themselves twice a day** while Plezy is open
  (there's no background service). Plezy checks 30 s after Home opens and
  then hourly.
  - Any Home AI row whose picks are 12 hours or more old re-runs its request
    on **Haiku 5.5**, one row at a time, quietly.
  - It keeps the 15–20 rule, leaves out what you've watched and prefers
    titles that weren't in the last version. The row keeps its name.
  - Home and the AI tab swap in the new picks. If a refresh fails, the old
    picks stay and it tries again at the next hourly check.
  - Rows that are only on the AI tab never auto-refresh. Manual **Refresh
    picks** still uses Sonnet.
- **At most 10 AI rows on Home.** Adding an 11th says "Home already has 10
  AI rows. Remove one first." Nothing is dropped silently.
- **Settings ▸ AI ▸ Auto-refresh AI rows on Home** (on by default). The
  monthly spend line now shows how much of it went on auto-refresh. Debug
  builds also have "Auto-refresh Home AI rows now", which skips the 12-hour
  wait for testing.
- **Not yet tried on the TV** (Karim had to leave): it compiles, `flutter
  analyze` is clean and the AI tests pass. Still to do: run one forced
  refresh from Settings to check it end to end and measure what a Haiku
  refresh costs (expected about $0.001–0.002).

### "More like this" from any title (branch `feature/ai-helper`) — `9ea216b38`
- **Hold OK on any film or show** (Home, Explore, Watchlist, libraries, AI
  rows…) and pick **More like this**. Episodes and seasons use their show.
- It jumps to the AI tab and runs in the background ("Looking for: more like
  Heroes"). The AI gets the title, type, year and Plex guid, so it knows the
  exact title.
- The new row lands at the top with 15–20 similar titles (never the title
  itself), under a short name the AI writes, e.g. "Superpowered ensembles
  like Heroes".
- It's saved like any answer, so Add to Home, Refresh picks and Delete all
  work. The AI now names every row; your own typed requests still show your
  words.

### Calmer backdrop and background AI requests (branch `feature/ai-helper`) — `5187c0f3f`
- **Darker overlay on the full-screen backdrop** (Home, Explore, Comfort,
  AI, anywhere the TV spotlight shows), so the title and summary no longer
  fight with busy artwork:
  - a light overall dim;
  - a strong dark band behind the text column that fades out across the
    screen;
  - darker under the rows.

  It's just three flat gradients and no blur, so it costs nothing on the
  Shield. Before and after: `notes/hero-overlay-before.png`,
  `notes/hero-overlay-after.png`.
- **AI requests run in the background.** After Ask or Follow up you can keep
  browsing:
  - a softly pulsing "Looking for: …" chip sits in the AI toolbar, and the
    AI icon in the side nav pulses;
  - when the picks arrive, the new row lands at the top without moving your
    focus, with a "New picks ready" message;
  - if you're on another tab, the answer is still saved and a dot on the AI
    icon tells you it's there;
  - several requests can run at once, and Refresh picks works the same way;
  - a failed request turns into a "Retry: …" chip (New conversation clears
    it).

### AI tab: saved answers, bigger rows, AI rows on Home (branch `feature/ai-helper`) — `d6dfa14cb`
- **More picks for broad requests.** The helper now aims for 15–20 picks
  for a genre, mood, era, "something like X" or "based on my history", so
  there's a full row to browse. For narrow requests (one title, a yes/no
  question, a small filmography, tight limits) it returns only what really
  fits, even one or two, and never pads the list. Tonight picks are 6–10.
  Trakt rating checks now cover up to 20 shortlisted titles.
- **Every answer is saved** in the local database (so it's in Backup &
  transfer): the request, the intro, each pick and its reason. Reopening the
  tab shows them straight away with no Plex calls. The newest answer is the
  top row; Tonight sits under this visit's answers, then older ones. Ten
  rows show at first, and **Load more** (the ⌄ button at the top) adds ten
  more. Up to 200 answers are kept; the oldest go first, except any on Home.
- **Hold OK on an AI row** for: **Add to Home** (it joins your Home rows and
  Manage Home like any other row, showing the saved picks, so it costs
  nothing to load), **Refresh picks** (re-runs the request, one Sonnet call,
  and replaces the picks everywhere) and **Delete this row** (also removes
  it from Home).
- **New conversation** now only resets the follow-up context; saved rows
  stay.

### AI tab (branch `feature/ai-helper`) — `3829b262a`
- **New AI item in the side nav** (after Comfort). On opening, Haiku 5.5
  says hello and makes **Tonight** picks from your history and what you're
  partway through (e.g. "You're one episode from finishing Solo Leveling").
  They're reused for 4 hours; ↻ makes new ones.
- **Ask** opens a box for any request. Sonnet 5.5 answers with a row of
  normal playable cards, newest row at the top and focused. The line at the
  top of the screen shows the focused pick's reason.
- **Follow up** keeps the conversation: "only films, nothing too long" after
  "something like Severance" narrows to films. **New conversation** clears it.
- Without a key the tab explains where to add one (Settings ▸ AI).
- Eval fixes:
  - A perfect 10.0 audience rating (usually a handful of votes on a new
    release) now counts as 7.0 in "best rated" ordering and is flagged to the
    model as "likely few votes".
  - The helper prefers the last ~25 years unless asked for classics.
  - Yes/no questions ("is X on my server?") always come with a playable card.

### AI helper: client, tools and eval harness (branch `feature/ai-helper`) — `185f94c7e`
- **Claude client** over HTTPS (there's no Dart SDK): Messages API
  `2026-10-21`, Sonnet 5.5 (main) / Haiku 5.5 (background), adaptive
  thinking at medium effort, cached system prompt and conversation, server
  fallbacks for Sonnet, retries with backoff on rate limits and overload.
  Thinking blocks are passed back unchanged.
- **Agent loop:** the model asks for tools, Plezy runs them on the device
  and sends the results back, and the loop stops as soon as the model calls
  `show_picks`.
- **Tools over the library index:** `search_library` (structured filters),
  `text_search` (plots, cast), `find_titles` (titles from the model's own
  knowledge checked against the servers), `get_title`, `get_history`,
  `get_continue_watching`, `get_ratings` (Trakt rating + votes for up to 10
  shortlisted titles, never in bulk), and `show_picks` (strict schema; only
  ids the tools returned). `get_new_seasons` is waiting on seasons being
  indexed.
- **Spend tracking** from each response's token usage, shown in Settings ▸ AI
  (no cap).
- **Settings ▸ AI ▸ Try a request:** runs one request and lists the picks
  with reasons; select one to open it. First real request, "random marvel
  film": 3 unwatched Marvel films, 11.5 s, $0.017.
- **Eval harness** (debug builds): runs `notes/ai-eval-prompts.txt` on
  Sonnet and Haiku and writes a markdown report (picks, all on servers?,
  tool calls, time, tokens, cost) to `notes/`.

### Library index and AI key (branch `feature/ai-helper`) — `853d70e86`
- **Library index** (Phase 1 of the AI helper plan): every movie and show on
  the Plex servers in a local SQLite file, `plezy_index.db` (a cache: safe to
  delete, rebuilt automatically, not backed up). It stores title, year, dates,
  runtime, ratings, genres, cast, director, collections, IMDb/TMDB/TVDB ids and
  watch state, with full-text search over titles, summaries and cast, and
  groups the same title across 4K copies and both servers.
- Built gently in the background 30 s after Plezy starts: one request every
  1.5 s, 500 titles per page, resuming where it stopped if interrupted. It
  then refreshes every 6 hours with "added/updated since" checks.
- First build on the PC: 166 requests in about 5.5 minutes. 51,894 movie
  entries and 23,099 shows (exactly the probe's counts), which are 30,663
  unique films and 15,466 unique shows. About 90 MB. Searches take 1–20 ms.
- **Settings ▸ AI**: the Anthropic API key, pasted in or sent from another
  device. **Receive key from another device** opens a one-time page on the
  home network (LAN address and a 6-digit code shown on the TV); it saves the
  key and closes after one use, 3 wrong codes or 5 minutes. The key is
  checked with a free model-list call, stored encrypted on this device only,
  shown only as its last 4 characters, and never logged, exported or backed
  up.

### Watchlist source switch and Comfort "Carry on watching" — `ef3f7c918`
- **Watchlist**: a Plex / Trakt switch at the top (like Explore's source
  selector), remembered on the device and included in backups. Trakt's
  watchlist gets the same Films / TV genre shelves; Trakt's lower-case genre
  slugs now read as titles ("Drama Films", "Science Fiction Films"). Shelves
  added to Home name their source ("Horror Films · Trakt") and keep working
  whichever source the page shows.
- **Comfort ▸ Carry on watching** (top row, hidden when empty): comfort-show
  episodes you're part-way through, newest first, e.g. "Friends · S2 E6 ·
  17 min left · The One with the Baby on the Bus" with a progress bar.
  Selecting one resumes where you stopped. Comes from Plex's resume points
  (the same data as Continue Watching, which leaves comfort shows out);
  under 3 minutes in or 90%+ watched are left out. Can be added to Home.

### Local database + Backup & transfer — `f50a7ef09`
- The fork's customisations now live in their own local SQLite database
  (`plezy_fork.db`, beside Plezy's `plezy_downloads.db`, using the same
  drift library), not in Trakt list descriptions. Tables: Home rows (ordered,
  plus "Only show rows I've added"), Comfort paused shows, Shortlist
  (reserved for the planned feature) and key/value settings. A separate file
  keeps upstream Plezy's database versions and migrations untouched. Storage
  sits behind one interface so cloud sync can be added later.
- First launch brings data over once: Home rows from the earlier local copy
  (or else the "Plezy" Trakt list), and Comfort paused shows from the
  Comfort Shows list description. Neither Trakt description is written any
  more. Both lists are left as they are; the Comfort Shows list's items (the
  shows) still come from Trakt.
- Home rows and Manage Home now work without Trakt connected (Trakt charts
  and lists still need it).
- **Settings ▸ Backup & transfer**: **Export to a file** saves a versioned
  JSON backup (format, schema version, app version, time, all the tables)
  with no dialog, and shows the path: PC → `Documents\Plezy\plezy-backup-
  <date>.json`; Android/Shield → the app's files folder (`Android/data/<app>/
  files/Plezy backups`). **Backups on this device** lists the files in that
  folder; picking one shows what's in it ("7 Home rows and 0 paused Comfort
  shows") and asks to **Replace** before anything changes. Where a system
  file dialog exists (not Android TV), **Import from a file** picks one from
  anywhere. Files that aren't backups, or come from a newer version, are
  rejected with a clear message.

### Fix: rows added to Home missing after a restart — `c01592a3a`
- **Plex Discover rows** (e.g. Most Watchlisted This Week, Released This
  Week in History) only render after Plex's row list has been read during
  the session, which only Explore did. On a fresh start Home got an empty
  answer and quietly skipped them. Home now reads that list itself when
  needed.
- **Rows never dropped silently**: a row whose source is still connecting,
  failed, or is empty stays saved and is retried (when sources connect, and
  a few timed retries). Manage Home shows "Loading…", "Couldn't load right
  now" or "Nothing in this row right now" next to it.
- **Safer saving**: every change is kept on the device first, then synced to
  the Plezy Trakt list one write at a time, retrying when Trakt rate-limits
  (about one write a second). Before, a rate-limited save was rolled back.
  Each save carries a revision number, so an older copy read back from Trakt
  (list reads can lag behind writes) can no longer replace rows you just
  added; a newer copy from another device still wins.
- Rows added before this fix that had already been lost (overwritten by a
  stale copy or rolled back) couldn't be recovered; the 7 saved rows were
  backed up first and all of them show again.

## 2026-10-31

### Fix: cursor jumping to the 4th card when changing rows — `7f238ca0c`
- On the PC, the mouse pointer sits idle in the middle of the screen. When the
  remote moved to a new row, that row slid under the pointer and Flutter
  counted it as the mouse "entering" the card underneath (usually the 4th),
  so focus jumped there and the row remembered it. Rows now only follow the
  mouse while it's actually being moved; with the remote or arrow keys a new
  row starts on its first card, and a row you've visited returns to where
  you left it. Affected every rail (Home, Explore, libraries). The Shield has
  no mouse, so it never happened there.

### Home builder — `9b965fbc8`
Replaces the first "Pin to Home" version below, after Karim's feedback.
- **Home shows only the rows you add, in your order.** Existing pins carried
  over: Continue Watching, Pick back up, then the pinned rows. Server rows are
  no longer shown automatically. In **Manage Home**, turning off **Only show
  rows I've added** brings back every other server row after yours.
- **Add to Home from anywhere**: it's the first entry of the hold-OK menu on
  Home rows, Explore rows of every source (Plex, Trakt, Trakt Lists), library
  Recommended rows, Watchlist shelves (each genre shelf, plus the whole
  Films / TV half), Comfort, Discover list pages, and Plex collection cards.
  Adding something already on Home says so.
- **No duplicate rows.** Rows with the same title, ignoring case and
  punctuation, merge into one, with each title appearing once (by Plex guid).
  Why Karim's Home had duplicates: PRM2-Xtra makes a curated "Oh, The
  Horror!" row in each of its five movie libraries; PRM2-Main has two
  collections called "Halloween Movies"; and there was one "Recently Added
  in …" row per library on each server (13 rows, 11 after merging *Movies
  with Movies and so on).
- **Manage Home** (the builder):
  - Rows on Home in order; select one to Move up / Move down / Move to top /
    Remove.
  - Then every row you can add, grouped: Continue Watching, From your Plex
    servers (with one switch for all "Recently added" rows), Trakt charts,
    your Trakt lists, Watchlist and Comfort, Explore rows of each source.
  - Reached from any row's hold-OK menu and from Explore's toolbar.
- Removing Continue Watching asks first.
- Rows Home doesn't already have loaded are fetched when Home loads: Trakt
  charts and lists, Explore rows, Watchlist shelves, Comfort, and library
  rows or collections. Charts refresh on every load.
- Storage: still the private Trakt list "Plezy", now as one compact encoded
  line holding the ordered rows (`[plezy:home2=…]`). The first-version format
  is migrated automatically. The local copy keeps Home instant offline.

### Pin to Home and Home rows (first version, replaced above) — `fba532f55`
- Hold OK (long-press) on any card in an Explore ▸ Trakt Lists row for
  **Pin to Home** / **Unpin from Home**. Public lists opened from Discover
  lists have a **Pin to Home** button next to Like list.
- Pinned rows appear on Home after Continue Watching and Pick back up, in pin
  order. Charts refresh every time Home loads.
- Any other Home row (Plex hubs like Recently Added or Trending, Continue
  Watching, Pick back up) can be dropped with **Remove row from Home** in the
  same long-press menu. Removing Continue Watching asks first.
- **Manage Home rows** (in the long-press menu, and the pin icon in Explore ▸
  Trakt Lists): switches for every chart and Trakt list, anything else
  pinned, and **Hidden rows**, each with "Show on Home again".
- Stored in the description of one private Trakt list, **Plezy** (created on
  the first change), so every device shows the same Home. A local copy keeps
  Home instant and working offline. The format is compact
  (`Plezy app settings [plezy:home=bo,41][plezy:hide=cw,…]`). A 65,000-
  character description stored intact, which allows thousands of rows, so
  pins are effectively unlimited. The list's items are free for the future
  Shortlist.
- If the account were at its Trakt list limit, Plezy says so instead of
  creating the list.

### Trakt Lists in Explore — `4061ed3`
- Explore's source selector gains **Trakt Lists** next to Trakt and Plex.
- Top rows are live Trakt charts: **Box Office**, **Most Watched Movies /
  Shows This Week**, **Most Anticipated Movies / Shows**.
- Then every list you've **liked on Trakt** (newest like first), then your own
  lists (except Comfort Shows). Like a list on trakt.tv from any device and it
  appears as a row. Rows load 50 titles with View all; seasons and episodes in
  a list show as their show.
- **Discover lists** (toolbar icon): trending and popular public Trakt lists;
  open one to browse it and press **Like list** right from the TV.
- Trakt smart lists / saved filters: the API answers on the free account but
  returned none for this account, so they aren't shown yet.

### Smarter Continue Watching — `7bae2cf`
- Home's Continue Watching splits in two: **Continue Watching** (touched in
  the last 30 days) stays at the top, and **Pick back up** (older) sits
  directly under it as the second row (hidden when empty). Most recent first
  in both; Remove from Continue Watching works in both.
- A show's age is when it was last watched; a new episode of a show you'd
  caught up on stays in the top row however long ago you last watched.
- Accidental starts (under 3 minutes in) and films 90%+ watched are hidden
  (nothing is marked watched).
- Shows on the Comfort list are left out of both rows.
- Per-server fetch raised from 20 to 60 items. The cut-off is a setting
  (`continue_watching_stale_days`, default 30).
- Plex's Continue Watching hub hides anything older than the server's On Deck
  window (~16 weeks), so Plezy also reads each server's `/library/onDeck` and
  adds what the hub left out (on Karim's servers: a dozen half-watched films).
  Anything last touched more than a year ago is hidden
  (`continue_watching_max_age_days`, default 365). — `aab28d0`

### Comfort shows and Random episode — `a7bbf5a`
- New **Comfort** tab (sofa icon, shown when Trakt is connected) listing the
  shows on the user's private Trakt list "Comfort Shows" (`comfort-shows`;
  reused if it exists, created otherwise).
- **Random episode** gives every show in the mix an equal chance, then picks a
  random episode from the user's Plex servers. It skips specials and avoids
  episodes watched in the last 30 days (unless nothing else is left). Shows not
  on any server are skipped.
- Shows the pick first (Play / Pick again) by default; **Play immediately** in
  Configure skips that (per device).
- **Configure**: per-show in/out-of-the-mix switches, Add a show (Trakt
  search), Remove. In/out state syncs across devices via one appended line in
  the Trakt list's description (`[plezy:paused=trakt:…]`); other description
  text is preserved.
- Every TV show's detail page gets a dice **Random episode** button that plays
  a random episode of that show immediately.

### PC previews the Shield's real layout — `911f99b`
- In TV mode on desktop, the app lays out on the Shield's 960×540 logical
  canvas (Android TV 1080p at 2×) and scales up to fill the screen, so what the
  PC shows matches the Shield. Android and the Shield build are unchanged.

### Watchlist page — `4084400`, `65921eb`, `8c9f382`
- New **Watchlist** tab (bookmark icon) showing the whole watchlist of the
  active catalog source (Plex for this profile).
- Grouped into genre rows: Films first, then TV, biggest genre first; each title
  under its primary genre once. Genres with 5 or fewer titles fold into
  "Other Films" / "Other TV".
- Genres are looked up automatically for every title at load time (Plex's
  watchlist listing omits them) and cached for 7 days; new titles always fetch.
- Selecting a title opens its detail page with where it's available to play.

### Netflix-style home rows — `0947a35`, `07e865e`
- Below the first row, the hero shrinks to a slim info strip and several rows
  show at once with slightly smaller cards (90%); the first row keeps the full
  hero. Applies to Home, Explore and libraries' Recommended tab.
- The background only switches after resting on a card for 0.4 s (no flashing
  while scrolling), and in the multi-row view the artwork fades out below the
  info strip.

### Libraries at the bottom of the side nav — `75dc9b1`
- A long library list no longer pushes Explore, Search, Settings and the rest
  off screen; D-pad order matches.

### NVIDIA Shield remote on Windows — `3566fe0`
- The Shield remote, paired to the PC over Bluetooth, is registered as an SDL
  gamepad (D-pad, OK, Back, Home, Play/Pause) so it navigates the app.
  Windows-only.
