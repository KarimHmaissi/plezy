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
| Row / section title | `textTheme.titleLarge` + `fontWeight: w700`, `fontSize: ForkSpacing.titleSize` (20 phone, 22 tablet/desktop; 26 TV) — as `HubSection` |
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

## Motion

Keep the fork's motion: `Pressable` press-and-spring, `ForkMotion` haptics
(touch only), the AI composer's iris and film-strip loaders. Motion is the
signature; colour and type stay native.

## Do / don't

- **Do** let `Scaffold` paint the background and the app bar match other
  tabs.
- **Do** check new screens at Fold cover (~360 dp), unfolded (~700 dp) and
  TV (960×540 logical) beside Home and Explore.
- **Don't** hard-code colours or fonts, add custom font assets, or use
  all-caps display headings.
- **Don't** add bottom-nav tabs for pages reached from a top-bar icon (the
  phone bar stays at five).
