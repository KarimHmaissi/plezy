import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/navigation/navigation_tabs.dart';

void main() {
  group('NavigationTab.resolveDefaultTab', () {
    test('offline prefers Downloads when available', () {
      expect(
        NavigationTab.resolveDefaultTab(isOffline: true, hasLiveTv: false, preferredStartup: null),
        NavigationTabId.downloads,
      );
    });

    test('offline ignores an online-only preferred section', () {
      expect(
        NavigationTab.resolveDefaultTab(isOffline: true, hasLiveTv: true, preferredStartup: NavigationTabId.liveTv),
        NavigationTabId.downloads,
      );
    });

    test('online honours the preferred section when it is visible', () {
      expect(
        NavigationTab.resolveDefaultTab(isOffline: false, hasLiveTv: true, preferredStartup: NavigationTabId.liveTv),
        NavigationTabId.liveTv,
      );
      expect(
        NavigationTab.resolveDefaultTab(isOffline: false, hasLiveTv: false, preferredStartup: NavigationTabId.search),
        NavigationTabId.search,
      );
    });

    test('online falls back to Home when preferred Live TV is unavailable', () {
      expect(
        NavigationTab.resolveDefaultTab(isOffline: false, hasLiveTv: false, preferredStartup: NavigationTabId.liveTv),
        NavigationTabId.discover,
      );
    });

    test('online defaults to Home when no preference is set', () {
      expect(
        NavigationTab.resolveDefaultTab(isOffline: false, hasLiveTv: true, preferredStartup: null),
        NavigationTabId.discover,
      );
    });

    test('online falls back to Home when preferred Explore is unavailable', () {
      expect(
        NavigationTab.resolveDefaultTab(isOffline: false, hasLiveTv: false, preferredStartup: NavigationTabId.explore),
        NavigationTabId.discover,
      );
      expect(
        NavigationTab.resolveDefaultTab(
          isOffline: false,
          hasLiveTv: false,
          hasExplore: true,
          preferredStartup: NavigationTabId.explore,
        ),
        NavigationTabId.explore,
      );
    });
  });

  group('NavigationTab.getVisibleTabs', () {
    test('hides Explore until a catalog source is connected', () {
      final without = NavigationTab.getVisibleTabs(isOffline: false);
      expect(without.map((tab) => tab.id), isNot(contains(NavigationTabId.explore)));

      final with_ = NavigationTab.getVisibleTabs(isOffline: false, hasExplore: true, hasLiveTv: true);
      final ids = with_.map((tab) => tab.id).toList();
      expect(ids, contains(NavigationTabId.explore));
      // Explore sits after Live TV, directly before Search.
      expect(ids.indexOf(NavigationTabId.explore), ids.indexOf(NavigationTabId.liveTv) + 1);
      // The AI tab, then History, sit right before Search.
      expect(ids.indexOf(NavigationTabId.explore), ids.indexOf(NavigationTabId.ai) - 1);
      expect(ids.indexOf(NavigationTabId.ai), ids.indexOf(NavigationTabId.history) - 1);
      expect(ids.indexOf(NavigationTabId.history), ids.indexOf(NavigationTabId.search) - 1);
    });

    test('V2-60: the Reel keeps its tab offline (it says so itself)', () {
      final offline = NavigationTab.getVisibleTabs(isOffline: true, hasReel: true);
      expect(offline.map((tab) => tab.id), contains(NavigationTabId.reel));
      expect(NavigationTab.getVisibleTabs(isOffline: true).map((tab) => tab.id), isNot(contains(NavigationTabId.reel)));
    });

    test('Explore is online-only', () {
      final offline = NavigationTab.getVisibleTabs(isOffline: true, hasExplore: true);
      expect(offline.map((tab) => tab.id), isNot(contains(NavigationTabId.explore)));
    });

    test('hides Watchlist until a watchlist source is connected, then shows it after Explore', () {
      final without = NavigationTab.getVisibleTabs(isOffline: false, hasExplore: true);
      expect(without.map((tab) => tab.id), isNot(contains(NavigationTabId.watchlist)));

      final ids = NavigationTab.getVisibleTabs(
        isOffline: false,
        hasExplore: true,
        hasWatchlist: true,
      ).map((tab) => tab.id).toList();
      expect(ids.indexOf(NavigationTabId.watchlist), ids.indexOf(NavigationTabId.explore) + 1);
      // The AI tab, then History, sit right before Search.
      expect(ids.indexOf(NavigationTabId.watchlist), ids.indexOf(NavigationTabId.ai) - 1);
      expect(ids.indexOf(NavigationTabId.ai), ids.indexOf(NavigationTabId.history) - 1);
      expect(ids.indexOf(NavigationTabId.history), ids.indexOf(NavigationTabId.search) - 1);

      final offline = NavigationTab.getVisibleTabs(isOffline: true, hasWatchlist: true);
      expect(offline.map((tab) => tab.id), isNot(contains(NavigationTabId.watchlist)));
    });

    test('shows Comfort only with Trakt connected, after Watchlist', () {
      final without = NavigationTab.getVisibleTabs(isOffline: false, hasWatchlist: true);
      expect(without.map((tab) => tab.id), isNot(contains(NavigationTabId.comfort)));

      final ids = NavigationTab.getVisibleTabs(
        isOffline: false,
        hasWatchlist: true,
        hasComfort: true,
      ).map((tab) => tab.id).toList();
      expect(ids.indexOf(NavigationTabId.comfort), ids.indexOf(NavigationTabId.watchlist) + 1);
      // The AI tab, then History, sit right before Search.
      expect(ids.indexOf(NavigationTabId.comfort), ids.indexOf(NavigationTabId.ai) - 1);
      expect(ids.indexOf(NavigationTabId.ai), ids.indexOf(NavigationTabId.history) - 1);
      expect(ids.indexOf(NavigationTabId.history), ids.indexOf(NavigationTabId.search) - 1);
    });
  });
}
