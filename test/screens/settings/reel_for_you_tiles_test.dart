import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/screens/settings/reel_for_you_tiles.dart';
import 'package:plezy/services/customisation/customisation_store.dart';
import 'package:plezy/services/customisation/mirror_store.dart';
import 'package:plezy/services/reel/reel_store.dart';
import 'package:plezy/theme/mono_theme.dart';

void main() {
  late _MemoryCustomisationStore settings;
  late ReelStore store;

  setUp(() {
    LocaleSettings.setLocaleSync(AppLocale.en);
    settings = _MemoryCustomisationStore();
    store = ReelStore(
      database: () => throw UnimplementedError('the note is a synced setting'),
      settings: () async => settings,
    );
  });

  Future<void> pump(WidgetTester tester, {Future<bool> Function()? rebuild}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 1600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      MaterialApp(
        theme: monoTheme(MonoPalette.dark),
        home: Scaffold(
          body: ReelForYouTiles(store: store, rebuild: rebuild ?? () async => true),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('no note yet: says For You goes by what you watch', (tester) async {
    await pump(tester);
    expect(find.text('For You in the Reel'), findsOneWidget);
    expect(find.text('Tell For You in your own words'), findsOneWidget);
    expect(find.text('No note yet: For You goes by what you watch'), findsOneWidget);
    expect(find.text("Rebuild today's For You"), findsOneWidget);
  });

  testWidgets('writing a note keeps it in the synced settings and shows it; clearing it removes it', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Tell For You in your own words'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '  Fewer long films on weeknights  ');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(settings.values[ReelStore.forYouNoteKey], 'Fewer long films on weeknights');
    expect(find.text('Fewer long films on weeknights'), findsOneWidget);
    expect(find.textContaining("Tomorrow's For You reads it"), findsOneWidget);

    await tester.tap(find.text('Tell For You in your own words'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Fewer long films on weeknights'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(settings.values.containsKey(ReelStore.forYouNoteKey), isFalse);
    expect(find.text('No note yet: For You goes by what you watch'), findsOneWidget);
  });

  testWidgets('a note written on the other device shows once it syncs', (tester) async {
    await pump(tester);
    settings.values[ReelStore.forYouNoteKey] = 'More harbor dramas';
    Customisation.changed.value++;
    await tester.pumpAndSettle();
    expect(find.text('More harbor dramas'), findsOneWidget);
  });

  testWidgets('rebuild says who builds: this device, or the TV', (tester) async {
    var asked = 0;
    var here = true;
    await pump(
      tester,
      rebuild: () async {
        asked++;
        return here;
      },
    );
    await tester.tap(find.text("Rebuild today's For You"));
    await tester.pumpAndSettle();
    expect(asked, 1);
    expect(find.text("Today's For You is cleared; the Reel builds a new one with your note"), findsOneWidget);

    ScaffoldMessenger.of(tester.element(find.byType(ReelForYouTiles))).clearSnackBars();
    await tester.pumpAndSettle();
    here = false;
    await tester.tap(find.text("Rebuild today's For You"));
    await tester.pumpAndSettle();
    expect(asked, 2);
    expect(
      find.text("The TV rebuilds today's For You when its Reel next opens; this phone then takes it"),
      findsOneWidget,
    );
  });

  testWidgets('a note or rebuild that fails says so and leaves the tiles usable', (tester) async {
    await pump(tester, rebuild: () async => throw StateError('no database'));
    settings.failWrites = true;
    await tester.tap(find.text('Tell For You in your own words'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'More harbor dramas');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.textContaining("Couldn't save the note"), findsOneWidget);
    expect(find.text('No note yet: For You goes by what you watch'), findsOneWidget);

    ScaffoldMessenger.of(tester.element(find.byType(ReelForYouTiles))).clearSnackBars();
    await tester.pumpAndSettle();
    await tester.tap(find.text("Rebuild today's For You"));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text("Couldn't clear today's For You"), findsOneWidget);
  });
}

class _MemoryCustomisationStore implements CustomisationStore {
  final Map<String, String> values = {};

  /// A phone mirroring a TV it isn't connected to: writes throw.
  bool failWrites = false;

  @override
  Future<String?> readSetting(String key) async => values[key];

  @override
  Future<void> writeSetting(String key, String? value) async {
    if (failWrites) throw const MirrorReadOnlyException();
    value == null ? values.remove(key) : values[key] = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
