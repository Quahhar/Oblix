//! Presentation logic shared by every note list.
//!
//! Timezone conversion stays in Dart: `DateTime.toLocal()` is the authority for
//! the device's zone and DST, and this crate deliberately builds Chrono without
//! its clock/local features. Dart therefore hands over civil-date components it
//! has already localized, exactly as the archive codecs take pre-formatted
//! timestamp text.

use chrono::{Datelike, NaiveDate};
use flutter_rust_bridge::frb;

use crate::dart_string::{dart_trim, is_dart_regexp_whitespace};

const MONTHS: [&str; 12] = [
    "JANUARY",
    "FEBRUARY",
    "MARCH",
    "APRIL",
    "MAY",
    "JUNE",
    "JULY",
    "AUGUST",
    "SEPTEMBER",
    "OCTOBER",
    "NOVEMBER",
    "DECEMBER",
];

/// One note reduced to what day-grouping needs. The `local_*` fields are the
/// civil date Dart read off `updatedAt.toLocal()`.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NoteDayInput {
    pub id: String,
    pub local_year: i32,
    pub local_month: u32,
    pub local_day: u32,
}

/// Notes that share a heading, in the order the caller supplied them.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NoteDayGroup {
    pub label: String,
    pub note_ids: Vec<String>,
}

/// Collapse a note body into its one-line list preview.
///
/// Ports `content.replaceAll(RegExp(r'\s+'), ' ').trim()`. The two whitespace
/// sets genuinely differ — U+0085 is not in Dart's regexp `\s` but is in
/// `String.trim`'s set — so an interior NEXT LINE survives collapsing while a
/// leading or trailing one is still trimmed.
#[frb(sync)]
pub fn note_snippet(content: String) -> String {
    let mut collapsed = String::with_capacity(content.len());
    let mut in_whitespace = false;
    for character in content.chars() {
        if is_dart_regexp_whitespace(character) {
            if !in_whitespace {
                collapsed.push(' ');
                in_whitespace = true;
            }
        } else {
            collapsed.push(character);
            in_whitespace = false;
        }
    }
    dart_trim(&collapsed).to_owned()
}

/// Group notes under TODAY / YESTERDAY / PREVIOUS 7 DAYS / PREVIOUS 30 DAYS /
/// month / year headings, keeping the caller's order both within and across
/// groups.
///
/// The buckets widen as they recede, the way Apple Notes' list does. A heading
/// per calendar day is accurate and unreadable: a month of daily notes becomes
/// thirty headings over thirty one-row cards, and the list turns into headings
/// with notes in the gaps. These buckets keep the recent past precise — today
/// and yesterday stay their own sections — and let everything older collapse
/// into a handful of sections that are worth scrolling past.
///
/// Grouping is by rendered label, not by date, so every day inside one bucket
/// lands in the same section. Labels are distinct across years by construction:
/// a month name is only used for the current year, and older years are labelled
/// by the year itself.
#[frb(sync)]
pub fn group_notes_by_day(
    notes: Vec<NoteDayInput>,
    today_year: i32,
    today_month: u32,
    today_day: u32,
) -> Vec<NoteDayGroup> {
    let today = NaiveDate::from_ymd_opt(today_year, today_month, today_day);
    let mut groups: Vec<NoteDayGroup> = Vec::new();
    for note in notes {
        let label = day_group_label(&note, today, today_year);
        match groups.iter_mut().find(|group| group.label == label) {
            Some(group) => group.note_ids.push(note.id),
            None => groups.push(NoteDayGroup {
                label,
                note_ids: vec![note.id],
            }),
        }
    }
    groups
}

/// The heading a single note falls under. A component set Chrono rejects
/// degrades to the calendar label rather than panicking.
fn day_group_label(note: &NoteDayInput, today: Option<NaiveDate>, today_year: i32) -> String {
    let day = NaiveDate::from_ymd_opt(note.local_year, note.local_month, note.local_day);
    let (Some(today), Some(day)) = (today, day) else {
        return calendar_label(note.local_year, note.local_month, today_year);
    };
    let days = today.signed_duration_since(day).num_days();
    if days <= 0 {
        return "TODAY".to_owned();
    }
    if days == 1 {
        return "YESTERDAY".to_owned();
    }
    if days < 7 {
        return "PREVIOUS 7 DAYS".to_owned();
    }
    if days < 30 {
        return "PREVIOUS 30 DAYS".to_owned();
    }
    calendar_label(day.year(), day.month(), today.year())
}

/// Older than a month: the month on its own inside the current year, and just
/// the year once the note predates it. The day is deliberately dropped — it is
/// what produced a heading per note.
fn calendar_label(year: i32, month: u32, reference_year: i32) -> String {
    let name = month
        .checked_sub(1)
        .and_then(|index| MONTHS.get(index as usize))
        .copied();
    match name {
        Some(name) if year == reference_year => name.to_owned(),
        // Either the note predates the current year, or its month is out of
        // range — which only happens for a date Chrono already rejected. Either
        // way the year is the most specific heading left.
        _ => year.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn note(id: &str, year: i32, month: u32, day: u32) -> NoteDayInput {
        NoteDayInput {
            id: id.to_owned(),
            local_year: year,
            local_month: month,
            local_day: day,
        }
    }

    #[test]
    fn snippet_collapses_runs_and_trims_like_dart() {
        assert_eq!(note_snippet("  a \n\n b\t c  ".to_owned()), "a b c");
        assert_eq!(note_snippet(String::new()), "");
        assert_eq!(note_snippet(" \n\t ".to_owned()), "");
    }

    #[test]
    fn snippet_keeps_dart_regexp_and_trim_whitespace_sets_apart() {
        // U+FEFF is regexp whitespace, so it collapses into the run.
        assert_eq!(note_snippet("a\u{feff}\u{feff}b".to_owned()), "a b");
        // U+0085 is not, so it survives inside and is trimmed at the edges.
        assert_eq!(note_snippet("a\u{0085}b".to_owned()), "a\u{0085}b");
        assert_eq!(note_snippet("\u{0085}ab\u{0085}".to_owned()), "ab");
    }

    #[test]
    fn groups_widen_from_days_through_windows_to_months_and_years() {
        let groups = group_notes_by_day(
            vec![
                note("today", 2026, 8, 9),
                note("also-today", 2026, 8, 9),
                note("yesterday", 2026, 8, 8),
                note("this-week", 2026, 8, 5),
                note("also-this-week", 2026, 8, 4),
                note("this-month", 2026, 7, 20),
                note("older", 2026, 6, 8),
                note("older-still", 2026, 6, 2),
                note("last-year", 2025, 7, 8),
                note("last-year-too", 2025, 2, 1),
            ],
            2026,
            8,
            9,
        );

        let labels: Vec<&str> = groups.iter().map(|group| group.label.as_str()).collect();
        assert_eq!(
            labels,
            vec![
                "TODAY",
                "YESTERDAY",
                "PREVIOUS 7 DAYS",
                "PREVIOUS 30 DAYS",
                "JUNE",
                "2025",
            ]
        );
        assert_eq!(groups[0].note_ids, vec!["today", "also-today"]);
        assert_eq!(groups[2].note_ids, vec!["this-week", "also-this-week"]);
        assert_eq!(groups[3].note_ids, vec!["this-month"]);
        assert_eq!(groups[4].note_ids, vec!["older", "older-still"]);
        assert_eq!(groups[5].note_ids, vec!["last-year", "last-year-too"]);
    }

    #[test]
    fn a_future_note_still_lands_under_today() {
        let groups = group_notes_by_day(vec![note("ahead", 2026, 8, 10)], 2026, 8, 9);
        assert_eq!(groups[0].label, "TODAY");
    }

    #[test]
    fn bucket_edges_land_on_the_documented_side() {
        let label_for = |year, month, day| {
            group_notes_by_day(vec![note("n", year, month, day)], 2026, 8, 9)[0]
                .label
                .clone()
        };
        // Six days back is still the week window; seven opens the month one.
        assert_eq!(label_for(2026, 8, 3), "PREVIOUS 7 DAYS");
        assert_eq!(label_for(2026, 8, 2), "PREVIOUS 30 DAYS");
        // Twenty-nine days back is the last day of the month window; thirty
        // falls through to the calendar heading.
        assert_eq!(label_for(2026, 7, 11), "PREVIOUS 30 DAYS");
        assert_eq!(label_for(2026, 7, 10), "JULY");
    }

    #[test]
    fn the_thirty_day_window_reaches_back_across_new_year() {
        let groups = group_notes_by_day(vec![note("n", 2025, 12, 20)], 2026, 1, 5);
        assert_eq!(groups[0].label, "PREVIOUS 30 DAYS");
    }

    #[test]
    fn rejects_impossible_components_without_panicking() {
        let groups = group_notes_by_day(vec![note("bad", 2026, 13, 40)], 2026, 8, 9);
        assert_eq!(groups[0].label, "2026");
    }
}
