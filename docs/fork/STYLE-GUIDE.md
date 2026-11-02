# Fork style guide

How Plezy screens look, so pages we add (AI, History, Ask about this,
Previously on…) read as part of the same app. Everything here comes from the
theme; a new screen should need no colour or font literals.

## Where styling lives

| What | Where |
| --- | --- |
| Theme (colours, text, buttons, cards, nav bar) | `lib/theme/mono_theme.dart` (`monoTheme(palette)`) |
| Palette tokens + radii + durations | `lib/theme/mono_tokens.dart` → `tokens(context)` |
| Row rhythm on touch screens | `lib/theme/fork_spacing.dart` → `ForkSpacing.of(context)` |
| TV shelf metrics | `TvLayoutConstants` |
| Touch feedback and haptics | `Pressable` (`lib/widgets/pressable.dart`), `ForkMotion` (`lib/theme/fork_motion.dart`) |

The user picks a palette in Settings (default dark, OLED black, warm, blue,
green, purple, light…). **Never assume dark or a specific accent**: read
`tokens(context)` or `Theme.of(context).colorScheme`.

## Colour

| Role | Token | Notes |
| --- | --- | --- |
| Page background | `tokens.bg` / `scaffoldBackgroundColor` | Default dark is a near-black blue-grey, not pure black. Let `Scaffold` paint it. |
| Cards, sheets, grouped lists | `tokens.surface` | `Card` already uses it. |
| Hairlines, borders | `tokens.outline` | |
| Primary text, icons | `tokens.text` / `colorScheme.onSurface` | |
| Secondary text | `tokens.textMuted` | Captions, counts, metadata. |
| Interactive / selected | `tokens.accent` / `colorScheme.primary` | White on the default palettes; coloured on some. |
| On accent | `colorScheme.onPrimary` | Text on a filled accent button. |
| Faint fills | `tokens.text.withValues(alpha: 0.06–0.12)` | Unselected chips, bars, placeholders. |
| Error | `colorScheme.error` | |

Don't: hex colours, `Colors.white*`, `Colors.black`, a second accent
(amber, red…) for decoration. Data visualisations use the accent at varying
opacity, with `tokens.text` at low alpha for the empty or other series.

## Type

The platform font (Roboto on Android, SF on Apple) through `textTheme`;
no custom display faces.

| Role | Style |
| --- | --- |
| Page title | `DesktopSliverAppBar(title: Text(...))` (appBarTheme: 18 sp, w700) |
| Row / section title | `ForkSpacing.of(context).titleStyle(context)`: `titleLarge`, w600, 17 phone / 19 tablet / 20 desktop (TV: 26, w700) — as `HubSection`; its icon and chevron match the title size |
| Card caption (under artwork) | `MediaCard`: title 15 regular (height 1.25), subtitle 13 muted (height 1.35), 8 dp poster→title gap on touch and desktop; TV keeps 13 w600 / 11 with a 2 dp gap. Rows size cards with `MediaCard.rowCaptionBandHeight` |
| Big stat number | `textTheme.headlineMedium` / `displaySmall`, w700 |
| Card title | `textTheme.titleSmall` / `bodyLarge` w600 |
| Body | `textTheme.bodyMedium` |
| Caption, metadata | `textTheme.bodySmall` (already `textMuted`) / `labelSmall` |
| Chip / button label | from the component's theme |

No all-caps labels, no letter-spacing tweaks; sentence case as the rest of
the app.

## Spacing and shape

- Touch screens: `ForkSpacing.of(context)`: `edgeInset` (20 phone / 28
  tablet / 32 desktop) for left and right gutters, `titleGap` between a
  section title and its content, `rowGap` between sections, `cardGap`
  between cards.
- TV: `TvLayoutConstants` (shelf gaps, overscan-safe insets).
- Radii: `tokens.radiusSm` (8) small elements, `radiusMd` (12) cards and
  posters, `radiusLg` (20) big grouped cards, `MonoTokens.radiusFull` pills.
  `Card` uses 14.
- Posters 2:3, wide art 16:9, sized with `ForkSpacing.cardWidth`.

## Components

| Need | Use |
| --- | --- |
| Page scaffold | `Scaffold` → `RefreshIndicator(onRefresh: ForkMotion.refreshing(...))` → `CustomScrollView` with `DesktopSliverAppBar(pinned: false, floating: true, snap: true, backgroundColor: scaffoldBackgroundColor, surfaceTintColor: transparent, scrolledUnderElevation: 0)` |
| A row of media | `HubSection` |
| Segmented choices (tabs, years) | `TabChipStrip` + `FocusableTabChip` |
| Filter/action chip | `FocusableFilterChip` |
| Header actions | `FocusableActionBar` + `FocusableAction` |
| Primary / secondary button | `FilledButton` / `OutlinedButton`, `TextButton` (themed: stadium, accent fill) |
| Card | `Card` (surface, 14 radius, no elevation) |
| Confirm | `showConfirmDialog` |
| Feedback | `showSuccessSnackBar` / `showErrorSnackBar` |
| Icons | `AppIcon` / material symbols rounded |
| Images | `OptimizedMediaImage` (Plex paths or absolute URLs) |
| Touch feedback | wrap tappables in `Pressable`; `ForkMotion.selection()` on selection changes |

## Navigation (phone)

As Plex's app:

- **Bottom bar**: Home, Comfort, Explore, Watchlist, AI (`mainScreenBottomNavigationTabs`). Comfort always shows on phones and explains how to connect Trakt when it isn't. Pages reached another way (Libraries, History, Search, Downloads, Settings) never take a slot; Home stays highlighted.
- **Top bar on every tab**: the tab's own primary action, if any (AI's Ask, Comfort's Random episode, Libraries' filters, Watchlist's source), then `phoneTabActions(context)`: Search, the companion remote and the avatar. Nothing else.
- **Side drawer** (`showPhoneNavDrawer`, from the avatar): slides in from the right over a dim scrim (`ForkMotion.sheetIn/sheetOut`, emphasized curves); swipe right, tap the scrim or Back closes it. Profile avatar and name, then the tab's own extra actions (`extras`), Libraries, History, Downloads, Watch Together, Refresh (tabs that reload), Profiles, Settings, Log out, as icon + label rows on `tokens.surface`.
- TV and desktop keep the side rail and their own toolbars.

## Motion

One set of tokens, in `ForkMotion` (`lib/theme/fork_motion.dart`):

| Motion | Tokens |
| --- | --- |
| Page push/pop | the theme's `pageTransitionsTheme`: Android's fade-forwards for every `MaterialPageRoute`; no per-screen route animations on touch |
| Overlay in/out (AI composer, full-screen sheets) | `ForkMotion.riseTransition`: fade + 24 dp rise, `sheetIn` 260 ms `Easing.emphasizedDecelerate`, `sheetOut` 200 ms `Easing.emphasizedAccelerate` |
| Press / release | `Pressable` (`pressIn` 100 ms, `release` 260 ms spring) |
| Haptics | `ForkMotion.selection / longPress / success / error` (touch only) |

Rules: animate opacity and translation, never scale text or clip-reveal a
page; open the keyboard (focus a field) only after the route has settled,
so the resize doesn't fight the motion; honour `ForkMotion.reduceMotion`
(fade only). Inside the composer the film-strip loader, clapper and
self-drawing mark stay: motion is the signature, colour and type stay
native.

## Do / don't

- **Do** let `Scaffold` paint the background and the app bar match other
  tabs.
- **Do** check new screens at Fold cover (~360 dp), unfolded (~700 dp) and
  TV (960×540 logical) beside Home and Explore.
- **Don't** hard-code colours or fonts, add custom font assets, or use
  all-caps display headings.
- **Don't** add bottom-nav tabs or top-bar icons on phones: new destinations
  and tab actions go in the side drawer (the bar stays at five; the top bar
  at Search, remote, avatar).
