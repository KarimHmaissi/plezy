# Shield Experience — fork changelog

Features and changes in [KarimHmaissi/plezy](https://github.com/KarimHmaissi/plezy)
on top of upstream [edde746/plezy](https://github.com/edde746/plezy). The target
is the NVIDIA Shield (Android TV); development happens on a Windows PC in TV
mode. Newest first. Each entry lists its commit(s) on `dev`.

## Planned (not built yet)

### AI helper
- A new nav item where you send a voice command or typed request ("something
  light and funny, under 30 minutes") and get back a list of suggestions from
  your libraries, each with its reasoning.

### Continue Watching from Trakt progress (phase 2)
- Use Trakt watch progress so "next up" is right even for episodes watched
  outside these Plex servers (other apps, devices), and so very old shows
  beyond Plex's On Deck window can still appear in "Pick back up".

## 2026-10-31

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
