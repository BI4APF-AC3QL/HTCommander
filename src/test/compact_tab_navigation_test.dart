import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/widgets/compact_tab_navigation.dart';

void main() {
  testWidgets('compact navigation keeps primary pages visible', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const _NavigationHarness());

    for (final id in const ['Radio', 'Comms', 'Audio', 'APRS', 'Map']) {
      expect(find.byKey(ValueKey('main_tab_$id')), findsOneWidget);
    }
    expect(find.byKey(const ValueKey('main_tab_more')), findsOneWidget);
    expect(find.byKey(const ValueKey('compact_more_Satellite')), findsNothing);
    expect(
      tester.getSize(find.byKey(const ValueKey('main_tab_navigation'))).height,
      lessThanOrEqualTo(72),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('More opens every additional page and selects it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const _NavigationHarness());

    await tester.tap(find.byKey(const ValueKey('main_tab_more')));
    await tester.pumpAndSettle();

    for (final id in const ['Satellite', 'Mail', 'Terminal', 'Debug']) {
      expect(find.byKey(ValueKey('compact_more_$id')), findsOneWidget);
    }

    await tester.tap(find.byKey(const ValueKey('compact_more_Satellite')));
    await tester.pumpAndSettle();

    expect(find.text('Selected: Satellite'), findsOneWidget);
    expect(
      tester
          .widget<NavigationBar>(
            find.byKey(const ValueKey('main_tab_navigation')),
          )
          .selectedIndex,
      5,
    );
    expect(tester.takeException(), isNull);
  });
}

class _NavigationHarness extends StatefulWidget {
  const _NavigationHarness();

  @override
  State<_NavigationHarness> createState() => _NavigationHarnessState();
}

class _NavigationHarnessState extends State<_NavigationHarness> {
  String _currentId = 'Radio';

  static const _primary = [
    CompactTabDestination(
      id: 'Radio',
      title: 'Radio',
      assetPath: 'missing/radio.png',
      fallbackIcon: Icons.radio,
    ),
    CompactTabDestination(
      id: 'Comms',
      title: 'Comms',
      assetPath: 'missing/comms.png',
      fallbackIcon: Icons.mic,
    ),
    CompactTabDestination(
      id: 'Audio',
      title: 'Audio',
      assetPath: 'missing/audio.png',
      fallbackIcon: Icons.volume_up,
    ),
    CompactTabDestination(
      id: 'APRS',
      title: 'APRS',
      assetPath: 'missing/aprs.png',
      fallbackIcon: Icons.people,
    ),
    CompactTabDestination(
      id: 'Map',
      title: 'Map',
      assetPath: 'missing/map.png',
      fallbackIcon: Icons.public,
    ),
  ];

  static const _more = [
    CompactTabDestination(
      id: 'Satellite',
      title: 'Satellite',
      assetPath: 'missing/satellite.png',
      fallbackIcon: Icons.satellite_alt,
    ),
    CompactTabDestination(
      id: 'Mail',
      title: 'Mail',
      assetPath: 'missing/mail.png',
      fallbackIcon: Icons.mail,
    ),
    CompactTabDestination(
      id: 'Terminal',
      title: 'Terminal',
      assetPath: 'missing/terminal.png',
      fallbackIcon: Icons.terminal,
    ),
    CompactTabDestination(
      id: 'Debug',
      title: 'Debug',
      assetPath: 'missing/debug.png',
      fallbackIcon: Icons.info,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(child: Text('Selected: $_currentId')),
        bottomNavigationBar: CompactTabNavigation(
          primaryDestinations: _primary,
          moreDestinations: _more,
          currentId: _currentId,
          moreTitle: 'More',
          onSelect: (id) => setState(() => _currentId = id),
        ),
      ),
    );
  }
}
