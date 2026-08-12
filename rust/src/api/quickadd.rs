//! One typed line in, one scheduled task out.
//!
//! `pay rent tomorrow 5pm p1 #home every month` should become a task called
//! "pay rent", due tomorrow at five, urgent, filed under Home, repeating
//! monthly — without the user ever opening a date picker. That single
//! interaction is the difference between a task app people use and one they
//! abandon, so the whole grammar lives here where it can be tested exhaustively
//! and behaves identically on every platform.
//!
//! Three design commitments are worth stating.
//!
//! *Offsets are UTF-16.* The spans come back in the units Dart's `String` and
//! `TextEditingValue` use, so the field can underline what it recognized as the
//! user types without the editor and the parser disagreeing about where a
//! character is. An emoji in a task title must not shift the highlight.
//!
//! *Quoting always wins.* Anything inside double quotes is literal. Without an
//! escape hatch a title like `review "monday" draft` silently loses a word, and
//! a parser you cannot overrule is worse than no parser.
//!
//! *No clock, no zone.* As everywhere else in the crate, Dart supplies today's
//! civil date and the current wall time, and gets civil components back.

use flutter_rust_bridge::frb;

use super::tasks::{
    serialize_recurrence, CivilDate, CivilTime, RecurrenceFreq, RecurrenceMode, RecurrenceRule,
    PRIORITY_HIGH, PRIORITY_LOW, PRIORITY_NONE, PRIORITY_URGENT,
};
use crate::dart_string::is_dart_regexp_whitespace;

/// Longest line we will parse. A quick-add field is one sentence; anything past
/// this is pasted prose and becomes the title verbatim.
const MAX_INPUT_UTF16: usize = 2_000;

/// Punctuation trimmed from the front of a word before matching.
const LEADING_TRIM: &[char] = &['(', '[', '{', '"', '\'', '\u{201c}', '\u{2018}'];
/// Punctuation trimmed from the end of a word before matching.
const TRAILING_TRIM: &[char] = &[
    ',', '.', ';', ':', '?', ')', ']', '}', '"', '\'', '!', '\u{201d}', '\u{2019}',
];

const WEEKDAY_NAMES: [(&str, u32); 18] = [
    ("monday", 0),
    ("mon", 0),
    ("tuesday", 1),
    ("tues", 1),
    ("tue", 1),
    ("wednesday", 2),
    ("weds", 2),
    ("wed", 2),
    ("thursday", 3),
    ("thurs", 3),
    ("thur", 3),
    ("thu", 3),
    ("friday", 4),
    ("fri", 4),
    ("saturday", 5),
    ("sat", 5),
    ("sunday", 6),
    ("sun", 6),
];

const MONTH_NAMES: [(&str, u32); 23] = [
    ("january", 1),
    ("jan", 1),
    ("february", 2),
    ("feb", 2),
    ("march", 3),
    ("mar", 3),
    ("april", 4),
    ("apr", 4),
    ("may", 5),
    ("june", 6),
    ("jun", 6),
    ("july", 7),
    ("jul", 7),
    ("august", 8),
    ("aug", 8),
    ("september", 9),
    ("sep", 9),
    ("october", 10),
    ("oct", 10),
    ("november", 11),
    ("nov", 11),
    ("december", 12),
    ("dec", 12),
];

const NUMBER_WORDS: [(&str, u32); 12] = [
    ("one", 1),
    ("two", 2),
    ("three", 3),
    ("four", 4),
    ("five", 5),
    ("six", 6),
    ("seven", 7),
    ("eight", 8),
    ("nine", 9),
    ("ten", 10),
    ("eleven", 11),
    ("twelve", 12),
];

/// What the device knows and the parser cannot.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct QuickAddContext {
    pub today: CivilDate,
    pub now: CivilTime,
    /// Monday-relative index of today (0 = Monday), which Dart reads off
    /// `DateTime.weekday`. Supplied rather than derived so the parser never
    /// needs a calendar for the common relative cases.
    pub today_weekday: u32,
    /// Whether the week the user sees starts on Monday. Decides what "next
    /// Friday" means when today is a Saturday.
    pub week_start_monday: bool,
    /// Whether a bare numeric date like `3/4` is March 4th (US) or 4 March.
    pub month_first: bool,
}

/// The kind of thing a highlighted span turned out to be, so the field can
/// tint a date differently from a label.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum QuickAddTokenKind {
    Date,
    Time,
    Priority,
    Project,
    Label,
    Recurrence,
    Reminder,
}

/// A recognized run of the input, in UTF-16 code units.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct QuickAddSpan {
    pub start: u32,
    pub end: u32,
    pub kind: QuickAddTokenKind,
}

/// Everything one line said.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct QuickAddParse {
    pub title: String,
    pub priority: i32,
    pub project: Option<String>,
    pub labels: Vec<String>,
    pub due: Option<CivilDate>,
    /// `None` means an all-day task even when `due` is set.
    pub due_time: Option<CivilTime>,
    /// Serialized [`RecurrenceRule`], ready for the `recurrence` column.
    pub recurrence: Option<String>,
    pub reminder_lead_minutes: Option<i32>,
    pub spans: Vec<QuickAddSpan>,
}

/// One whitespace-separated run of the input.
struct Word {
    /// The run exactly as typed, used to rebuild the title.
    raw: String,
    /// Lowercased and stripped of surrounding punctuation, used to match.
    lower: String,
    /// Core bounds in UTF-16 code units.
    start: u32,
    end: u32,
    /// Inside double quotes, so never matched.
    protected: bool,
    /// The run ended in `!` before trimming — Todoist's marker for a rule that
    /// counts from completion rather than from the schedule.
    had_bang: bool,
    consumed: bool,
}

/// Accumulated findings, applied in one pass over the words.
///
/// Internal to the parse; the bridge must not mirror it. Only
/// [`QuickAddParse`] crosses into Dart.
#[frb(ignore)]
#[derive(Default)]
struct Found {
    priority: Option<i32>,
    project: Option<String>,
    labels: Vec<String>,
    date: Option<CivilDate>,
    time: Option<CivilTime>,
    recurrence: Option<RecurrenceRule>,
    reminder: Option<i32>,
}

/// Parse a quick-add line.
///
/// Every token kind is recognized at most once — the first date wins, the first
/// time wins — except labels, which accumulate. A second date-looking word is
/// left in the title, because "move the Monday meeting to Tuesday" should keep
/// its subject.
#[frb(sync)]
pub fn parse_quick_add(text: String, context: QuickAddContext) -> QuickAddParse {
    let mut words = tokenize(&text);
    let mut found = Found::default();

    if text.encode_utf16().count() <= MAX_INPUT_UTF16 {
        let mut spans = Vec::new();
        let mut index = 0;
        while index < words.len() {
            match match_at(&words, index, &context, &found) {
                Some(hit) => {
                    let start = words[index].start;
                    let end = words[index + hit.length - 1].end;
                    spans.push(QuickAddSpan {
                        start,
                        end,
                        kind: hit.kind,
                    });
                    for word in words.iter_mut().skip(index).take(hit.length) {
                        word.consumed = true;
                    }
                    apply(&mut found, hit.effect);
                    index += hit.length;
                }
                None => index += 1,
            }
        }
        return finish(&words, found, spans, &context);
    }

    finish(&words, found, Vec::new(), &context)
}

/// Assemble the result once every word has been classified.
fn finish(
    words: &[Word],
    mut found: Found,
    spans: Vec<QuickAddSpan>,
    context: &QuickAddContext,
) -> QuickAddParse {
    // A bare time implies a day: "call the bank 5pm" means today, unless five
    // has already been and gone, in which case it means tomorrow. Dropping the
    // time instead would silently discard something the user typed.
    if found.date.is_none() {
        if let Some(time) = found.time {
            let now_minutes = context.now.hour.min(23) * 60 + context.now.minute.min(59);
            let target = time.hour * 60 + time.minute;
            found.date = if target > now_minutes {
                Some(context.today)
            } else {
                shift_days(context.today, 1)
            };
        }
    }

    // A repeating task with no stated date starts at its first occurrence, so
    // "water plants every 3 days" is due today rather than floating undated.
    if found.date.is_none() {
        if let Some(rule) = &found.recurrence {
            found.date = first_occurrence(rule, context);
        }
    }

    QuickAddParse {
        title: rebuild_title(words),
        priority: found.priority.unwrap_or(PRIORITY_NONE),
        project: found.project,
        labels: found.labels,
        due: found.date,
        due_time: found.date.and(found.time),
        recurrence: found.recurrence.map(serialize_recurrence),
        reminder_lead_minutes: found.reminder,
        spans,
    }
}

/// The words that were not consumed, rejoined.
///
/// Interior spacing is normalized to single spaces: the input is one line, and
/// a title assembled out of the surviving words reads better than one with the
/// gaps left by removed tokens.
fn rebuild_title(words: &[Word]) -> String {
    let mut parts: Vec<String> = Vec::new();
    for word in words.iter().filter(|word| !word.consumed) {
        let cleaned: String = word.raw.chars().filter(|c| *c != '"').collect();
        if !cleaned.is_empty() {
            parts.push(cleaned);
        }
    }
    // Punctuation left stranded by a removed token ("call mum , tomorrow")
    // is dropped rather than preserved as its own word.
    parts.retain(|part| part.chars().any(|c| !TRAILING_TRIM.contains(&c)));
    let joined = parts.join(" ");
    joined
        .trim_matches(|c: char| is_dart_regexp_whitespace(c) || matches!(c, ',' | ';' | ':' | '-'))
        .to_owned()
}

/// A matched token: how many words it spanned and what it meant.
struct Hit {
    length: usize,
    kind: QuickAddTokenKind,
    effect: Effect,
}

enum Effect {
    Priority(i32),
    Project(String),
    Label(String),
    Date(CivilDate),
    Time(CivilTime),
    DateTime(CivilDate, CivilTime),
    Recurrence(RecurrenceRule),
    Reminder(i32),
}

fn apply(found: &mut Found, effect: Effect) {
    match effect {
        Effect::Priority(value) => found.priority = Some(value),
        Effect::Project(name) => found.project = Some(name),
        Effect::Label(name) => {
            if !found.labels.iter().any(|entry| entry == &name) {
                found.labels.push(name);
            }
        }
        Effect::Date(date) => found.date = Some(date),
        Effect::Time(time) => found.time = Some(time),
        Effect::DateTime(date, time) => {
            found.date = Some(date);
            found.time = Some(time);
        }
        Effect::Recurrence(rule) => found.recurrence = Some(rule),
        Effect::Reminder(minutes) => found.reminder = Some(minutes),
    }
}

/// Try every matcher at one position, longest and most specific first.
///
/// Recurrence is attempted before dates so "every monday" is a rule rather than
/// the word "every" followed by a date, and reminders before times for the same
/// reason.
fn match_at(words: &[Word], index: usize, context: &QuickAddContext, found: &Found) -> Option<Hit> {
    let word = &words[index];
    if word.protected || word.consumed || word.lower.is_empty() {
        return None;
    }

    if found.priority.is_none() {
        if let Some(hit) = match_priority(word) {
            return Some(hit);
        }
    }
    if found.project.is_none() {
        if let Some(hit) = match_prefixed(word, '#', QuickAddTokenKind::Project) {
            return Some(hit);
        }
    }
    if let Some(hit) = match_prefixed(word, '@', QuickAddTokenKind::Label) {
        return Some(hit);
    }
    if found.recurrence.is_none() {
        if let Some(hit) = match_recurrence(words, index) {
            return Some(hit);
        }
    }
    if found.reminder.is_none() {
        if let Some(hit) = match_reminder(words, index) {
            return Some(hit);
        }
    }
    if found.date.is_none() {
        if let Some(hit) = match_date(words, index, context) {
            return Some(hit);
        }
    }
    if found.time.is_none() {
        if let Some(hit) = match_time(words, index) {
            return Some(hit);
        }
    }
    None
}

fn match_priority(word: &Word) -> Option<Hit> {
    let digit = match word.lower.as_str() {
        "p1" | "!1" => 1,
        "p2" | "!2" => 2,
        "p3" | "!3" => 3,
        "p4" | "!4" => 4,
        _ => return None,
    };
    // Todoist counts down — p1 is the most urgent — while the stored rank
    // counts up so ordering is plain arithmetic.
    let value = match digit {
        1 => PRIORITY_URGENT,
        2 => PRIORITY_HIGH,
        3 => PRIORITY_LOW,
        _ => PRIORITY_NONE,
    };
    Some(Hit {
        length: 1,
        kind: QuickAddTokenKind::Priority,
        effect: Effect::Priority(value),
    })
}

/// `#project` and `@label`. The sigil alone is not a token.
fn match_prefixed(word: &Word, sigil: char, kind: QuickAddTokenKind) -> Option<Hit> {
    let rest = word.lower.strip_prefix(sigil)?;
    if rest.is_empty() {
        return None;
    }
    // Take the name from the raw word so the user's capitalization survives.
    let raw = word
        .raw
        .trim_start_matches(LEADING_TRIM)
        .trim_end_matches(TRAILING_TRIM);
    let name = raw.strip_prefix(sigil).unwrap_or(rest).replace('_', " ");
    if name.is_empty() {
        return None;
    }
    let effect = match kind {
        QuickAddTokenKind::Project => Effect::Project(name),
        _ => Effect::Label(name),
    };
    Some(Hit {
        length: 1,
        kind,
        effect,
    })
}

fn match_recurrence(words: &[Word], index: usize) -> Option<Hit> {
    let head = words[index].lower.as_str();
    let completion = words[index].had_bang;
    let mode = if completion {
        RecurrenceMode::Completion
    } else {
        RecurrenceMode::Schedule
    };
    let make = |freq, interval, by_weekday: Vec<u32>, length| {
        Some(Hit {
            length,
            kind: QuickAddTokenKind::Recurrence,
            effect: Effect::Recurrence(RecurrenceRule {
                freq,
                interval,
                by_weekday,
                mode,
            }),
        })
    };

    // Single-word forms.
    match head {
        "daily" | "everyday" => return make(RecurrenceFreq::Daily, 1, Vec::new(), 1),
        "weekly" => return make(RecurrenceFreq::Weekly, 1, Vec::new(), 1),
        "monthly" => return make(RecurrenceFreq::Monthly, 1, Vec::new(), 1),
        "yearly" | "annually" => return make(RecurrenceFreq::Yearly, 1, Vec::new(), 1),
        "every" => {}
        _ => return None,
    }

    let next = words.get(index + 1)?;
    if next.protected {
        return None;
    }

    // "every weekday" / "every day" / "every week" ...
    if let Some(hit) = match next.lower.as_str() {
        "day" => make(RecurrenceFreq::Daily, 1, Vec::new(), 2),
        "week" => make(RecurrenceFreq::Weekly, 1, Vec::new(), 2),
        "month" => make(RecurrenceFreq::Monthly, 1, Vec::new(), 2),
        "year" => make(RecurrenceFreq::Yearly, 1, Vec::new(), 2),
        "weekday" | "weekdays" => make(RecurrenceFreq::Weekly, 1, vec![0, 1, 2, 3, 4], 2),
        "weekend" | "weekends" => make(RecurrenceFreq::Weekly, 1, vec![5, 6], 2),
        "morning" | "night" | "evening" => make(RecurrenceFreq::Daily, 1, Vec::new(), 2),
        _ => None,
    } {
        return Some(hit);
    }

    // "every other week"
    if next.lower == "other" {
        let unit = words.get(index + 2)?;
        return match unit.lower.as_str() {
            "day" => make(RecurrenceFreq::Daily, 2, Vec::new(), 3),
            "week" => make(RecurrenceFreq::Weekly, 2, Vec::new(), 3),
            "month" => make(RecurrenceFreq::Monthly, 2, Vec::new(), 3),
            "year" => make(RecurrenceFreq::Yearly, 2, Vec::new(), 3),
            _ => weekday_index(&unit.lower)
                .and_then(|day| make(RecurrenceFreq::Weekly, 2, vec![day], 3)),
        };
    }

    // "every 2 weeks"
    if let Some(count) = parse_count(&next.lower) {
        let unit = words.get(index + 2)?;
        let freq = match singular(&unit.lower) {
            "day" => RecurrenceFreq::Daily,
            "week" => RecurrenceFreq::Weekly,
            "month" => RecurrenceFreq::Monthly,
            "year" => RecurrenceFreq::Yearly,
            _ => return None,
        };
        return make(freq, count, Vec::new(), 3);
    }

    // "every monday", "every mon and thu", "every tue, thu"
    let mut days = Vec::new();
    let mut length = 1;
    let mut cursor = index + 1;
    while let Some(word) = words.get(cursor) {
        if word.protected {
            break;
        }
        if word.lower == "and" && !days.is_empty() {
            cursor += 1;
            length += 1;
            continue;
        }
        match weekday_index(&word.lower) {
            Some(day) => {
                if !days.contains(&day) {
                    days.push(day);
                }
                cursor += 1;
                length += 1;
            }
            None => break,
        }
    }
    if days.is_empty() {
        return None;
    }
    // A dangling "and" must not stay highlighted if no day followed it.
    while length > 1 && words[index + length - 1].lower == "and" {
        length -= 1;
    }
    make(RecurrenceFreq::Weekly, 1, days, length)
}

/// `remind me 30m before`, `remind 1 hour before`, `remind 15 minutes before`.
fn match_reminder(words: &[Word], index: usize) -> Option<Hit> {
    if words[index].lower != "remind" {
        return None;
    }
    let mut cursor = index + 1;
    if words.get(cursor).map(|word| word.lower.as_str()) == Some("me") {
        cursor += 1;
    }
    let amount_word = words.get(cursor)?;
    let (minutes, consumed) = match parse_duration(&amount_word.lower) {
        // "30m" is one word.
        Some(minutes) => (minutes, 1),
        // "30 minutes" is two.
        None => {
            let count = parse_count(&amount_word.lower)?;
            let unit = words.get(cursor + 1)?;
            let scale = match singular(&unit.lower) {
                "minute" | "min" => 1,
                "hour" | "hr" => 60,
                "day" => 1440,
                _ => return None,
            };
            (count * scale, 2)
        }
    };
    cursor += consumed;
    // "before" is optional but consumed when present, so it leaves the title.
    if words.get(cursor).map(|word| word.lower.as_str()) == Some("before") {
        cursor += 1;
    }
    Some(Hit {
        length: cursor - index,
        kind: QuickAddTokenKind::Reminder,
        effect: Effect::Reminder(minutes.min(40_320) as i32),
    })
}

fn match_date(words: &[Word], index: usize, context: &QuickAddContext) -> Option<Hit> {
    let word = &words[index];
    let today = context.today;

    let day = |offset: i64| shift_days(today, offset);

    match word.lower.as_str() {
        "today" => {
            return Some(date_hit(today, 1));
        }
        "tomorrow" | "tmr" | "tmrw" | "tom" => {
            return day(1).map(|date| date_hit(date, 1));
        }
        "yesterday" => {
            return day(-1).map(|date| date_hit(date, 1));
        }
        "tonight" => {
            return Some(Hit {
                length: 1,
                kind: QuickAddTokenKind::Date,
                effect: Effect::DateTime(
                    today,
                    CivilTime {
                        hour: 20,
                        minute: 0,
                    },
                ),
            });
        }
        _ => {}
    }

    // "next week" / "next month" / "next monday" / "this friday"
    if matches!(word.lower.as_str(), "next" | "this" | "coming") {
        let target = words.get(index + 1)?;
        if target.protected {
            return None;
        }
        let is_next = word.lower == "next";
        if let Some(weekday) = weekday_index(&target.lower) {
            let date = resolve_weekday(context, weekday, is_next)?;
            return Some(date_hit(date, 2));
        }
        if is_next {
            return match target.lower.as_str() {
                "week" => day(7).map(|date| date_hit(date, 2)),
                "month" => add_months_civil(today, 1).map(|date| date_hit(date, 2)),
                "year" => add_months_civil(today, 12).map(|date| date_hit(date, 2)),
                _ => None,
            };
        }
        return None;
    }

    // "in 3 days" / "in 2 weeks"
    if word.lower == "in" {
        let amount = words.get(index + 1)?;
        let unit = words.get(index + 2)?;
        let count = parse_count(&amount.lower)? as i64;
        return match singular(&unit.lower) {
            "day" => day(count).map(|date| date_hit(date, 3)),
            "week" => day(count * 7).map(|date| date_hit(date, 3)),
            "month" => add_months_civil(today, count as i32).map(|date| date_hit(date, 3)),
            "year" => add_months_civil(today, count as i32 * 12).map(|date| date_hit(date, 3)),
            _ => None,
        };
    }

    // A bare weekday means the next one, today included.
    if let Some(weekday) = weekday_index(&word.lower) {
        let date = resolve_weekday(context, weekday, false)?;
        return Some(date_hit(date, 1));
    }

    // "aug 12", "august 12 2027"
    if let Some(month) = month_index(&word.lower) {
        let day_word = words.get(index + 1)?;
        let day_number = parse_count(&day_word.lower)?;
        if day_number == 0 || day_number > 31 {
            return None;
        }
        let (year, length) = match words
            .get(index + 2)
            .and_then(|word| parse_year(&word.lower))
        {
            Some(year) => (year, 3),
            None => (roll_year(today, month, day_number), 2),
        };
        return valid_date(year, month, day_number).map(|date| date_hit(date, length));
    }

    // "12 aug", "12 august 2027"
    if let Some(day_number) = parse_count(&word.lower) {
        if (1..=31).contains(&day_number) {
            if let Some(month) = words.get(index + 1).and_then(|w| month_index(&w.lower)) {
                let (year, length) = match words
                    .get(index + 2)
                    .and_then(|word| parse_year(&word.lower))
                {
                    Some(year) => (year, 3),
                    None => (roll_year(today, month, day_number), 2),
                };
                return valid_date(year, month, day_number).map(|date| date_hit(date, length));
            }
        }
    }

    // "12/8", "12/8/2027", "12-8"
    if let Some(date) = parse_numeric_date(&word.lower, context) {
        return Some(date_hit(date, 1));
    }

    None
}

fn date_hit(date: CivilDate, length: usize) -> Hit {
    Hit {
        length,
        kind: QuickAddTokenKind::Date,
        effect: Effect::Date(date),
    }
}

fn match_time(words: &[Word], index: usize) -> Option<Hit> {
    let word = &words[index];

    let named = match word.lower.as_str() {
        "noon" | "midday" => Some(CivilTime {
            hour: 12,
            minute: 0,
        }),
        "midnight" => Some(CivilTime { hour: 0, minute: 0 }),
        "morning" => Some(CivilTime { hour: 9, minute: 0 }),
        "afternoon" => Some(CivilTime {
            hour: 14,
            minute: 0,
        }),
        "evening" => Some(CivilTime {
            hour: 18,
            minute: 0,
        }),
        _ => None,
    };
    if let Some(time) = named {
        return Some(Hit {
            length: 1,
            kind: QuickAddTokenKind::Time,
            effect: Effect::Time(time),
        });
    }

    // "at 5pm" / "at 17:00" / "at 5"
    if word.lower == "at" {
        let target = words.get(index + 1)?;
        if target.protected {
            return None;
        }
        if let Some(time) = parse_clock(&target.lower, true) {
            return Some(Hit {
                length: 2,
                kind: QuickAddTokenKind::Time,
                effect: Effect::Time(time),
            });
        }
        return None;
    }

    // A bare "5pm" or "17:00"; a bare "5" is not a time, or every quantity in
    // a title would become one.
    parse_clock(&word.lower, false).map(|time| Hit {
        length: 1,
        kind: QuickAddTokenKind::Time,
        effect: Effect::Time(time),
    })
}

/// Parse a clock reading.
///
/// `bare_hour_allowed` is set only after an explicit "at", where a lone number
/// is unambiguous enough to accept. A bare number without it stays part of the
/// title.
fn parse_clock(token: &str, bare_hour_allowed: bool) -> Option<CivilTime> {
    let (body, meridiem) = if let Some(rest) = token.strip_suffix("am") {
        (rest, Some(false))
    } else if let Some(rest) = token.strip_suffix("pm") {
        (rest, Some(true))
    } else if let Some(rest) = token.strip_suffix('a') {
        (rest, Some(false))
    } else if let Some(rest) = token.strip_suffix('p') {
        (rest, Some(true))
    } else {
        (token, None)
    };
    let body = body.trim_end_matches('.').trim();
    if body.is_empty() {
        return None;
    }

    let (hour, minute) = match body.split_once(':') {
        Some((hour, minute)) => (
            hour.parse::<u32>().ok()?,
            minute.parse::<u32>().ok().filter(|value| *value < 60)?,
        ),
        None => {
            let hour = body.parse::<u32>().ok()?;
            // "1730" is not accepted: the risk of eating a quantity out of a
            // title outweighs the convenience.
            if meridiem.is_none() && !bare_hour_allowed {
                return None;
            }
            (hour, 0)
        }
    };

    match meridiem {
        Some(is_pm) => {
            if hour == 0 || hour > 12 {
                return None;
            }
            let hour = match (hour, is_pm) {
                (12, false) => 0,
                (12, true) => 12,
                (value, true) => value + 12,
                (value, false) => value,
            };
            Some(CivilTime { hour, minute })
        }
        None => {
            if hour > 23 {
                return None;
            }
            // A bare "at 5" means the afternoon; "at 9" means the morning.
            // People say the first about dinner and the second about work.
            let hour = if body.contains(':') || hour > 12 {
                hour
            } else if (1..=7).contains(&hour) {
                hour + 12
            } else {
                hour
            };
            Some(CivilTime { hour, minute })
        }
    }
}

/// "30m", "2h", "45min", "1hr".
fn parse_duration(token: &str) -> Option<u32> {
    let (digits, scale) = if let Some(rest) = token.strip_suffix("minutes") {
        (rest, 1)
    } else if let Some(rest) = token.strip_suffix("mins") {
        (rest, 1)
    } else if let Some(rest) = token.strip_suffix("min") {
        (rest, 1)
    } else if let Some(rest) = token.strip_suffix("hours") {
        (rest, 60)
    } else if let Some(rest) = token.strip_suffix("hrs") {
        (rest, 60)
    } else if let Some(rest) = token.strip_suffix("hr") {
        (rest, 60)
    } else if let Some(rest) = token.strip_suffix('m') {
        (rest, 1)
    } else if let Some(rest) = token.strip_suffix('h') {
        (rest, 60)
    } else if let Some(rest) = token.strip_suffix('d') {
        (rest, 1440)
    } else {
        return None;
    };
    if digits.is_empty() {
        return None;
    }
    digits.parse::<u32>().ok().map(|value| value * scale)
}

fn parse_count(token: &str) -> Option<u32> {
    if let Ok(value) = token.parse::<u32>() {
        return Some(value);
    }
    NUMBER_WORDS
        .iter()
        .find(|(name, _)| *name == token)
        .map(|(_, value)| *value)
}

fn parse_year(token: &str) -> Option<i32> {
    let value = token.parse::<i32>().ok()?;
    match token.len() {
        4 if (1900..=2999).contains(&value) => Some(value),
        2 => Some(2000 + value),
        _ => None,
    }
}

/// "12/8", "12-8-2027". Ambiguity is resolved by the caller's locale flag
/// unless one component is too large to be a month.
fn parse_numeric_date(token: &str, context: &QuickAddContext) -> Option<CivilDate> {
    let separator = if token.contains('/') {
        '/'
    } else if token.matches('-').count() >= 1 && !token.starts_with('-') {
        '-'
    } else {
        return None;
    };
    let parts: Vec<&str> = token.split(separator).collect();
    if parts.len() < 2 || parts.len() > 3 {
        return None;
    }
    if parts.iter().any(|part| part.is_empty()) {
        return None;
    }

    // A leading four-digit year is ISO order and never ambiguous.
    if parts.len() == 3 && parts[0].len() == 4 {
        let year = parse_year(parts[0])?;
        let month = parts[1].parse::<u32>().ok()?;
        let day = parts[2].parse::<u32>().ok()?;
        return valid_date(year, month, day);
    }

    let first = parts[0].parse::<u32>().ok()?;
    let second = parts[1].parse::<u32>().ok()?;

    // A component over 12 cannot be a month, which settles the order on its
    // own. Only a genuinely ambiguous pair falls through to the locale.
    let month_leads = if first > 12 {
        false
    } else if second > 12 {
        true
    } else {
        context.month_first
    };
    let (month, day) = if month_leads {
        (first, second)
    } else {
        (second, first)
    };

    let year = match parts.get(2) {
        Some(part) => parse_year(part)?,
        None => roll_year(context.today, month, day),
    };
    valid_date(year, month, day)
}

/// A month/day with no year means the next time it comes around.
fn roll_year(today: CivilDate, month: u32, day: u32) -> i32 {
    let passed = month < today.month || (month == today.month && day < today.day);
    if passed {
        today.year + 1
    } else {
        today.year
    }
}

/// The next occurrence of a weekday.
///
/// Plain `friday` is the nearest Friday including today. `next friday` skips
/// into the following week, which is what people mean when they say it on a
/// Wednesday — and, because "the following week" depends on where the week
/// starts, the caller's convention decides.
fn resolve_weekday(context: &QuickAddContext, weekday: u32, is_next: bool) -> Option<CivilDate> {
    let today_index = context.today_weekday.min(6);
    let mut offset = (weekday + 7 - today_index) % 7;
    if is_next {
        if offset == 0 {
            offset = 7;
        }
        // Still inside the current week: push a full week out.
        let position_today = week_position(today_index, context.week_start_monday);
        let position_target = week_position((today_index + offset) % 7, context.week_start_monday);
        if position_target > position_today {
            offset += 7;
        }
    }
    shift_days(context.today, offset as i64)
}

/// Where a Monday-relative weekday sits in the user's week.
fn week_position(weekday: u32, week_start_monday: bool) -> u32 {
    if week_start_monday {
        weekday
    } else {
        // Sunday first.
        (weekday + 1) % 7
    }
}

/// The first date a rule fires on, counting today.
fn first_occurrence(rule: &RecurrenceRule, context: &QuickAddContext) -> Option<CivilDate> {
    if rule.freq == RecurrenceFreq::Weekly && !rule.by_weekday.is_empty() {
        let today_index = context.today_weekday.min(6);
        let offset = rule
            .by_weekday
            .iter()
            .map(|day| (*day + 7 - today_index) % 7)
            .min()?;
        return shift_days(context.today, offset as i64);
    }
    Some(context.today)
}

fn weekday_index(token: &str) -> Option<u32> {
    WEEKDAY_NAMES
        .iter()
        .find(|(name, _)| *name == token)
        .map(|(_, value)| *value)
}

fn month_index(token: &str) -> Option<u32> {
    // "may" is also an ordinary English word, but a bare "may" only reaches
    // here when a number follows it, which resolves the ambiguity.
    MONTH_NAMES
        .iter()
        .find(|(name, _)| *name == token)
        .map(|(_, value)| *value)
}

fn singular(token: &str) -> &str {
    token.strip_suffix('s').unwrap_or(token)
}

// --- Calendar arithmetic, duplicated deliberately ---
//
// These mirror the helpers in `tasks.rs` rather than sharing them, because the
// parser works in whole civil days and needs no Chrono types at its boundary.

fn valid_date(year: i32, month: u32, day: u32) -> Option<CivilDate> {
    if !(1..=12).contains(&month) || day == 0 || day > days_in_month(year, month) {
        return None;
    }
    Some(CivilDate { year, month, day })
}

fn days_in_month(year: i32, month: u32) -> u32 {
    match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if is_leap(year) => 29,
        2 => 28,
        _ => 0,
    }
}

fn is_leap(year: i32) -> bool {
    (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
}

fn shift_days(from: CivilDate, offset: i64) -> Option<CivilDate> {
    let days = to_days(from)?.checked_add(offset)?;
    from_days(days)
}

/// Days since 1970-01-01, by Howard Hinnant's civil-date algorithm.
fn to_days(date: CivilDate) -> Option<i64> {
    if !(1..=12).contains(&date.month)
        || date.day == 0
        || date.day > days_in_month(date.year, date.month)
    {
        return None;
    }
    let year = date.year as i64 - i64::from(date.month <= 2);
    let era = year.div_euclid(400);
    let year_of_era = year - era * 400;
    let month = date.month as i64;
    let day_of_year =
        (153 * (month + if month > 2 { -3 } else { 9 }) + 2) / 5 + date.day as i64 - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    Some(era * 146_097 + day_of_era - 719_468)
}

fn from_days(days: i64) -> Option<CivilDate> {
    let shifted = days + 719_468;
    let era = shifted.div_euclid(146_097);
    let day_of_era = shifted - era * 146_097;
    let year_of_era =
        (day_of_era - day_of_era / 1460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let year = year_of_era + era * 400;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let shifted_month = (5 * day_of_year + 2) / 153;
    let day = (day_of_year - (153 * shifted_month + 2) / 5 + 1) as u32;
    let month = (shifted_month + if shifted_month < 10 { 3 } else { -9 }) as u32;
    Some(CivilDate {
        year: i32::try_from(year + i64::from(month <= 2)).ok()?,
        month,
        day,
    })
}

fn add_months_civil(date: CivilDate, months: i32) -> Option<CivilDate> {
    let zero_based = date.year as i64 * 12 + (date.month as i64 - 1) + months as i64;
    let year = i32::try_from(zero_based.div_euclid(12)).ok()?;
    let month = zero_based.rem_euclid(12) as u32 + 1;
    let day = date.day.min(days_in_month(year, month));
    Some(CivilDate { year, month, day })
}

/// Split the input into words, recording UTF-16 bounds and quoted regions.
fn tokenize(text: &str) -> Vec<Word> {
    // Character, its UTF-16 start offset, and its width in code units.
    let mut units: Vec<(char, u32)> = Vec::with_capacity(text.len());
    let mut offset = 0_u32;
    for character in text.chars() {
        units.push((character, offset));
        offset += character.len_utf16() as u32;
    }
    let end_offset = offset;

    // Quoted regions, by index into `units`. An unterminated quote protects
    // the rest of the line, which is the forgiving reading while typing.
    let mut quoted = vec![false; units.len()];
    let mut open: Option<usize> = None;
    for (index, (character, _)) in units.iter().enumerate() {
        if *character != '"' {
            continue;
        }
        match open {
            Some(start) => {
                for flag in quoted.iter_mut().take(index + 1).skip(start) {
                    *flag = true;
                }
                open = None;
            }
            None => open = Some(index),
        }
    }
    if let Some(start) = open {
        for flag in quoted.iter_mut().skip(start) {
            *flag = true;
        }
    }

    let mut words = Vec::new();
    let mut cursor = 0;
    while cursor < units.len() {
        if is_dart_regexp_whitespace(units[cursor].0) {
            cursor += 1;
            continue;
        }
        let start = cursor;
        while cursor < units.len() && !is_dart_regexp_whitespace(units[cursor].0) {
            cursor += 1;
        }
        let raw: String = units[start..cursor].iter().map(|(c, _)| *c).collect();
        let protected = quoted[start..cursor].iter().any(|flag| *flag);

        // Trim surrounding punctuation, tracking how much came off each end so
        // the highlight covers the word and not its comma. A run that begins
        // with `!` keeps it: that is the priority form.
        let leading = raw.chars().take_while(|c| LEADING_TRIM.contains(c)).count();
        let after_leading = &raw[raw
            .char_indices()
            .nth(leading)
            .map(|(index, _)| index)
            .unwrap_or(raw.len())..];
        let had_bang = after_leading.ends_with('!');
        let trailing = if after_leading.starts_with('!') {
            0
        } else {
            after_leading
                .chars()
                .rev()
                .take_while(|c| TRAILING_TRIM.contains(c))
                .count()
        };
        let core_len = after_leading.chars().count().saturating_sub(trailing);
        let core: String = after_leading.chars().take(core_len).collect();

        let start_offset = units
            .get(start + leading)
            .map(|(_, offset)| *offset)
            .unwrap_or(end_offset);
        let end_offset_word = units
            .get(start + leading + core_len)
            .map(|(_, offset)| *offset)
            .unwrap_or_else(|| {
                units
                    .get(cursor - 1)
                    .map(|(character, offset)| offset + character.len_utf16() as u32)
                    .unwrap_or(end_offset)
            });

        words.push(Word {
            raw,
            lower: core.to_lowercase(),
            start: start_offset,
            end: end_offset_word,
            protected,
            had_bang,
            consumed: false,
        });
    }
    words
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Monday, 10 August 2026, 10:00.
    fn context() -> QuickAddContext {
        QuickAddContext {
            today: CivilDate {
                year: 2026,
                month: 8,
                day: 10,
            },
            now: CivilTime {
                hour: 10,
                minute: 0,
            },
            today_weekday: 0,
            week_start_monday: true,
            month_first: false,
        }
    }

    fn parse(text: &str) -> QuickAddParse {
        parse_quick_add(text.to_owned(), context())
    }

    fn date(year: i32, month: u32, day: u32) -> CivilDate {
        CivilDate { year, month, day }
    }

    #[test]
    fn the_headline_example_parses_completely() {
        let result = parse("pay rent tomorrow 5pm p1 #home every month");
        assert_eq!(result.title, "pay rent");
        assert_eq!(result.due, Some(date(2026, 8, 11)));
        assert_eq!(
            result.due_time,
            Some(CivilTime {
                hour: 17,
                minute: 0
            })
        );
        assert_eq!(result.priority, PRIORITY_URGENT);
        assert_eq!(result.project.as_deref(), Some("home"));
        assert_eq!(
            result.recurrence.as_deref(),
            Some("FREQ=MONTHLY;INTERVAL=1")
        );
    }

    #[test]
    fn a_plain_line_stays_a_plain_task() {
        let result = parse("buy milk");
        assert_eq!(result.title, "buy milk");
        assert_eq!(result.due, None);
        assert_eq!(result.due_time, None);
        assert_eq!(result.priority, PRIORITY_NONE);
        assert!(result.spans.is_empty());
    }

    #[test]
    fn quoting_overrules_the_parser() {
        let result = parse("review \"monday\" draft");
        assert_eq!(result.title, "review monday draft");
        assert_eq!(result.due, None);
    }

    #[test]
    fn labels_accumulate_but_a_project_does_not() {
        let result = parse("email the board @email @urgent #work #ignored");
        assert_eq!(result.title, "email the board #ignored");
        assert_eq!(result.labels, vec!["email", "urgent"]);
        assert_eq!(result.project.as_deref(), Some("work"));
    }

    #[test]
    fn an_underscore_becomes_a_space_in_a_name() {
        let result = parse("ship it #Deep_Work");
        assert_eq!(result.project.as_deref(), Some("Deep Work"));
        assert_eq!(result.title, "ship it");
    }

    #[test]
    fn relative_days_resolve_against_the_supplied_today() {
        assert_eq!(parse("x today").due, Some(date(2026, 8, 10)));
        assert_eq!(parse("x tomorrow").due, Some(date(2026, 8, 11)));
        assert_eq!(parse("x in 3 days").due, Some(date(2026, 8, 13)));
        assert_eq!(parse("x in two weeks").due, Some(date(2026, 8, 24)));
        assert_eq!(parse("x next week").due, Some(date(2026, 8, 17)));
        assert_eq!(parse("x next month").due, Some(date(2026, 9, 10)));
    }

    #[test]
    fn tonight_sets_a_date_and_an_evening_time_together() {
        let result = parse("call mum tonight");
        assert_eq!(result.title, "call mum");
        assert_eq!(result.due, Some(date(2026, 8, 10)));
        assert_eq!(
            result.due_time,
            Some(CivilTime {
                hour: 20,
                minute: 0
            })
        );
    }

    #[test]
    fn a_bare_weekday_includes_today_and_next_skips_the_week() {
        // Today is Monday.
        assert_eq!(parse("x monday").due, Some(date(2026, 8, 10)));
        assert_eq!(parse("x next monday").due, Some(date(2026, 8, 17)));
        assert_eq!(parse("x friday").due, Some(date(2026, 8, 14)));
        // Friday is still this week, so "next friday" is a week further out.
        assert_eq!(parse("x next friday").due, Some(date(2026, 8, 21)));
    }

    #[test]
    fn absolute_dates_parse_in_both_orders_and_roll_to_next_year() {
        assert_eq!(parse("x aug 12").due, Some(date(2026, 8, 12)));
        assert_eq!(parse("x 12 august").due, Some(date(2026, 8, 12)));
        assert_eq!(parse("x august 12 2027").due, Some(date(2027, 8, 12)));
        // January has already gone by on 10 August.
        assert_eq!(parse("x jan 5").due, Some(date(2027, 1, 5)));
    }

    #[test]
    fn numeric_dates_follow_the_locale_unless_a_component_settles_it() {
        // The context is day-first.
        assert_eq!(parse("x 3/4").due, Some(date(2027, 4, 3)));
        // 25 cannot be a month, so this is unambiguous in either locale.
        assert_eq!(parse("x 25/12").due, Some(date(2026, 12, 25)));
        let us = QuickAddContext {
            month_first: true,
            ..context()
        };
        assert_eq!(
            parse_quick_add("x 3/4".to_owned(), us).due,
            Some(date(2027, 3, 4)),
        );
    }

    #[test]
    fn times_parse_with_and_without_a_meridiem() {
        assert_eq!(
            parse("x today 5pm").due_time,
            Some(CivilTime {
                hour: 17,
                minute: 0
            })
        );
        assert_eq!(
            parse("x today 5:30pm").due_time,
            Some(CivilTime {
                hour: 17,
                minute: 30
            })
        );
        assert_eq!(
            parse("x today 17:00").due_time,
            Some(CivilTime {
                hour: 17,
                minute: 0
            })
        );
        assert_eq!(
            parse("x today noon").due_time,
            Some(CivilTime {
                hour: 12,
                minute: 0
            })
        );
        assert_eq!(
            parse("x today 12am").due_time,
            Some(CivilTime { hour: 0, minute: 0 })
        );
    }

    #[test]
    fn at_five_means_the_afternoon_and_at_nine_the_morning() {
        assert_eq!(
            parse("standup today at 9").due_time,
            Some(CivilTime { hour: 9, minute: 0 })
        );
        assert_eq!(
            parse("dinner today at 5").due_time,
            Some(CivilTime {
                hour: 17,
                minute: 0
            })
        );
    }

    #[test]
    fn a_bare_number_is_not_a_time() {
        let result = parse("buy 6 eggs");
        assert_eq!(result.title, "buy 6 eggs");
        assert_eq!(result.due_time, None);
    }

    #[test]
    fn a_bare_time_lands_on_the_next_day_that_still_has_it() {
        // It is 10:00, so five in the afternoon is still to come today.
        let today = parse("call the bank 5pm");
        assert_eq!(today.title, "call the bank");
        assert_eq!(today.due, Some(date(2026, 8, 10)));
        assert_eq!(
            today.due_time,
            Some(CivilTime {
                hour: 17,
                minute: 0
            })
        );
        // Eight in the morning has already gone, so it means tomorrow.
        let tomorrow = parse("call the bank 8am");
        assert_eq!(tomorrow.due, Some(date(2026, 8, 11)));
    }

    #[test]
    fn an_iso_date_is_read_in_its_own_order() {
        assert_eq!(parse("x 2027-03-09").due, Some(date(2027, 3, 9)));
    }

    #[test]
    fn priorities_accept_both_spellings() {
        assert_eq!(parse("x p1").priority, PRIORITY_URGENT);
        assert_eq!(parse("x !2").priority, PRIORITY_HIGH);
        assert_eq!(parse("x p3").priority, PRIORITY_LOW);
        assert_eq!(parse("x p4").priority, PRIORITY_NONE);
        assert_eq!(parse("x p1").title, "x");
    }

    #[test]
    fn recurrence_covers_the_shapes_people_type() {
        assert_eq!(
            parse("x every day").recurrence.as_deref(),
            Some("FREQ=DAILY;INTERVAL=1")
        );
        assert_eq!(
            parse("x daily").recurrence.as_deref(),
            Some("FREQ=DAILY;INTERVAL=1")
        );
        assert_eq!(
            parse("x every 3 days").recurrence.as_deref(),
            Some("FREQ=DAILY;INTERVAL=3")
        );
        assert_eq!(
            parse("x every other week").recurrence.as_deref(),
            Some("FREQ=WEEKLY;INTERVAL=2")
        );
        assert_eq!(
            parse("x every weekday").recurrence.as_deref(),
            Some("FREQ=WEEKLY;INTERVAL=1;BYDAY=MO,TU,WE,TH,FR")
        );
        assert_eq!(
            parse("x every mon and thu").recurrence.as_deref(),
            Some("FREQ=WEEKLY;INTERVAL=1;BYDAY=MO,TH")
        );
    }

    #[test]
    fn a_trailing_bang_asks_for_completion_based_repetition() {
        let result = parse("water plants every! 3 days");
        assert_eq!(
            result.recurrence.as_deref(),
            Some("FREQ=DAILY;INTERVAL=3;MODE=COMPLETION")
        );
        assert_eq!(result.title, "water plants");
    }

    #[test]
    fn a_repeating_task_starts_at_its_first_occurrence() {
        // Today is Monday, so the first Thursday is the 13th.
        assert_eq!(parse("x every thursday").due, Some(date(2026, 8, 13)));
        // A daily rule starts today.
        assert_eq!(parse("x every 3 days").due, Some(date(2026, 8, 10)));
        // An explicit date still wins over the rule's first occurrence.
        assert_eq!(
            parse("x every thursday aug 20").due,
            Some(date(2026, 8, 20))
        );
    }

    #[test]
    fn reminders_parse_in_their_common_spellings() {
        assert_eq!(
            parse("x tomorrow remind 30m before").reminder_lead_minutes,
            Some(30)
        );
        assert_eq!(
            parse("x tomorrow remind me 2 hours before").reminder_lead_minutes,
            Some(120)
        );
        assert_eq!(
            parse("x tomorrow remind me 1h").reminder_lead_minutes,
            Some(60)
        );
        assert_eq!(parse("x tomorrow remind 30m before").title, "x");
    }

    #[test]
    fn spans_are_utf16_offsets_that_survive_astral_characters() {
        let result = parse("\u{1f680} ship tomorrow");
        // The rocket is one char but two UTF-16 code units, so "tomorrow"
        // begins at 8, not 7.
        let span = result
            .spans
            .iter()
            .find(|span| span.kind == QuickAddTokenKind::Date)
            .expect("the date is highlighted");
        assert_eq!((span.start, span.end), (8, 16));
        assert_eq!(result.title, "\u{1f680} ship");
    }

    #[test]
    fn a_span_covers_the_token_and_not_its_punctuation() {
        let result = parse("call mum, tomorrow.");
        let span = result
            .spans
            .iter()
            .find(|span| span.kind == QuickAddTokenKind::Date)
            .expect("the date is highlighted");
        // "call mum, " is 10 units; "tomorrow" ends before the full stop.
        assert_eq!((span.start, span.end), (10, 18));
        assert_eq!(result.title, "call mum");
    }

    #[test]
    fn only_the_first_date_is_taken() {
        let result = parse("move the monday meeting to tuesday");
        assert_eq!(result.due, Some(date(2026, 8, 10)));
        assert_eq!(result.title, "move the meeting to tuesday");
    }

    #[test]
    fn an_empty_or_token_only_line_still_produces_a_result() {
        let empty = parse("   ");
        assert_eq!(empty.title, "");
        assert_eq!(empty.due, None);

        let tokens = parse("tomorrow p1");
        assert_eq!(tokens.title, "");
        assert_eq!(tokens.due, Some(date(2026, 8, 11)));
        assert_eq!(tokens.priority, PRIORITY_URGENT);
    }

    #[test]
    fn an_impossible_date_is_left_in_the_title() {
        let result = parse("x feb 30");
        assert_eq!(result.due, None);
        assert_eq!(result.title, "x feb 30");
    }

    #[test]
    fn a_very_long_line_becomes_a_title_verbatim() {
        let long = format!("{} tomorrow", "word ".repeat(500));
        let result = parse_quick_add(long.clone(), context());
        assert_eq!(result.due, None);
        assert!(result.title.ends_with("tomorrow"));
    }

    #[test]
    fn civil_day_arithmetic_crosses_months_and_leap_years() {
        assert_eq!(shift_days(date(2026, 12, 31), 1), Some(date(2027, 1, 1)));
        assert_eq!(shift_days(date(2028, 2, 28), 1), Some(date(2028, 2, 29)));
        assert_eq!(shift_days(date(2026, 2, 28), 1), Some(date(2026, 3, 1)));
        assert_eq!(shift_days(date(2026, 1, 1), -1), Some(date(2025, 12, 31)));
    }
}
