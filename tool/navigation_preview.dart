import 'package:flutter/material.dart';
import 'package:oblix/ui/shell/dock_controller.dart';
import 'package:oblix/ui/shell/home_shell.dart';
import 'package:oblix/ui/theme/oblix_theme.dart';
import 'package:oblix/ui/theme/theme_controller.dart';

void main() => runApp(const _PreviewApp());

class _PreviewApp extends StatefulWidget {
  const _PreviewApp();

  @override
  State<_PreviewApp> createState() => _PreviewAppState();
}

class _PreviewAppState extends State<_PreviewApp> {
  var _collection = OblixThemeCollection.classic;
  var _glass = false;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: OblixTheme.forCollection(_collection, Brightness.light),
      home: _PreviewHome(
        collection: _collection,
        glass: _glass,
        onCollection: (value) => setState(() => _collection = value),
        onGlass: (value) => setState(() => _glass = value),
      ),
    );
  }
}

class _PreviewHome extends StatefulWidget {
  final OblixThemeCollection collection;
  final bool glass;
  final ValueChanged<OblixThemeCollection> onCollection;
  final ValueChanged<bool> onGlass;

  const _PreviewHome({
    required this.collection,
    required this.glass,
    required this.onCollection,
    required this.onGlass,
  });

  @override
  State<_PreviewHome> createState() => _PreviewHomeState();
}

class _PreviewHomeState extends State<_PreviewHome> {
  static const _collapsed = 92.0;
  static const _expanded = 246.0;
  double _height = _collapsed;
  bool _editing = false;
  int _selected = 0;
  final _order = [...DockController.defaultOrder];

  void _snap(bool expanded) {
    setState(() {
      _height = expanded ? _expanded : _collapsed;
      if (!expanded) _editing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = OblixColors.of(context);
    return Scaffold(
      extendBody: true,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 120),
          children: [
            Text('SATURDAY, AUGUST 8', style: OblixType.eyebrow(c)),
            const SizedBox(height: 7),
            Text('Notes', style: OblixType.pageTitle(c)),
            const SizedBox(height: 16),
            Row(
              children: [
                for (final collection in OblixThemeCollection.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(collection.label),
                      selected: widget.collection == collection,
                      onSelected: (_) => widget.onCollection(collection),
                    ),
                  ),
                const Spacer(),
                Text('Glass', style: OblixType.ui(c, size: 12)),
                Switch.adaptive(value: widget.glass, onChanged: widget.onGlass),
              ],
            ),
            const SizedBox(height: 8),
            _PreviewCard(
              eyebrow: 'PINNED',
              title: 'Designing the next Oblix',
              body:
                  'A calmer place for notes, notebooks, and the work that matters.',
            ),
            const SizedBox(height: 12),
            _PreviewCard(
              eyebrow: 'TODAY',
              title: 'Ideas worth keeping',
              body:
                  'The navigation should feel close, quiet, and immediately familiar.',
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        minimum: const EdgeInsets.fromLTRB(10, 0, 10, 8),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 320),
          height: _height,
          child: NavigationDock(
            order: _order,
            selectedTab: _selected,
            editing: _editing,
            liquidGlass: widget.glass,
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
            // Scan opens a route rather than a tab, so the preview leaves the
            // selection alone for it.
            onDestination: (destination) =>
                setState(() => _selected = destination.tabIndex ?? _selected),
            onPickShortcut: (_) {},
            onSwap: (source, target) async {
              setState(() {
                final sourceIndex = _order.indexOf(source);
                final targetIndex = _order.indexOf(target);
                _order[sourceIndex] = target;
                _order[targetIndex] = source;
              });
            },
            onProfile: () {},
          ),
        ),
      ),
    );
  }
}

class _PreviewCard extends StatelessWidget {
  final String eyebrow;
  final String title;
  final String body;

  const _PreviewCard({
    required this.eyebrow,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    final c = OblixColors.of(context);
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: c.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(eyebrow, style: OblixType.eyebrow(c)),
          const SizedBox(height: 10),
          Text(title, style: OblixType.cardTitle(c)),
          const SizedBox(height: 6),
          Text(body, style: OblixType.snippet(c)),
        ],
      ),
    );
  }
}
