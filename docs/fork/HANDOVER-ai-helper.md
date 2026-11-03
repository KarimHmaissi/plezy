# Handover: AI helper (branch `feature/ai-helper`)

State of the AI work in this fork. The full history is in
[`CHANGELOG-FORK.md`](../../CHANGELOG-FORK.md) at the repo root. Everything
below is on `feature/ai-helper` and not merged to `main`.

## What's built

- **Library index**: a local SQLite index (`plezy_index.db`) of every film
  and show on the connected Plex servers, with full-text search. It's built
  gently on first open (about 5 minutes for a large library) and kept up to
  date every 6 hours. Code: `lib/services/library_index/`.
- **AI helper core**: a Claude Messages API client, an agent loop, and tools
  over the index, watch history, Continue Watching and Trakt ratings. Sonnet
  5.5 handles requests; Haiku 5.5 handles Tonight picks and auto-refresh.
  Spend is tracked per month with no cap. Code: `lib/services/ai/`.
- **API key**: stored encrypted on the device and never logged, exported or
  backed up. It's entered in Settings ▸ AI.
- **AI tab** (side nav, after Comfort):
  - A greeting and **Tonight** picks.
  - **Ask** and **Follow up**, which run in the background while you browse,
    with a pulsing chip and nav icon and a dot if the answer arrives
    off-tab.
  - 15–20 picks for broad requests, and only the true matches for narrow
    ones.
  - Every answer is saved (up to 200), with **Load more**.
  - Hold OK on a row for **Add to Home**, **Refresh picks** and **Delete**.
- **More like this** in the long-press menu of any film, show or episode:
  it jumps to the AI tab and adds an AI-named row of similar titles.
- **AI rows on Home**: they show the saved picks (no extra calls) and
  **auto-refresh** twice a day on Haiku while Plezy is open. There's a cap
  of 10 AI rows on Home, and a toggle in Settings ▸ AI.
- **UI**: a darker, calmer overlay on the TV spotlight backdrop.

## Unfinished

- **Auto-refresh hasn't been tried on a real device yet.** It compiles and
  `flutter analyze` is clean. To check it: in a debug build, go to Settings ▸
  AI ▸ "Auto-refresh Home AI rows now" with an AI row on Home, then check
  the row and the spend line.
- **Eval re-run**: the cost per request with 15–20 picks hasn't been
  measured yet (it was about 1.6¢ with Sonnet at 3–12 picks). Use the debug
  "Run eval" in Settings ▸ AI.
- **Text entry on TV**: the request box isn't autofocused (press UP, type,
  then OK twice).

## Running it on the Mac or the Shield

1. `git checkout feature/ai-helper`
2. Use Flutter **3.47.x**, then `flutter pub get` and `flutter run`
   (`-d macos`, or the Shield over adb).
3. Sign in to Plex as usual. On first open the library index builds in the
   background (about 5 minutes; Home works meanwhile).
4. Add the Anthropic API key in **Settings ▸ AI ▸ Receive key from another
   device**. This opens a one-time page on the home network, protected by a
   6-digit code; you paste the key there from a phone or laptop. It works on
   the Shield too, so you don't have to type on the remote. **Paste API key**
   also works where there's a keyboard.

## Eval prompts

The eval reads a plain-text prompt list (one request per line, `#` for
comments) from `AiEval.promptsFile` (`lib/services/ai/ai_eval.dart`): the
`PLEZY_EVAL_PROMPTS` environment variable when set, else
`notes/ai-eval-prompts.txt` under the working directory (ignored by git).
Reports are written next to it. Don't commit them: they list library
titles.

## Next backlog items (AI)

- **43: Ask about this title**: ask the AI about one title from its detail
  page or long-press menu ("is it scary?", "do I need to see the first
  one?").
- **42: "Previously on"**: a short, spoiler-free recap when going back to a
  show after a break.
- Later: voice requests, and richer context per title (reviews or
  subtitles).
