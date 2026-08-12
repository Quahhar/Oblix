import 'package:flutter/material.dart';

import '../../core/db/app_database.dart';
import '../../core/db/meta_dao.dart';

/// Every tool the navigation deck can hold. There are deliberately more of
/// these than the deck has slots — the surplus lives in the expanded dock's
/// tray, where it can be dragged onto a slot to take its place.
enum DockDestination { notes, notebooks, tasks, scan }

extension DockDestinationDetails on DockDestination {
  String get storageKey => switch (this) {
    DockDestination.notes => 'notes',
    DockDestination.notebooks => 'notebooks',
    DockDestination.tasks => 'tasks',
    DockDestination.scan => 'scan',
  };

  String get label => switch (this) {
    DockDestination.notes => 'Note',
    DockDestination.notebooks => 'Notebook',
    DockDestination.tasks => 'Task',
    DockDestination.scan => 'Scan',
  };

  String get blurb => switch (this) {
    DockDestination.notes => 'Everything you have written',
    DockDestination.notebooks => 'Notes grouped into books',
    DockDestination.tasks => 'Things to do, with due dates',
    DockDestination.scan => 'Photograph text into a note',
  };

  IconData get icon => switch (this) {
    DockDestination.notes => Icons.description_outlined,
    DockDestination.notebooks => Icons.auto_stories_outlined,
    DockDestination.tasks => Icons.check_circle_outline,
    DockDestination.scan => Icons.document_scanner_outlined,
  };

  /// The shell tab this destination shows, or null when it starts a flow
  /// instead of switching tabs. Scanning is a capture flow with its own route,
  /// so it never reads as a selected tab.
  int? get tabIndex => switch (this) {
    DockDestination.notes => 0,
    DockDestination.notebooks => 1,
    DockDestination.tasks => 2,
    DockDestination.scan => null,
  };
}

/// Persists the three changeable dock slots. Profile deliberately lives
/// outside this model, which makes it impossible to replace or reorder.
class DockController {
  DockController._();
  static final DockController instance = DockController._();

  static const _key = 'navigation_dock_v1';

  /// Profile is not a [DockDestination] — it can't be reordered or replaced —
  /// but it is still a shell tab, sitting after the three arrangeable ones so
  /// the dock stays on screen while you are on it.
  static const profileTabIndex = 3;

  static const defaultOrder = [
    DockDestination.notes,
    DockDestination.notebooks,
    DockDestination.tasks,
  ];

  /// Slots in the deck, beside the fixed Profile item. Adding a destination
  /// does not widen the bar; it lands in the tray instead.
  static const deckSize = 3;

  final ValueNotifier<List<DockDestination>> order = ValueNotifier(
    List.unmodifiable(defaultOrder),
  );

  /// Destinations the deck is not currently showing, in enum order. These are
  /// what the expanded dock offers in its tray.
  static List<DockDestination> trayFor(List<DockDestination> order) => [
    for (final destination in DockDestination.values)
      if (!order.contains(destination)) destination,
  ];

  Future<void> load() async {
    final raw = await MetaDao(AppDatabase.instance).getSetting(_key);
    order.value = List.unmodifiable(decodeOrder(raw));
  }

  /// Invalid, duplicate, or older saved values recover to a complete deck.
  /// Keeping this public also gives migrations and tests one canonical parser.
  static List<DockDestination> decodeOrder(String? raw) {
    final decoded = <DockDestination>[];
    for (final key in (raw ?? '').split(',')) {
      for (final destination in DockDestination.values) {
        if (destination.storageKey == key && !decoded.contains(destination)) {
          decoded.add(destination);
          break;
        }
      }
    }
    for (final destination in defaultOrder) {
      if (!decoded.contains(destination)) decoded.add(destination);
    }
    return decoded.take(deckSize).toList();
  }

  /// Give [incoming] the slot [target] holds.
  ///
  /// One entry point for both gestures the expanded dock supports: dragging
  /// one deck item onto another trades their places, and dragging a tray item
  /// onto a slot takes it over, sending [target] back to the tray.
  Future<void> assign(DockDestination incoming, DockDestination target) async {
    if (incoming == target) return;
    final next = [...order.value];
    final targetIndex = next.indexOf(target);
    if (targetIndex < 0) return;
    final incomingIndex = next.indexOf(incoming);
    if (incomingIndex >= 0) next[incomingIndex] = target;
    next[targetIndex] = incoming;
    await _save(next);
  }

  /// Chooses a destination for a slot. Selecting a destination already in the
  /// deck swaps the two slots, so the deck never contains duplicates.
  Future<void> setDestination(int index, DockDestination destination) async {
    final next = [...order.value];
    if (index < 0 || index >= next.length || next[index] == destination) return;
    final existingIndex = next.indexOf(destination);
    if (existingIndex >= 0) {
      final previous = next[index];
      next[index] = destination;
      next[existingIndex] = previous;
    } else {
      next[index] = destination;
    }
    await _save(next);
  }

  Future<void> _save(List<DockDestination> value) async {
    order.value = List.unmodifiable(value);
    await MetaDao(AppDatabase.instance).setSetting(
      _key,
      value.map((destination) => destination.storageKey).join(','),
    );
  }
}
