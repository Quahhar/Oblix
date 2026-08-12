import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oblix/ui/shell/dock_controller.dart';
import 'package:oblix/ui/shell/home_shell.dart';
import 'package:oblix/ui/theme/oblix_theme.dart';
import 'package:oblix/ui/theme/theme_controller.dart';

void main() {
  testWidgets('compact dock has only the requested destinations', (
    tester,
  ) async {
    await _setPhoneSize(tester, const Size(390, 844));
    await tester.pumpWidget(const _DockHarness());

    expect(find.text('Note'), findsOneWidget);
    expect(find.text('Notebook'), findsOneWidget);
    expect(find.text('Task'), findsOneWidget);
    expect(find.text('Profile'), findsOneWidget);
    expect(find.text('New'), findsNothing);
    expect(find.text('Books'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('upward drag opens the customizable deck', (tester) async {
    await _setPhoneSize(tester, const Size(390, 844));
    await tester.pumpWidget(const _DockHarness());

    await tester.drag(
      find.bySemanticsLabel('Expand or collapse navigation dock'),
      const Offset(0, -180),
    );
    await tester.pumpAndSettle();

    expect(find.text('Your dock'), findsOneWidget);
    expect(find.text('Customize'), findsOneWidget);

    await tester.tap(find.text('Customize'));
    await tester.pumpAndSettle();

    expect(find.text('Done'), findsOneWidget);
    expect(find.textContaining('Profile is fixed'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Scan waits in the expanded tray, not in the bar', (
    tester,
  ) async {
    await _setPhoneSize(tester, const Size(390, 844));
    await tester.pumpWidget(const _DockHarness());

    // Collapsed: still the same four, Scan is nowhere.
    expect(find.text('Scan'), findsNothing);

    await tester.drag(
      find.bySemanticsLabel('Expand or collapse navigation dock'),
      const Offset(0, -260),
    );
    await tester.pumpAndSettle();

    expect(find.text('MORE TOOLS'), findsOneWidget);
    expect(find.text('Scan'), findsOneWidget);
    expect(find.text('Profile'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dragging Scan onto a slot puts it in the bar', (tester) async {
    await _setPhoneSize(tester, const Size(390, 844));
    await tester.pumpWidget(const _DockHarness(expanded: true));
    await tester.pumpAndSettle();

    await tester.drag(
      find.text('Scan'),
      _offsetBetween(tester, 'Scan', 'Task'),
    );
    await tester.pumpAndSettle();

    // Scan took Task's slot; Task went back to the tray, so both are still
    // on screen — but Scan is now a deck tile and Task is the tray chip.
    expect(find.text('Scan'), findsOneWidget);
    expect(find.text('Task'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('expanded glass dock fits a narrow phone', (tester) async {
    await _setPhoneSize(tester, const Size(320, 700));
    await tester.pumpWidget(
      const _DockHarness(
        expanded: true,
        liquidGlass: true,
        collection: OblixThemeCollection.paper,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Your dock'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Offset _offsetBetween(WidgetTester tester, String from, String to) =>
    tester.getCenter(find.text(to)) - tester.getCenter(find.text(from));

Future<void> _setPhoneSize(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

class _DockHarness extends StatefulWidget {
  final bool expanded;
  final bool liquidGlass;
  final OblixThemeCollection collection;

  const _DockHarness({
    this.expanded = false,
    this.liquidGlass = false,
    this.collection = OblixThemeCollection.classic,
  });

  @override
  State<_DockHarness> createState() => _DockHarnessState();
}

class _DockHarnessState extends State<_DockHarness> {
  static const _collapsed = 56.0;
  static const _expanded = 322.0;

  late double _height = widget.expanded ? _expanded : _collapsed;
  var _editing = false;
  var _selectedTab = 0;
  final _order = [...DockController.defaultOrder];

  void _snap(bool expanded) {
    setState(() {
      _height = expanded ? _expanded : _collapsed;
      if (!expanded) _editing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: OblixTheme.forCollection(widget.collection, Brightness.light),
      home: Scaffold(
        extendBody: true,
        body: Builder(
          builder: (context) {
            final c = OblixColors.of(context);
            return ColoredBox(
              color: c.bg,
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  Text('Notes', style: OblixType.pageTitle(c)),
                  const SizedBox(height: 18),
                  Container(
                    height: 220,
                    decoration: BoxDecoration(
                      color: c.surface,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: c.hairline),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
        bottomNavigationBar: SafeArea(
          top: false,
          minimum: const EdgeInsets.fromLTRB(10, 0, 10, 8),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 320),
            height: _height,
            child: NavigationDock(
              order: _order,
              selectedTab: _selectedTab,
              editing: _editing,
              liquidGlass: widget.liquidGlass,
              onDragStart: (_) {},
              onDragUpdate: (details) => setState(() {
                _height = (_height - details.delta.dy)
                    .clamp(_collapsed, _expanded)
                    .toDouble();
              }),
              onDragEnd: (details) => _snap(
                details.velocity.pixelsPerSecond.dy < -280 ||
                    _height > (_collapsed + _expanded) / 2,
              ),
              onToggle: () => _snap(_height == _collapsed),
              onToggleEditing: () => setState(() => _editing = !_editing),
              onDestination: (destination) => setState(
                () => _selectedTab = destination.tabIndex ?? _selectedTab,
              ),
              onPickShortcut: (_) {},
              // Mirrors DockController.assign: a deck item trades places, a
              // tray item takes the slot over.
              onAssign: (incoming, target) async {
                setState(() {
                  final targetIndex = _order.indexOf(target);
                  if (targetIndex < 0) return;
                  final incomingIndex = _order.indexOf(incoming);
                  if (incomingIndex >= 0) _order[incomingIndex] = target;
                  _order[targetIndex] = incoming;
                });
              },
              onProfile: () {},
            ),
          ),
        ),
      ),
    );
  }
}
