import 'package:flutter_test/flutter_test.dart';
import 'package:oblix/core/native/oblix_core.dart';

/// The note list's grouping and snippet logic lives in the Rust core. Unit
/// tests run without the native library loaded, so these exercise the Dart
/// oracle in `oblix_core_fallback.dart`; `rust/src/api/view.rs` carries the
/// matching cases on the Rust side so the two stay in step.
void main() {
  NoteDayValue day(String id, int year, int month, int dayOfMonth) =>
      (id: id, localYear: year, localMonth: month, localDay: dayOfMonth);

  group('note snippet', () {
    test('collapses whitespace runs and trims the ends', () {
      expect(noteSnippet('  a \n\n b\t c  '), 'a b c');
      expect(noteSnippet('single'), 'single');
    });

    test('a blank body produces an empty snippet', () {
      expect(noteSnippet(''), '');
      expect(noteSnippet('  \n\t  '), '');
    });

    test('matches the raw Dart expression it replaced', () {
      for (final sample in [
        'plain',
        '  padded  ',
        'many\n\n\nlines',
        'tabs\t\tand   spaces',
        '\u{feff}bom wrapped\u{feff}',
      ]) {
        expect(
          noteSnippet(sample),
          sample.replaceAll(RegExp(r'\s+'), ' ').trim(),
          reason: 'snippet for "$sample"',
        );
      }
    });
  });

  group('day grouping', () {
    test('widens from days through windows to months and years', () {
      final groups = groupNotesByDay(
        notes: [
          day('a', 2026, 8, 9),
          day('b', 2026, 8, 9),
          day('c', 2026, 8, 8),
          day('d', 2026, 8, 5),
          day('e', 2026, 8, 4),
          day('f', 2026, 7, 20),
          day('g', 2026, 6, 8),
          day('h', 2026, 6, 2),
          day('i', 2025, 7, 8),
          day('j', 2025, 2, 1),
        ],
        todayYear: 2026,
        todayMonth: 8,
        todayDay: 9,
      );

      expect(groups.map((group) => group.label).toList(), [
        'TODAY',
        'YESTERDAY',
        'PREVIOUS 7 DAYS',
        'PREVIOUS 30 DAYS',
        'JUNE',
        '2025',
      ]);
      // Every day inside one window collapses into that window's section —
      // the whole point of the change.
      expect(groups[2].noteIds, ['d', 'e']);
      expect(groups[4].noteIds, ['g', 'h']);
      expect(groups[5].noteIds, ['i', 'j']);
    });

    test('keeps the caller order inside and across groups', () {
      final groups = groupNotesByDay(
        notes: [
          day('first', 2026, 8, 9),
          day('older', 2026, 8, 8),
          day('second', 2026, 8, 9),
        ],
        todayYear: 2026,
        todayMonth: 8,
        todayDay: 9,
      );

      expect(groups.first.noteIds, ['first', 'second']);
      expect(groups.last.noteIds, ['older']);
    });

    test('bucket edges land on the documented side', () {
      String labelFor(int year, int month, int dayOfMonth) => groupNotesByDay(
        notes: [day('n', year, month, dayOfMonth)],
        todayYear: 2026,
        todayMonth: 8,
        todayDay: 9,
      ).single.label;

      // Six days back is still the week window; seven opens the month one.
      expect(labelFor(2026, 8, 3), 'PREVIOUS 7 DAYS');
      expect(labelFor(2026, 8, 2), 'PREVIOUS 30 DAYS');
      // Twenty-nine days back is the last day of the month window; thirty
      // falls through to the calendar heading.
      expect(labelFor(2026, 7, 11), 'PREVIOUS 30 DAYS');
      expect(labelFor(2026, 7, 10), 'JULY');
    });

    test('the thirty-day window reaches back across new year', () {
      final groups = groupNotesByDay(
        notes: [day('n', 2025, 12, 20)],
        todayYear: 2026,
        todayMonth: 1,
        todayDay: 5,
      );
      expect(groups.single.label, 'PREVIOUS 30 DAYS');
    });

    test('a note dated ahead of today still lands under TODAY', () {
      final groups = groupNotesByDay(
        notes: [day('ahead', 2026, 8, 10)],
        todayYear: 2026,
        todayMonth: 8,
        todayDay: 9,
      );
      expect(groups.single.label, 'TODAY');
    });

    test('no notes produces no groups', () {
      expect(
        groupNotesByDay(
          notes: const [],
          todayYear: 2026,
          todayMonth: 8,
          todayDay: 9,
        ),
        isEmpty,
      );
    });
  });
}
