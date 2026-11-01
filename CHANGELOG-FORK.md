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

Details of each are in the dated entries below.

## Backlog (not built yet)

### AI
- **Voice requests** — speak a request on the AI tab instead of typing it
  (typed requests are built).
- **Richer context per title (later)** — add more about each title to the
  library index, such as reviews or subtitles (possibly as embeddings), so
  the helper can match on mood, themes and dialogue, not just genre, cast
  and summary.
- **Auto-refreshing AI rows on Home** — AI rows added to Home re-run their
  request now and then (for example once a day, with Haiku to keep it cheap),
  so they pick up new additions and drop what you've watched. Today they
  only refresh when you choose Refresh picks.
- **Ask about this title** — from a title's detail page or its hold-OK
  menu, ask the AI about that title ("is it scary?", "do I need to have
  seen the first one?", "more like this but lighter"), with the answer and
  any picks shown on the spot.
- **"More like this" from any title** — a new entry in a title's hold-OK
  menu that sends it to the AI ("titles similar to <title>"). It switches to
  the AI tab and adds a new row of similar titles (running in the
  background like any request), named by the AI, e.g. "Twisty mysteries
  like Dark".
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

## 2026-11-01

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
