# Working on this fork

## No personal data, ever

This repository is public. Nothing in it may describe the owner's own setup.
That covers code, comments, tests, fixtures, the changelog, commit messages
and PR text.

- **Media servers:** no server names, hostnames, machine ids or addresses, and
  no library or collection names taken from a real server. Use invented ones
  (`server-a`, `srv-b`, "Spooky Picks").
- **Library size:** no counts of what a real library, watchlist or Continue
  Watching row holds. Write "a large library", never the measured number.
- **Home devices:** no models of TVs, phones, soundbars, receivers or
  computers, no rooms, and nothing about who in the household watches what.
  Write "a TV", "a phone", "a foldable", "an AV receiver".
- **Watch history:** no titles from real history, lists or Continue Watching
  as examples, prompt text or fixtures, and no real TMDB, IMDb or TVDB ids.
  Invent titles. Fake ids use the 9xxxxx range (`tmdb: 900001`,
  `tt9000001`).
- **Network and accounts:** no LAN addresses, tokens, keys, emails, local
  paths or account details.

Measurements go in as timings and rates (searches take 1–20 ms, 120 fps), not
as facts about one person's library or devices.

If something like this was committed, fix it in a new commit and say so in
the PR; don't push a rewrite of shared history without the owner's say.
