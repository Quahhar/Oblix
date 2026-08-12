//! Pulling the actionable things out of scanned text.
//!
//! A scan is rarely wanted only as prose. A receipt has a total, a letter has
//! a deadline, a poster has a date and a place, a card has an email. Finding
//! those turns a wall of recognized text into something the app can offer to
//! *do* — and, because every entity also knows where it sat on the page, into
//! something it can offer to hide.
//!
//! No model is involved: this is patterns and arithmetic, which is why it runs
//! offline in a millisecond and behaves the same on every device.
//!
//! Two deliberate refusals. Dates are not resolved against "today" and times
//! are not converted to UTC — the core has no business guessing the device's
//! timezone, so civil components come back and Dart converts them, the same
//! division of labour the note grouping uses. And an ambiguous numeric date is
//! reported but left unnormalized unless the caller says which of day and
//! month comes first, because `01/02` is two different days in two countries
//! and quietly picking one is worse than picking neither.

use std::sync::OnceLock;

use flutter_rust_bridge::frb;
use regex::Regex;

use crate::api::textlayer::TextLayer;
use crate::dart_string::dart_trim;

/// Longest text we will scan for entities. A very long note is not worth
/// spending unbounded time on, and nothing useful lives past this.
const MAX_SCAN_UNITS: usize = 400_000;

/// Digit counts a plausible telephone number falls between, ignoring
/// punctuation and any country prefix.
const MIN_PHONE_DIGITS: usize = 7;
const MAX_PHONE_DIGITS: usize = 15;

/// What was found.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EntityKind {
    Date,
    Time,
    Money,
    Percent,
    Phone,
    Email,
    Url,
    /// A payment card number that passes a Luhn check.
    Card,
    Iban,
    PostCode,
}

impl EntityKind {
    /// Lower is preferred when two patterns claim the same characters, so the
    /// more specific reading wins: the digits inside a URL are part of the
    /// URL, and a card number is a card before it is a phone number.
    fn priority(self) -> u8 {
        match self {
            EntityKind::Url => 0,
            EntityKind::Email => 1,
            EntityKind::Iban => 2,
            EntityKind::Card => 3,
            EntityKind::Money => 4,
            EntityKind::Date => 5,
            EntityKind::Time => 6,
            EntityKind::Percent => 7,
            EntityKind::PostCode => 8,
            EntityKind::Phone => 9,
        }
    }

    /// Whether hiding this would normally be the point of redacting a page.
    fn sensitive(self) -> bool {
        matches!(
            self,
            EntityKind::Card | EntityKind::Iban | EntityKind::Phone | EntityKind::Email
        )
    }
}

/// One thing found in the text.
#[derive(Clone, Debug, PartialEq)]
pub struct Entity {
    pub kind: EntityKind,
    /// Exactly the characters that matched.
    pub text: String,
    /// UTF-16 offsets, so they index the same string Dart holds.
    pub start: i32,
    pub end: i32,
    /// A canonical form where one exists and is unambiguous: `YYYY-MM-DD` for
    /// a date, `HH:MM` for a time, digits for a phone number, the amount in
    /// minor units for money. Empty when the match cannot be normalized
    /// without guessing.
    pub normalized: String,
    /// ISO currency code for [EntityKind::Money], else empty.
    pub currency: String,
}

/// What the caller knows that the text does not.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct EntityOptions {
    /// Whether `01/02/2026` means the first of February. Set from the device
    /// locale; when the day exceeds twelve the text settles it either way.
    pub day_first: bool,
}

impl Default for EntityOptions {
    fn default() -> Self {
        Self { day_first: true }
    }
}

/// A rectangle on a page to paint over.
#[derive(Clone, Debug, PartialEq)]
pub struct RedactionSpan {
    pub kind: EntityKind,
    pub page: i32,
    pub left: f32,
    pub top: f32,
    pub right: f32,
    pub bottom: f32,
    /// What is being hidden, so the UI can say so without showing it.
    pub label: String,
}

/// Something the app could offer to do with the scan.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ActionKind {
    Task,
    Event,
    Contact,
}

/// A proposed action, in civil components. Dart resolves these against the
/// device timezone; the core never does.
#[derive(Clone, Debug, PartialEq)]
pub struct SuggestedAction {
    pub kind: ActionKind,
    pub title: String,
    pub detail: String,
    pub year: Option<i32>,
    pub month: Option<i32>,
    pub day: Option<i32>,
    pub hour: Option<i32>,
    pub minute: Option<i32>,
    /// Money in minor units — pence, cents — so nothing is lost to rounding.
    pub amount_minor: Option<i64>,
    pub currency: String,
}

// --- Patterns -------------------------------------------------------------

struct Patterns {
    url: Regex,
    email: Regex,
    iban: Regex,
    digits_run: Regex,
    money_prefix: Regex,
    money_suffix: Regex,
    percent: Regex,
    iso_date: Regex,
    numeric_date: Regex,
    day_month_name: Regex,
    month_name_day: Regex,
    time: Regex,
    phone: Regex,
    postcode: Regex,
}

fn patterns() -> &'static Patterns {
    static PATTERNS: OnceLock<Patterns> = OnceLock::new();
    PATTERNS.get_or_init(|| {
        const MONTHS: &str = "jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|\
                              jul(?:y)?|aug(?:ust)?|sep(?:t)?(?:ember)?|oct(?:ober)?|\
                              nov(?:ember)?|dec(?:ember)?";
        Patterns {
            url: Regex::new(r#"(?i)\b(?:https?://|www\.)[^\s<>"'\)\]]+"#).expect("url pattern"),
            email: Regex::new(r"(?i)\b[\w.+-]+@[\w-]+(?:\.[\w-]+)+\b").expect("email pattern"),
            iban: Regex::new(r"\b[A-Z]{2}\d{2}[A-Z0-9]{10,30}\b").expect("iban pattern"),
            // Candidate card numbers; a Luhn check decides which really are.
            digits_run: Regex::new(r"\b\d(?:[ -]?\d){12,18}\b").expect("digits pattern"),
            money_prefix: Regex::new(r"(?i)[$£€¥₹]\s?\d[\d,]*(?:\.\d{1,2})?")
                .expect("money prefix pattern"),
            money_suffix: Regex::new(
                r"(?i)\b\d[\d,]*(?:\.\d{1,2})?\s?(USD|GBP|EUR|JPY|INR|CAD|AUD|CHF|NGN)\b",
            )
            .expect("money suffix pattern"),
            percent: Regex::new(r"\b\d+(?:\.\d+)?\s?%").expect("percent pattern"),
            iso_date: Regex::new(r"\b(\d{4})-(\d{2})-(\d{2})\b").expect("iso date pattern"),
            numeric_date: Regex::new(r"\b(\d{1,2})[/.](\d{1,2})[/.](\d{2,4})\b")
                .expect("numeric date pattern"),
            day_month_name: Regex::new(&format!(
                r"(?i)\b(\d{{1,2}})(?:st|nd|rd|th)?\s+(?:of\s+)?({MONTHS})\b\.?(?:,?\s+(\d{{4}}))?"
            ))
            .expect("day month pattern"),
            month_name_day: Regex::new(&format!(
                r"(?i)\b({MONTHS})\b\.?\s+(\d{{1,2}})(?:st|nd|rd|th)?(?:,?\s+(\d{{4}}))?"
            ))
            .expect("month day pattern"),
            time: Regex::new(r"(?i)\b(\d{1,2}):(\d{2})(?::\d{2})?\s?([ap])\.?m\.?|\b(\d{1,2}):(\d{2})(?::\d{2})?\b")
                .expect("time pattern"),
            phone: Regex::new(r"\+?\d[\d\s().-]{5,}\d").expect("phone pattern"),
            postcode: Regex::new(r"(?i)\b[A-Z]{1,2}\d[A-Z\d]?\s?\d[A-Z]{2}\b")
                .expect("postcode pattern"),
        }
    })
}

// --- Extraction -----------------------------------------------------------

/// Find every entity in the text, without overlaps.
#[frb(sync)]
pub fn extract_entities(text: String, options: EntityOptions) -> Vec<Entity> {
    if text.encode_utf16().count() > MAX_SCAN_UNITS {
        return Vec::new();
    }
    let patterns = patterns();
    let mut found: Vec<(usize, usize, EntityKind, String, String)> = Vec::new();

    for capture in patterns.url.find_iter(&text) {
        found.push((
            capture.start(),
            capture.end(),
            EntityKind::Url,
            capture.as_str().to_owned(),
            String::new(),
        ));
    }
    for capture in patterns.email.find_iter(&text) {
        found.push((
            capture.start(),
            capture.end(),
            EntityKind::Email,
            capture.as_str().to_lowercase(),
            String::new(),
        ));
    }
    for capture in patterns.iban.find_iter(&text) {
        found.push((
            capture.start(),
            capture.end(),
            EntityKind::Iban,
            capture.as_str().replace(' ', ""),
            String::new(),
        ));
    }
    for capture in patterns.digits_run.find_iter(&text) {
        let digits: String = capture
            .as_str()
            .chars()
            .filter(char::is_ascii_digit)
            .collect();
        // Only a run that passes Luhn is called a card. Without that check
        // every long reference number on an invoice would be redacted.
        if (13..=19).contains(&digits.len()) && luhn(&digits) {
            found.push((
                capture.start(),
                capture.end(),
                EntityKind::Card,
                digits,
                String::new(),
            ));
        }
    }
    for capture in patterns.money_prefix.find_iter(&text) {
        let (minor, currency) = parse_money(capture.as_str());
        found.push((
            capture.start(),
            capture.end(),
            EntityKind::Money,
            minor,
            currency,
        ));
    }
    for capture in patterns.money_suffix.find_iter(&text) {
        let (minor, currency) = parse_money(capture.as_str());
        found.push((
            capture.start(),
            capture.end(),
            EntityKind::Money,
            minor,
            currency,
        ));
    }
    for capture in patterns.percent.find_iter(&text) {
        found.push((
            capture.start(),
            capture.end(),
            EntityKind::Percent,
            capture.as_str().replace(' ', ""),
            String::new(),
        ));
    }
    collect_dates(&text, options, &mut found);
    for capture in patterns.time.captures_iter(&text) {
        let whole = capture.get(0).expect("group zero always matches");
        found.push((
            whole.start(),
            whole.end(),
            EntityKind::Time,
            normalize_time(&capture),
            String::new(),
        ));
    }
    for capture in patterns.postcode.find_iter(&text) {
        found.push((
            capture.start(),
            capture.end(),
            EntityKind::PostCode,
            capture.as_str().to_uppercase(),
            String::new(),
        ));
    }
    for capture in patterns.phone.find_iter(&text) {
        let digits: String = capture
            .as_str()
            .chars()
            .filter(char::is_ascii_digit)
            .collect();
        if (MIN_PHONE_DIGITS..=MAX_PHONE_DIGITS).contains(&digits.len()) {
            let normalized = if capture.as_str().starts_with('+') {
                format!("+{digits}")
            } else {
                digits
            };
            found.push((
                capture.start(),
                capture.end(),
                EntityKind::Phone,
                normalized,
                String::new(),
            ));
        }
    }

    resolve(&text, found)
}

/// Keep the highest-priority reading of each stretch of characters, then hand
/// them back in the order they appear.
fn resolve(text: &str, mut found: Vec<(usize, usize, EntityKind, String, String)>) -> Vec<Entity> {
    // Best first: by priority, then by length, so a full date beats the year
    // inside it.
    found.sort_by(|a, b| {
        a.2.priority()
            .cmp(&b.2.priority())
            .then_with(|| (b.1 - b.0).cmp(&(a.1 - a.0)))
            .then_with(|| a.0.cmp(&b.0))
    });
    let mut taken: Vec<(usize, usize)> = Vec::new();
    let mut entities: Vec<Entity> = Vec::new();
    for (start, end, kind, normalized, currency) in found {
        if taken.iter().any(|(from, to)| start < *to && end > *from) {
            continue;
        }
        taken.push((start, end));
        entities.push(Entity {
            kind,
            text: text[start..end].to_owned(),
            start: utf16_offset(text, start),
            end: utf16_offset(text, end),
            normalized,
            currency,
        });
    }
    entities.sort_by_key(|entity| entity.start);
    entities
}

fn utf16_offset(text: &str, byte: usize) -> i32 {
    i32::try_from(text[..byte].encode_utf16().count()).unwrap_or(i32::MAX)
}

// --- Dates and times ------------------------------------------------------

fn collect_dates(
    text: &str,
    options: EntityOptions,
    found: &mut Vec<(usize, usize, EntityKind, String, String)>,
) {
    let patterns = patterns();
    for capture in patterns.iso_date.captures_iter(text) {
        let whole = capture.get(0).expect("group zero always matches");
        let year = group_number(&capture, 1);
        let month = group_number(&capture, 2);
        let day = group_number(&capture, 3);
        found.push((
            whole.start(),
            whole.end(),
            EntityKind::Date,
            iso_or_empty(year, month, day),
            String::new(),
        ));
    }
    for capture in patterns.numeric_date.captures_iter(text) {
        let whole = capture.get(0).expect("group zero always matches");
        let first = group_number(&capture, 1);
        let second = group_number(&capture, 2);
        let year = expand_year(group_number(&capture, 3));
        // The text settles the order when one number cannot be a month;
        // otherwise the caller's locale does.
        let (day, month) = if first > 12 {
            (first, second)
        } else if second > 12 {
            (second, first)
        } else if options.day_first {
            (first, second)
        } else {
            (second, first)
        };
        found.push((
            whole.start(),
            whole.end(),
            EntityKind::Date,
            iso_or_empty(year, month, day),
            String::new(),
        ));
    }
    for capture in patterns.day_month_name.captures_iter(text) {
        let whole = capture.get(0).expect("group zero always matches");
        let day = group_number(&capture, 1);
        let month = month_number(capture.get(2).map_or("", |m| m.as_str()));
        let year = group_number(&capture, 3);
        found.push((
            whole.start(),
            whole.end(),
            EntityKind::Date,
            iso_or_empty(year, month, day),
            String::new(),
        ));
    }
    for capture in patterns.month_name_day.captures_iter(text) {
        let whole = capture.get(0).expect("group zero always matches");
        let month = month_number(capture.get(1).map_or("", |m| m.as_str()));
        let day = group_number(&capture, 2);
        let year = group_number(&capture, 3);
        found.push((
            whole.start(),
            whole.end(),
            EntityKind::Date,
            iso_or_empty(year, month, day),
            String::new(),
        ));
    }
}

fn group_number(capture: &regex::Captures<'_>, index: usize) -> i32 {
    capture
        .get(index)
        .and_then(|group| group.as_str().parse::<i32>().ok())
        .unwrap_or(0)
}

/// A two-digit year is this century; anything else is taken as written.
fn expand_year(year: i32) -> i32 {
    if (0..=99).contains(&year) {
        2000 + year
    } else {
        year
    }
}

/// `YYYY-MM-DD`, or empty when the date is not fully known or not a real day.
/// A year of zero means the text never said which year, and inventing one
/// would put a reminder on the wrong day.
fn iso_or_empty(year: i32, month: i32, day: i32) -> String {
    if year <= 0 || !(1..=12).contains(&month) || day < 1 || day > days_in_month(year, month) {
        return String::new();
    }
    format!("{year:04}-{month:02}-{day:02}")
}

fn days_in_month(year: i32, month: i32) -> i32 {
    match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) => 29,
        2 => 28,
        _ => 0,
    }
}

fn month_number(name: &str) -> i32 {
    const PREFIXES: [&str; 12] = [
        "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec",
    ];
    let lower = name.to_lowercase();
    PREFIXES
        .iter()
        .position(|prefix| lower.starts_with(prefix))
        .map_or(0, |index| index as i32 + 1)
}

/// `HH:MM` on a 24-hour clock, or empty when the hands make no sense.
fn normalize_time(capture: &regex::Captures<'_>) -> String {
    let twelve_hour = capture.get(1).is_some();
    let (hour, minute) = if twelve_hour {
        (group_number(capture, 1), group_number(capture, 2))
    } else {
        (group_number(capture, 4), group_number(capture, 5))
    };
    if !(0..=23).contains(&hour) || !(0..=59).contains(&minute) {
        return String::new();
    }
    let hour = if twelve_hour {
        let afternoon = capture
            .get(3)
            .map(|meridiem| meridiem.as_str().eq_ignore_ascii_case("p"))
            .unwrap_or(false);
        if !(1..=12).contains(&hour) {
            return String::new();
        }
        match (hour, afternoon) {
            (12, false) => 0,
            (12, true) => 12,
            (hour, true) => hour + 12,
            (hour, false) => hour,
        }
    } else {
        hour
    };
    format!("{hour:02}:{minute:02}")
}

fn luhn(digits: &str) -> bool {
    let mut sum = 0u32;
    for (index, digit) in digits.bytes().rev().enumerate() {
        let mut value = u32::from(digit - b'0');
        if index % 2 == 1 {
            value *= 2;
            if value > 9 {
                value -= 9;
            }
        }
        sum += value;
    }
    sum.is_multiple_of(10)
}

/// Minor units as a decimal string, plus the currency code.
fn parse_money(text: &str) -> (String, String) {
    let currency = if let Some(symbol) = text.chars().find(|c| "$£€¥₹".contains(*c)) {
        match symbol {
            '$' => "USD",
            '£' => "GBP",
            '€' => "EUR",
            '¥' => "JPY",
            _ => "INR",
        }
        .to_owned()
    } else {
        text.chars()
            .filter(|c| c.is_ascii_alphabetic())
            .collect::<String>()
            .to_uppercase()
    };
    let cleaned: String = text
        .chars()
        .filter(|c| c.is_ascii_digit() || *c == '.')
        .collect();
    let (whole, fraction) = match cleaned.split_once('.') {
        Some((whole, fraction)) => (whole, fraction),
        None => (cleaned.as_str(), ""),
    };
    let major: i64 = whole.parse().unwrap_or(0);
    let minor: i64 = match fraction.len() {
        0 => 0,
        1 => fraction.parse::<i64>().unwrap_or(0) * 10,
        _ => fraction[..2].parse().unwrap_or(0),
    };
    (format!("{}", major * 100 + minor), currency)
}

// --- Redaction ------------------------------------------------------------

/// Boxes over everything worth hiding on a scanned page.
///
/// `kinds` empty means every sensitive kind — cards, bank numbers, telephone
/// numbers and email addresses. Boxes are narrowed to the matched characters
/// the same way a search hit is, so redacting a card number on a line does not
/// black out the whole line.
#[frb(sync)]
pub fn find_redactions(
    layer: TextLayer,
    kinds: Vec<EntityKind>,
    options: EntityOptions,
) -> Vec<RedactionSpan> {
    let mut spans = Vec::new();
    for (page_index, page) in layer.pages.iter().enumerate() {
        for line in &page.lines {
            let units = line.text.encode_utf16().count().max(1) as f32;
            let width = line.right - line.left;
            for entity in extract_entities(line.text.clone(), options) {
                let wanted = if kinds.is_empty() {
                    entity.kind.sensitive()
                } else {
                    kinds.contains(&entity.kind)
                };
                if !wanted {
                    continue;
                }
                let start = entity.start.max(0) as f32 / units;
                let end = (entity.end.max(0) as f32 / units).min(1.0);
                spans.push(RedactionSpan {
                    kind: entity.kind,
                    page: page_index as i32,
                    left: line.left + width * start,
                    top: line.top,
                    right: line.left + width * end,
                    bottom: line.bottom,
                    label: label_for(entity.kind).to_owned(),
                });
            }
        }
    }
    spans
}

fn label_for(kind: EntityKind) -> &'static str {
    match kind {
        EntityKind::Card => "Card number",
        EntityKind::Iban => "Bank account",
        EntityKind::Phone => "Phone number",
        EntityKind::Email => "Email address",
        EntityKind::PostCode => "Postcode",
        EntityKind::Date => "Date",
        EntityKind::Time => "Time",
        EntityKind::Money => "Amount",
        EntityKind::Percent => "Percentage",
        EntityKind::Url => "Link",
    }
}

// --- Actions --------------------------------------------------------------

/// What the app could offer to do with this scan.
///
/// Kept conservative on purpose: a page full of numbers should not produce a
/// page full of suggestions. A total is only proposed when a line says it is
/// one, and a date only when the text gave a year to hang it on.
#[frb(sync)]
pub fn suggest_actions(text: String, options: EntityOptions) -> Vec<SuggestedAction> {
    const TOTAL_WORDS: [&str; 6] = ["total", "amount due", "balance", "due", "subtotal", "paid"];
    let mut actions: Vec<SuggestedAction> = Vec::new();

    for line in text.lines() {
        let lower = line.to_lowercase();
        if !TOTAL_WORDS.iter().any(|word| lower.contains(word)) {
            continue;
        }
        let entities = extract_entities(line.to_owned(), options);
        // The largest amount on a "total" line is the total; a discount or a
        // unit price sitting beside it is not.
        let Some(amount) = entities
            .iter()
            .filter(|entity| entity.kind == EntityKind::Money)
            .filter_map(|entity| {
                entity
                    .normalized
                    .parse::<i64>()
                    .ok()
                    .map(|minor| (minor, entity.currency.clone()))
            })
            .max_by_key(|(minor, _)| *minor)
        else {
            continue;
        };
        actions.push(SuggestedAction {
            kind: ActionKind::Task,
            title: dart_trim(line).to_owned(),
            detail: String::new(),
            year: None,
            month: None,
            day: None,
            hour: None,
            minute: None,
            amount_minor: Some(amount.0),
            currency: amount.1,
        });
        break;
    }

    let entities = extract_entities(text.clone(), options);
    if let Some(date) = entities
        .iter()
        .find(|entity| entity.kind == EntityKind::Date && !entity.normalized.is_empty())
    {
        let parts: Vec<i32> = date
            .normalized
            .split('-')
            .filter_map(|part| part.parse().ok())
            .collect();
        // A time is only attached when it came after the date, which is how
        // "14 March at 6pm" reads and "6pm on the 14th" does not.
        let time = entities
            .iter()
            .find(|entity| {
                entity.kind == EntityKind::Time
                    && !entity.normalized.is_empty()
                    && entity.start > date.start
            })
            .map(|entity| {
                let clock: Vec<i32> = entity
                    .normalized
                    .split(':')
                    .filter_map(|part| part.parse().ok())
                    .collect();
                (clock.first().copied(), clock.get(1).copied())
            });
        if parts.len() == 3 {
            actions.push(SuggestedAction {
                kind: ActionKind::Event,
                title: first_line(&text),
                detail: date.text.clone(),
                year: Some(parts[0]),
                month: Some(parts[1]),
                day: Some(parts[2]),
                hour: time.and_then(|(hour, _)| hour),
                minute: time.and_then(|(_, minute)| minute),
                amount_minor: None,
                currency: String::new(),
            });
        }
    }

    // A page with contact details and little else is a business card.
    let email = entities
        .iter()
        .find(|entity| entity.kind == EntityKind::Email);
    let phone = entities
        .iter()
        .find(|entity| entity.kind == EntityKind::Phone);
    if (email.is_some() || phone.is_some()) && text.lines().count() <= 10 {
        actions.push(SuggestedAction {
            kind: ActionKind::Contact,
            title: first_line(&text),
            detail: [
                email.map(|entity| entity.normalized.clone()),
                phone.map(|entity| entity.normalized.clone()),
            ]
            .into_iter()
            .flatten()
            .collect::<Vec<_>>()
            .join(" · "),
            year: None,
            month: None,
            day: None,
            hour: None,
            minute: None,
            amount_minor: None,
            currency: String::new(),
        });
    }

    actions
}

fn first_line(text: &str) -> String {
    text.lines()
        .map(dart_trim)
        .find(|line| !line.is_empty())
        .unwrap_or_default()
        .to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::textlayer::{TextLayerLine, TextLayerPage};

    fn extract(text: &str) -> Vec<Entity> {
        extract_entities(text.to_owned(), EntityOptions::default())
    }

    fn kinds(text: &str) -> Vec<EntityKind> {
        extract(text)
            .into_iter()
            .map(|entity| entity.kind)
            .collect()
    }

    fn normalized(text: &str, kind: EntityKind) -> String {
        extract(text)
            .into_iter()
            .find(|entity| entity.kind == kind)
            .map(|entity| entity.normalized)
            .unwrap_or_default()
    }

    #[test]
    fn finds_an_email_address_and_lowercases_it() {
        let found = extract("Write to Ada.Lovelace@Example.CO.UK today");
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].kind, EntityKind::Email);
        assert_eq!(found[0].normalized, "ada.lovelace@example.co.uk");
        assert_eq!(found[0].text, "Ada.Lovelace@Example.CO.UK");
    }

    #[test]
    fn finds_links_in_both_common_forms() {
        assert_eq!(
            kinds("see https://example.com/a?b=1 and www.example.org for more"),
            vec![EntityKind::Url, EntityKind::Url]
        );
    }

    #[test]
    fn a_trailing_bracket_is_not_part_of_the_link() {
        let found = extract("(see https://example.com/page)");
        assert_eq!(found[0].text, "https://example.com/page");
    }

    #[test]
    fn offsets_are_utf16_so_they_index_the_same_string_dart_holds() {
        // The emoji is one Rust char but two UTF-16 units, so a byte offset
        // would land Dart in the wrong place.
        let found = extract("🙂 mail me at a@b.com");
        assert_eq!(found.len(), 1);
        let text = "🙂 mail me at a@b.com";
        let units: Vec<u16> = text.encode_utf16().collect();
        let start = found[0].start as usize;
        let end = found[0].end as usize;
        assert_eq!(String::from_utf16(&units[start..end]).unwrap(), "a@b.com");
    }

    // --- Money ---

    #[test]
    fn reads_money_in_minor_units_with_its_currency() {
        let found = extract("Total £1,340.25 due");
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].kind, EntityKind::Money);
        assert_eq!(found[0].normalized, "134025");
        assert_eq!(found[0].currency, "GBP");
    }

    #[test]
    fn a_whole_amount_and_a_trailing_code_both_work() {
        assert_eq!(normalized("costs $40", EntityKind::Money), "4000");
        let suffix = extract("paid 99.50 EUR");
        assert_eq!(suffix[0].currency, "EUR");
        assert_eq!(suffix[0].normalized, "9950");
    }

    #[test]
    fn one_decimal_place_is_tenths_not_hundredths() {
        assert_eq!(normalized("$4.5", EntityKind::Money), "450");
    }

    // --- Dates ---

    #[test]
    fn reads_the_three_written_date_forms() {
        assert_eq!(normalized("due 2026-03-14", EntityKind::Date), "2026-03-14");
        assert_eq!(
            normalized("due 14th March 2026", EntityKind::Date),
            "2026-03-14"
        );
        assert_eq!(
            normalized("due March 14, 2026", EntityKind::Date),
            "2026-03-14"
        );
    }

    #[test]
    fn an_ambiguous_numeric_date_follows_the_callers_locale() {
        let day_first = extract_entities(
            "on 01/02/2026".to_owned(),
            EntityOptions { day_first: true },
        );
        assert_eq!(day_first[0].normalized, "2026-02-01");
        let month_first = extract_entities(
            "on 01/02/2026".to_owned(),
            EntityOptions { day_first: false },
        );
        assert_eq!(month_first[0].normalized, "2026-01-02");
    }

    #[test]
    fn a_number_over_twelve_settles_the_order_whatever_the_locale() {
        let month_first = extract_entities(
            "on 25/12/2026".to_owned(),
            EntityOptions { day_first: false },
        );
        assert_eq!(month_first[0].normalized, "2026-12-25");
    }

    #[test]
    fn a_date_with_no_year_is_reported_but_not_invented() {
        let found = extract("the meeting on 14 March");
        assert_eq!(found[0].kind, EntityKind::Date);
        assert_eq!(found[0].text, "14 March");
        // No year in the text, so no ISO form — guessing one would put a
        // reminder on the wrong day.
        assert_eq!(found[0].normalized, "");
    }

    #[test]
    fn an_impossible_day_is_not_normalized() {
        assert_eq!(normalized("2026-02-30", EntityKind::Date), "");
        assert_eq!(normalized("31/11/2026", EntityKind::Date), "");
        // But a leap day is real.
        assert_eq!(normalized("2028-02-29", EntityKind::Date), "2028-02-29");
    }

    #[test]
    fn a_two_digit_year_is_read_as_this_century() {
        assert_eq!(normalized("14/03/26", EntityKind::Date), "2026-03-14");
    }

    // --- Times ---

    #[test]
    fn reads_both_clocks_onto_a_24_hour_one() {
        assert_eq!(normalized("at 18:30", EntityKind::Time), "18:30");
        assert_eq!(normalized("at 6:30pm", EntityKind::Time), "18:30");
        assert_eq!(normalized("at 6:30 a.m.", EntityKind::Time), "06:30");
    }

    #[test]
    fn midnight_and_noon_do_not_wrap_the_wrong_way() {
        assert_eq!(normalized("12:05am", EntityKind::Time), "00:05");
        assert_eq!(normalized("12:05pm", EntityKind::Time), "12:05");
    }

    #[test]
    fn an_impossible_clock_is_not_normalized() {
        assert_eq!(normalized("at 25:99", EntityKind::Time), "");
    }

    // --- Cards, accounts, phones ---

    #[test]
    fn a_card_number_is_only_a_card_if_it_passes_a_luhn_check() {
        // A well-known test number, and the same digits with one changed.
        assert!(kinds("card 4111 1111 1111 1111").contains(&EntityKind::Card));
        assert!(!kinds("ref 4111 1111 1111 1112").contains(&EntityKind::Card));
    }

    #[test]
    fn a_long_invoice_reference_is_not_mistaken_for_a_card() {
        assert!(!kinds("Order 8827364519274 shipped").contains(&EntityKind::Card));
    }

    #[test]
    fn finds_a_phone_number_and_keeps_its_country_prefix() {
        let found = extract("ring +44 20 7946 0958 after six");
        let phone = found
            .iter()
            .find(|entity| entity.kind == EntityKind::Phone)
            .expect("a phone number");
        assert_eq!(phone.normalized, "+442079460958");
    }

    #[test]
    fn something_too_short_to_dial_is_not_a_phone_number() {
        assert!(!kinds("room 12 34").contains(&EntityKind::Phone));
    }

    #[test]
    fn finds_a_bank_account_number() {
        assert!(kinds("pay to GB33BUKB20201555555555").contains(&EntityKind::Iban));
    }

    // --- Overlaps ---

    #[test]
    fn the_digits_inside_a_link_stay_part_of_the_link() {
        let found = extract("open https://example.com/2026-03-14/report");
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].kind, EntityKind::Url);
    }

    #[test]
    fn a_card_number_beats_the_phone_number_reading_of_the_same_digits() {
        let found = extract("4111 1111 1111 1111");
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].kind, EntityKind::Card);
    }

    #[test]
    fn entities_come_back_in_reading_order() {
        let found = extract("Call 020 7946 0958 or write to a@b.com before 2026-03-14");
        let starts: Vec<i32> = found.iter().map(|entity| entity.start).collect();
        let mut sorted = starts.clone();
        sorted.sort_unstable();
        assert_eq!(starts, sorted);
    }

    // --- Redaction ---

    fn layer_of(lines: &[&str]) -> TextLayer {
        TextLayer {
            source: "camera".to_owned(),
            pages: vec![TextLayerPage {
                width: 1000.0,
                height: 1400.0,
                lines: lines
                    .iter()
                    .enumerate()
                    .map(|(index, text)| TextLayerLine {
                        text: (*text).to_owned(),
                        left: 0.0,
                        top: index as f32 * 30.0,
                        right: 400.0,
                        bottom: index as f32 * 30.0 + 20.0,
                        confidence: None,
                    })
                    .collect(),
            }],
        }
    }

    #[test]
    fn redaction_covers_the_sensitive_things_by_default() {
        let spans = find_redactions(
            layer_of(&["Card 4111 1111 1111 1111", "Total £12.00"]),
            Vec::new(),
            EntityOptions::default(),
        );
        assert_eq!(spans.len(), 1);
        assert_eq!(spans[0].kind, EntityKind::Card);
        assert_eq!(spans[0].label, "Card number");
        assert_eq!(spans[0].page, 0);
    }

    #[test]
    fn a_redaction_box_covers_the_match_not_the_whole_line() {
        let spans = find_redactions(
            layer_of(&["Card 4111 1111 1111 1111"]),
            Vec::new(),
            EntityOptions::default(),
        );
        // "Card " comes first, so the box must start in from the left edge.
        assert!(spans[0].left > 20.0, "left was {}", spans[0].left);
        assert!(spans[0].right <= 400.0);
    }

    #[test]
    fn asking_for_a_kind_redacts_only_that_kind() {
        let spans = find_redactions(
            layer_of(&["Total £12.00 on 2026-03-14"]),
            vec![EntityKind::Money],
            EntityOptions::default(),
        );
        assert_eq!(spans.len(), 1);
        assert_eq!(spans[0].kind, EntityKind::Money);
    }

    // --- Actions ---

    #[test]
    fn a_receipt_total_is_offered_as_a_task_with_its_amount() {
        let actions = suggest_actions(
            "Corner Grocer\nBread 2.40\nMilk 1.10\nTOTAL £3.50".to_owned(),
            EntityOptions::default(),
        );
        let task = actions
            .iter()
            .find(|action| action.kind == ActionKind::Task)
            .expect("a task");
        assert_eq!(task.amount_minor, Some(350));
        assert_eq!(task.currency, "GBP");
    }

    #[test]
    fn the_largest_amount_on_a_total_line_is_the_total() {
        let actions = suggest_actions(
            "TOTAL £3.50 after £1.00 discount".to_owned(),
            EntityOptions::default(),
        );
        assert_eq!(actions[0].amount_minor, Some(350));
    }

    #[test]
    fn a_dated_page_is_offered_as_an_event_in_civil_components() {
        let actions = suggest_actions(
            "Spring Concert\nSaturday 14 March 2026 at 7:30pm".to_owned(),
            EntityOptions::default(),
        );
        let event = actions
            .iter()
            .find(|action| action.kind == ActionKind::Event)
            .expect("an event");
        assert_eq!(event.title, "Spring Concert");
        assert_eq!(
            (event.year, event.month, event.day),
            (Some(2026), Some(3), Some(14))
        );
        assert_eq!((event.hour, event.minute), (Some(19), Some(30)));
    }

    #[test]
    fn a_date_with_no_year_produces_no_event() {
        let actions = suggest_actions(
            "Village fete\nSaturday 14 March".to_owned(),
            EntityOptions::default(),
        );
        assert!(!actions
            .iter()
            .any(|action| action.kind == ActionKind::Event));
    }

    #[test]
    fn a_business_card_is_offered_as_a_contact() {
        let actions = suggest_actions(
            "Ada Lovelace\nAnalyst\nada@example.com\n+44 20 7946 0958".to_owned(),
            EntityOptions::default(),
        );
        let contact = actions
            .iter()
            .find(|action| action.kind == ActionKind::Contact)
            .expect("a contact");
        assert_eq!(contact.title, "Ada Lovelace");
        assert!(contact.detail.contains("ada@example.com"));
        assert!(contact.detail.contains("+442079460958"));
    }

    #[test]
    fn a_long_letter_that_mentions_an_address_is_not_a_contact() {
        let letter = (0..20)
            .map(|index| format!("line {index} of an ordinary letter"))
            .collect::<Vec<_>>()
            .join("\n")
            + "\nwrite to a@b.com";
        let actions = suggest_actions(letter, EntityOptions::default());
        assert!(!actions
            .iter()
            .any(|action| action.kind == ActionKind::Contact));
    }

    #[test]
    fn a_page_with_nothing_actionable_suggests_nothing() {
        assert!(suggest_actions(
            "just some ordinary prose about nothing".to_owned(),
            EntityOptions::default()
        )
        .is_empty());
    }
}
