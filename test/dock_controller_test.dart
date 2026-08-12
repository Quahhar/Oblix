import 'package:flutter_test/flutter_test.dart';
import 'package:oblix/ui/shell/dock_controller.dart';

void main() {
  test('dock defaults to Note, Notebook, Task', () {
    expect(DockController.decodeOrder(null), DockController.defaultOrder);
  });

  test('dock restores a custom order', () {
    expect(DockController.decodeOrder('tasks,notes,notebooks'), [
      DockDestination.tasks,
      DockDestination.notes,
      DockDestination.notebooks,
    ]);
  });

  test('dock repairs duplicates and unknown future values', () {
    expect(DockController.decodeOrder('tasks,telepathy,tasks'), [
      DockDestination.tasks,
      DockDestination.notes,
      DockDestination.notebooks,
    ]);
  });

  test('dock labels use the requested singular names', () {
    expect(DockDestination.notes.label, 'Note');
    expect(DockDestination.notebooks.label, 'Notebook');
    expect(DockDestination.tasks.label, 'Task');
    expect(DockDestination.scan.label, 'Scan');
  });

  group('deck and tray', () {
    test('the bar stays three wide even though there are four tools', () {
      expect(
        DockDestination.values.length,
        greaterThan(DockController.deckSize),
      );
      expect(
        DockController.decodeOrder(null),
        hasLength(DockController.deckSize),
      );
    });

    test('Scan is off the bar by default and waits in the tray', () {
      final order = DockController.decodeOrder(null);
      expect(order, isNot(contains(DockDestination.scan)));
      expect(DockController.trayFor(order), [DockDestination.scan]);
    });

    test('a saved deck holding Scan restores with it, still three wide', () {
      final order = DockController.decodeOrder('scan,notebooks,tasks');
      expect(order, [
        DockDestination.scan,
        DockDestination.notebooks,
        DockDestination.tasks,
      ]);
      // Whatever Scan displaced is what the tray now offers.
      expect(DockController.trayFor(order), [DockDestination.notes]);
    });

    test('the tray is whatever the deck is not showing', () {
      expect(DockController.trayFor([DockDestination.notes]), [
        DockDestination.notebooks,
        DockDestination.tasks,
        DockDestination.scan,
      ]);
      expect(DockController.trayFor(DockDestination.values), isEmpty);
    });
  });

  group('scan is a flow, not a tab', () {
    test('browsing destinations map to shell tabs', () {
      expect(DockDestination.notes.tabIndex, 0);
      expect(DockDestination.notebooks.tabIndex, 1);
      expect(DockDestination.tasks.tabIndex, 2);
    });

    test('Scan has no tab, so it can never read as selected', () {
      expect(DockDestination.scan.tabIndex, isNull);
      expect(
        DockDestination.scan.tabIndex == DockController.profileTabIndex,
        isFalse,
      );
    });
  });
}
