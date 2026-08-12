//! The task engine: repetition, ordering, and what a list actually shows.
//!
//! Everything a task list decides — which day a repeating chore lands on next,
//! what order rows appear in, which rows are nested under which parent, how
//! many dots a calendar cell gets — is arithmetic over values the caller
//! supplies. None of it needs a database, a widget, or a clock, so all of it
//! lives here and behaves identically on every platform.
//!
//! Two boundaries are deliberate, and they match the rest of the crate.
//!
//! *No clock, no zone.* `chrono` is built without its clock and local-time
//! features. Dart reads `DateTime.now().toLocal()` — the only authority on the
//! device's zone and its DST discontinuities — and hands civil components
//! across, exactly as note grouping and the archive codecs already do. A task
//! due "tomorrow at 9" is a civil date and a wall-clock time until Dart pins it
//! to an instant.
//!
//! *No hidden completion.* Ticking a repeating task is two facts, not one: the
//! occurrence that was finished, and the occurrence that comes next. This
//! module returns both and lets the repository decide how to persist them.

use chrono::{Datelike, Duration, NaiveDate};
use flutter_rust_bridge::frb;

/// Longest run of skipped occurrences we will search before giving up.
///
/// A rule like "every 31st" has no February match, so advancing has to be
/// allowed to miss. The ceiling keeps a pathological or corrupted rule from
/// spinning: 400 iterations clears a leap year for every frequency we support.
const MAX_ADVANCE_STEPS: u32 = 400;

/// Priority ranks. Stored as an integer so ordering is plain arithmetic and a
/// future rank cannot break old clients: anything unrecognized reads as `None`.
pub const PRIORITY_NONE: i32 = 0;
pub const PRIORITY_LOW: i32 = 1;
pub const PRIORITY_HIGH: i32 = 2;
pub const PRIORITY_URGENT: i32 = 3;

const WEEKDAY_CODES: [&str; 7] = ["MO", "TU", "WE", "TH", "FR", "SA", "SU"];
const WEEKDAY_SHORT: [&str; 7] = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
const WEEKDAY_LONG: [&str; 7] = [
    "Monday",
    "Tuesday",
    "Wednesday",
    "Thursday",
    "Friday",
    "Saturday",
    "Sunday",
];
const MONTH_SHORT: [&str; 12] = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
];

/// A calendar date with no zone attached. Dart localizes it.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct CivilDate {
    pub year: i32,
    pub month: u32,
    pub day: u32,
}

/// A wall-clock time with no zone attached.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct CivilTime {
    pub hour: u32,
    pub minute: u32,
}

impl CivilDate {
    fn to_naive(self) -> Option<NaiveDate> {
        NaiveDate::from_ymd_opt(self.year, self.month, self.day)
    }

    fn from_naive(date: NaiveDate) -> Self {
        CivilDate {
            year: date.year(),
            month: date.month(),
            day: date.day(),
        }
    }
}

/// How often a task repeats.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RecurrenceFreq {
    Daily,
    Weekly,
    Monthly,
    Yearly,
}

/// What the next occurrence is measured from.
///
/// `Schedule` keeps a fixed cadence: rent is due on the 1st whether or not you
/// paid March late. `Completion` measures from the day you finished, which is
/// what "water the plants every 3 days" actually means — the clock restarts
/// when the chore is done, so a late completion pushes the next one out.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RecurrenceMode {
    Schedule,
    Completion,
}

/// A repetition rule.
///
/// `by_weekday` holds Monday-relative indices (0 = Monday). It is only
/// meaningful for [`RecurrenceFreq::Weekly`]; other frequencies ignore it.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RecurrenceRule {
    pub freq: RecurrenceFreq,
    pub interval: u32,
    pub by_weekday: Vec<u32>,
    pub mode: RecurrenceMode,
}

impl RecurrenceRule {
    fn sanitized(mut self) -> Self {
        self.interval = self.interval.clamp(1, 1000);
        self.by_weekday.retain(|day| *day < 7);
        self.by_weekday.sort_unstable();
        self.by_weekday.dedup();
        if self.freq != RecurrenceFreq::Weekly {
            self.by_weekday.clear();
        }
        self
    }
}

/// Render a rule to the compact text stored in the `recurrence` column.
///
/// The shape is RRULE-shaped on purpose — `FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TH`
/// — so it stays readable in a database row and in a sync payload, and so a
/// later iCalendar export has somewhere obvious to start. It is not full
/// RFC 5545: only what the app can honestly honour is representable.
#[frb(sync)]
pub fn serialize_recurrence(rule: RecurrenceRule) -> String {
    let rule = rule.sanitized();
    let freq = match rule.freq {
        RecurrenceFreq::Daily => "DAILY",
        RecurrenceFreq::Weekly => "WEEKLY",
        RecurrenceFreq::Monthly => "MONTHLY",
        RecurrenceFreq::Yearly => "YEARLY",
    };
    let mut out = format!("FREQ={freq};INTERVAL={}", rule.interval);
    if !rule.by_weekday.is_empty() {
        let days: Vec<&str> = rule
            .by_weekday
            .iter()
            .filter_map(|day| WEEKDAY_CODES.get(*day as usize).copied())
            .collect();
        out.push_str(";BYDAY=");
        out.push_str(&days.join(","));
    }
    if rule.mode == RecurrenceMode::Completion {
        out.push_str(";MODE=COMPLETION");
    }
    out
}

/// Read a stored rule back. Unknown keys are ignored and a malformed rule is
/// `None` rather than an error, because a row written by a newer client must
/// degrade to "does not repeat" instead of breaking the list.
#[frb(sync)]
pub fn parse_recurrence(text: String) -> Option<RecurrenceRule> {
    let mut freq = None;
    let mut interval = 1_u32;
    let mut by_weekday = Vec::new();
    let mut mode = RecurrenceMode::Schedule;

    for part in text.split(';') {
        let (key, value) = part.split_once('=')?;
        match key.trim().to_ascii_uppercase().as_str() {
            "FREQ" => {
                freq = match value.trim().to_ascii_uppercase().as_str() {
                    "DAILY" => Some(RecurrenceFreq::Daily),
                    "WEEKLY" => Some(RecurrenceFreq::Weekly),
                    "MONTHLY" => Some(RecurrenceFreq::Monthly),
                    "YEARLY" => Some(RecurrenceFreq::Yearly),
                    _ => return None,
                };
            }
            "INTERVAL" => interval = value.trim().parse::<u32>().ok()?,
            "BYDAY" => {
                for code in value.split(',') {
                    let code = code.trim().to_ascii_uppercase();
                    if code.is_empty() {
                        continue;
                    }
                    let index = WEEKDAY_CODES.iter().position(|entry| *entry == code)?;
                    by_weekday.push(index as u32);
                }
            }
            "MODE" => {
                if value.trim().eq_ignore_ascii_case("COMPLETION") {
                    mode = RecurrenceMode::Completion;
                }
            }
            _ => {}
        }
    }

    Some(
        RecurrenceRule {
            freq: freq?,
            interval,
            by_weekday,
            mode,
        }
        .sanitized(),
    )
}

/// One-line human description for the row and the editor ("Every 2 weeks on
/// Mon, Thu"). Kept here so the phrasing cannot drift between screens.
#[frb(sync)]
pub fn describe_recurrence(rule: RecurrenceRule) -> String {
    let rule = rule.sanitized();
    let every = |unit: &str, plural: &str| -> String {
        if rule.interval == 1 {
            format!("Every {unit}")
        } else {
            format!("Every {} {plural}", rule.interval)
        }
    };

    let base = match rule.freq {
        RecurrenceFreq::Daily => every("day", "days"),
        RecurrenceFreq::Yearly => every("year", "years"),
        RecurrenceFreq::Monthly => every("month", "months"),
        RecurrenceFreq::Weekly => {
            if rule.by_weekday == [0, 1, 2, 3, 4] && rule.interval == 1 {
                return "Every weekday".to_owned();
            }
            let weekly = every("week", "weeks");
            if rule.by_weekday.is_empty() {
                weekly
            } else if rule.by_weekday.len() == 1 && rule.interval == 1 {
                // "Every Monday" reads better than "Every week on Mon".
                return format!("Every {}", WEEKDAY_LONG[rule.by_weekday[0].min(6) as usize]);
            } else {
                let names: Vec<&str> = rule
                    .by_weekday
                    .iter()
                    .filter_map(|day| WEEKDAY_SHORT.get(*day as usize).copied())
                    .collect();
                format!("{weekly} on {}", names.join(", "))
            }
        }
    };

    if rule.mode == RecurrenceMode::Completion {
        format!("{base} after completion")
    } else {
        base
    }
}

/// The date a repeating task moves to once the current occurrence is done.
///
/// `from` is the occurrence being advanced past — the old due date under
/// [`RecurrenceMode::Schedule`], the completion date under
/// [`RecurrenceMode::Completion`]. The result is always strictly later than
/// `from`, so ticking an overdue chore can never leave it in the past: a
/// monthly bill three months late jumps to the next month that has not
/// happened yet rather than to a date that is still overdue. Pass `not_before`
/// (normally today) to enable that catch-up; pass `from` itself to disable it.
#[frb(sync)]
pub fn next_occurrence(
    rule: RecurrenceRule,
    from: CivilDate,
    not_before: CivilDate,
) -> Option<CivilDate> {
    let rule = rule.sanitized();
    let start = from.to_naive()?;
    let floor = not_before.to_naive().unwrap_or(start);
    let mut cursor = start;

    for _ in 0..MAX_ADVANCE_STEPS {
        cursor = step_once(&rule, cursor)?;
        if cursor > start && cursor >= floor {
            return Some(CivilDate::from_naive(cursor));
        }
    }
    None
}

/// Advance one repetition from `cursor`, without the catch-up floor.
fn step_once(rule: &RecurrenceRule, cursor: NaiveDate) -> Option<NaiveDate> {
    match rule.freq {
        RecurrenceFreq::Daily => cursor.checked_add_signed(Duration::days(rule.interval as i64)),
        RecurrenceFreq::Weekly => Some(next_weekly(rule, cursor)),
        RecurrenceFreq::Monthly => add_months(cursor, rule.interval as i32),
        RecurrenceFreq::Yearly => add_months(cursor, rule.interval as i32 * 12),
    }
}

/// Weekly stepping, with or without an explicit day set.
///
/// Without `BYDAY` this is just "n weeks later". With it, the next listed day
/// inside the current week comes first; once the week is exhausted the cursor
/// jumps `interval` weeks ahead and takes the earliest listed day. Anchoring on
/// the week rather than on the previous date is what keeps "every other Monday
/// and Thursday" from drifting into a 3/11-day sawtooth.
fn next_weekly(rule: &RecurrenceRule, cursor: NaiveDate) -> NaiveDate {
    let step = Duration::days(rule.interval as i64 * 7);
    if rule.by_weekday.is_empty() {
        return cursor + step;
    }
    let current = cursor.weekday().num_days_from_monday();
    if let Some(next) = rule
        .by_weekday
        .iter()
        .copied()
        .find(|day| *day > current)
        .and_then(|day| cursor.checked_add_signed(Duration::days((day - current) as i64)))
    {
        return next;
    }
    // Past the last listed day: rewind to this week's Monday, jump the
    // interval, then take the first listed day of that week.
    let monday = cursor - Duration::days(current as i64);
    let first = rule.by_weekday.first().copied().unwrap_or(0);
    monday + step + Duration::days(first as i64)
}

/// Add whole months, clamping to the last valid day.
///
/// The 31st plus one month is the 28th, 29th or 30th, never a rollover into
/// the following month — a task due on the 31st must not silently become due
/// on March 3rd.
fn add_months(date: NaiveDate, months: i32) -> Option<NaiveDate> {
    let zero_based = date.year() as i64 * 12 + (date.month() as i64 - 1) + months as i64;
    let year = i32::try_from(zero_based.div_euclid(12)).ok()?;
    let month = zero_based.rem_euclid(12) as u32 + 1;
    let day = date.day().min(days_in_month(year, month));
    NaiveDate::from_ymd_opt(year, month, day)
}

fn days_in_month(year: i32, month: u32) -> u32 {
    let (next_year, next_month) = if month == 12 {
        (year + 1, 1)
    } else {
        (year, month + 1)
    };
    match (
        NaiveDate::from_ymd_opt(year, month, 1),
        NaiveDate::from_ymd_opt(next_year, next_month, 1),
    ) {
        (Some(start), Some(next)) => next.signed_duration_since(start).num_days() as u32,
        _ => 28,
    }
}

/// What ticking a repeating task should do.
///
/// `next_due` is `None` for a one-off task or a rule that cannot advance; the
/// caller then completes the task normally. When it is set, the caller instead
/// rolls the task forward and — if `reminder_lead_minutes` was set — moves the
/// reminder with it.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RecurrenceAdvance {
    pub next_due: Option<CivilDate>,
    pub keeps_time: bool,
}

/// Decide where a repeating task lands when it is completed on `completed_on`.
#[frb(sync)]
pub fn advance_on_completion(
    recurrence: Option<String>,
    due: Option<CivilDate>,
    due_has_time: bool,
    completed_on: CivilDate,
) -> RecurrenceAdvance {
    let Some(rule) = recurrence.and_then(parse_recurrence) else {
        return RecurrenceAdvance {
            next_due: None,
            keeps_time: false,
        };
    };
    // A completion-mode rule measures from the day the work was done; a
    // schedule-mode rule measures from the occurrence that was due. An
    // undated repeating task has only the completion day to go on.
    let anchor = match rule.mode {
        RecurrenceMode::Completion => completed_on,
        RecurrenceMode::Schedule => due.unwrap_or(completed_on),
    };
    RecurrenceAdvance {
        next_due: next_occurrence(rule, anchor, completed_on),
        keeps_time: due_has_time,
    }
}

/// How a list is ordered.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TaskSort {
    /// Urgency first, then the clock, then the user's own arrangement.
    Smart,
    /// The user's drag order, untouched.
    Manual,
    Priority,
    DueDate,
    Alphabetical,
}

/// One task, reduced to what ordering and grouping need.
///
/// `due` and `completed_on` are civil dates Dart has already localized.
/// `created_seq` is any stable, monotonically increasing stamp (microseconds
/// since epoch works) used only as the final tiebreak, so ordering is total
/// and two runs over the same data can never disagree.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TaskViewInput {
    pub id: String,
    pub title: String,
    pub parent_id: Option<String>,
    pub priority: i32,
    pub due: Option<CivilDate>,
    pub due_time: Option<CivilTime>,
    pub is_completed: bool,
    pub completed_on: Option<CivilDate>,
    pub sort_order: i64,
    pub created_seq: i64,
}

/// Which band of the list a row belongs to.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TaskSectionKind {
    Overdue,
    Focus,
    Anytime,
    Completed,
}

/// A rendered row. `depth` is the indent level (0 for a top-level task) and the
/// child counts drive the "2/5" progress a parent shows.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TaskRow {
    pub id: String,
    pub depth: u32,
    pub child_total: u32,
    pub child_done: u32,
    pub is_overdue: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TaskSection {
    pub kind: TaskSectionKind,
    pub label: String,
    pub rows: Vec<TaskRow>,
}

/// What the screen is currently showing.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct TaskViewContext {
    pub today: CivilDate,
    /// The day the list is focused on. Equal to `today` on open.
    pub focus: CivilDate,
    pub sort: TaskSort,
    pub show_completed: bool,
    /// Whether undated tasks appear. They only make sense on today's list;
    /// showing a backlog under a future date implies it is due then.
    pub show_anytime: bool,
}

/// The whole plan for one screenful, plus the counts the header shows.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TaskViewPlan {
    pub sections: Vec<TaskSection>,
    pub open_count: u32,
    pub overdue_count: u32,
    pub completed_count: u32,
}

/// Lay out the task list.
///
/// Subtasks follow their parent and are indented, but only when the parent is
/// on screen too. A subtask whose parent is filtered out — a chore due today
/// under a project scheduled for next week — is promoted to a top-level row
/// rather than vanishing, because a hidden parent must never hide work that is
/// genuinely due.
#[frb(sync)]
pub fn plan_task_view(tasks: Vec<TaskViewInput>, context: TaskViewContext) -> TaskViewPlan {
    let today = context.today.to_naive();
    let focus = context.focus.to_naive();
    let focus_is_today = today.is_some() && today == focus;

    let mut overdue = Vec::new();
    let mut on_focus = Vec::new();
    let mut anytime = Vec::new();
    let mut completed = Vec::new();

    for task in &tasks {
        let due = task.due.and_then(CivilDate::to_naive);
        if task.is_completed {
            // A finished task belongs to the day it was finished, so today's
            // list shows today's wins and does not accumulate history.
            let done_on = task.completed_on.and_then(CivilDate::to_naive);
            if context.show_completed && done_on.is_some() && done_on == focus {
                completed.push(task);
            }
            continue;
        }
        match (due, today, focus) {
            (Some(due), Some(today), Some(focus)) if due < today && focus == today => {
                overdue.push(task)
            }
            (Some(due), _, Some(focus)) if due == focus => on_focus.push(task),
            // An overdue task stays visible while the focus is today; on any
            // other day it is simply not that day's work.
            (Some(_), _, _) => {}
            (None, _, _) => {
                if context.show_anytime && focus_is_today {
                    anytime.push(task)
                }
            }
        }
    }

    let open_count = (overdue.len() + on_focus.len()) as u32;
    let overdue_count = overdue.len() as u32;
    let completed_count = completed.len() as u32;

    let mut sections = Vec::new();
    let mut push = |kind: TaskSectionKind, label: &str, bucket: Vec<&TaskViewInput>| {
        if bucket.is_empty() {
            return;
        }
        sections.push(TaskSection {
            kind,
            label: label.to_owned(),
            rows: arrange(bucket, &tasks, context.sort, today),
        });
    };

    push(TaskSectionKind::Overdue, "OVERDUE", overdue);
    push(
        TaskSectionKind::Focus,
        &focus_label(context.focus, context.today, focus_is_today),
        on_focus,
    );
    push(TaskSectionKind::Anytime, "ANYTIME", anytime);
    push(TaskSectionKind::Completed, "COMPLETED", completed);

    TaskViewPlan {
        sections,
        open_count,
        overdue_count,
        completed_count,
    }
}

/// Heading for the focused day: TODAY, TOMORROW, a weekday inside the coming
/// week, otherwise a calendar date.
fn focus_label(focus: CivilDate, today: CivilDate, focus_is_today: bool) -> String {
    if focus_is_today {
        return "TODAY".to_owned();
    }
    let (Some(focus_date), Some(today_date)) = (focus.to_naive(), today.to_naive()) else {
        return "SCHEDULED".to_owned();
    };
    let days = focus_date.signed_duration_since(today_date).num_days();
    if days == 1 {
        return "TOMORROW".to_owned();
    }
    if days == -1 {
        return "YESTERDAY".to_owned();
    }
    if (2..7).contains(&days) {
        return WEEKDAY_LONG[focus_date.weekday().num_days_from_monday() as usize].to_uppercase();
    }
    let month = MONTH_SHORT
        .get(focus_date.month0() as usize)
        .copied()
        .unwrap_or_default();
    let label = format!("{} {}", month.to_uppercase(), focus_date.day());
    if focus_date.year() == today_date.year() {
        label
    } else {
        format!("{label}, {}", focus_date.year())
    }
}

/// Sort one bucket and thread its subtasks in underneath their parents.
fn arrange(
    bucket: Vec<&TaskViewInput>,
    all: &[TaskViewInput],
    sort: TaskSort,
    today: Option<NaiveDate>,
) -> Vec<TaskRow> {
    let visible: Vec<&str> = bucket.iter().map(|task| task.id.as_str()).collect();
    let is_visible = |id: &str| visible.contains(&id);

    // Roots are tasks with no parent, plus tasks whose parent is not in this
    // bucket. Both render flush left.
    let mut roots: Vec<&TaskViewInput> = bucket
        .iter()
        .copied()
        .filter(|task| match &task.parent_id {
            Some(parent) => !is_visible(parent),
            None => true,
        })
        .collect();
    sort_bucket(&mut roots, sort, today);

    let mut rows = Vec::with_capacity(bucket.len());
    for root in roots {
        emit(root, 0, &bucket, all, sort, today, &mut rows);
    }
    rows
}

/// Append a task and, recursively, its visible children.
fn emit<'a>(
    task: &'a TaskViewInput,
    depth: u32,
    bucket: &[&'a TaskViewInput],
    all: &[TaskViewInput],
    sort: TaskSort,
    today: Option<NaiveDate>,
    rows: &mut Vec<TaskRow>,
) {
    let (child_total, child_done) = child_progress(&task.id, all);
    rows.push(TaskRow {
        id: task.id.clone(),
        depth,
        child_total,
        child_done,
        is_overdue: is_overdue(task, today),
    });
    // Two levels of indent is as deep as a phone row can stay readable;
    // grandchildren keep their parent's indent rather than marching off-screen.
    let child_depth = (depth + 1).min(2);
    let mut children: Vec<&TaskViewInput> = bucket
        .iter()
        .copied()
        .filter(|candidate| candidate.parent_id.as_deref() == Some(task.id.as_str()))
        .collect();
    sort_bucket(&mut children, sort, today);
    for child in children {
        emit(child, child_depth, bucket, all, sort, today, rows);
    }
}

/// Progress across every child of a task, whether or not it is on screen. A
/// parent showing "1/3" must count the two subtasks scheduled for next week.
fn child_progress(parent_id: &str, all: &[TaskViewInput]) -> (u32, u32) {
    let mut total = 0;
    let mut done = 0;
    for task in all {
        if task.parent_id.as_deref() == Some(parent_id) {
            total += 1;
            if task.is_completed {
                done += 1;
            }
        }
    }
    (total, done)
}

fn is_overdue(task: &TaskViewInput, today: Option<NaiveDate>) -> bool {
    match (task.due.and_then(CivilDate::to_naive), today) {
        (Some(due), Some(today)) => !task.is_completed && due < today,
        _ => false,
    }
}

fn sort_bucket(bucket: &mut [&TaskViewInput], sort: TaskSort, today: Option<NaiveDate>) {
    bucket.sort_by(|left, right| match sort {
        TaskSort::Manual => left
            .sort_order
            .cmp(&right.sort_order)
            .then_with(|| left.created_seq.cmp(&right.created_seq)),
        TaskSort::Alphabetical => left
            .title
            .to_lowercase()
            .cmp(&right.title.to_lowercase())
            .then_with(|| left.created_seq.cmp(&right.created_seq)),
        TaskSort::Priority => rank_priority(left)
            .cmp(&rank_priority(right))
            .then_with(|| rank_clock(left).cmp(&rank_clock(right)))
            .then_with(|| left.sort_order.cmp(&right.sort_order))
            .then_with(|| left.created_seq.cmp(&right.created_seq)),
        TaskSort::DueDate => rank_clock(left)
            .cmp(&rank_clock(right))
            .then_with(|| rank_priority(left).cmp(&rank_priority(right)))
            .then_with(|| left.sort_order.cmp(&right.sort_order))
            .then_with(|| left.created_seq.cmp(&right.created_seq)),
        // Smart: how late it already is, then how much it matters, then when
        // it is due, then the arrangement the user chose by hand.
        TaskSort::Smart => rank_lateness(left, today)
            .cmp(&rank_lateness(right, today))
            .then_with(|| rank_priority(left).cmp(&rank_priority(right)))
            .then_with(|| rank_clock(left).cmp(&rank_clock(right)))
            .then_with(|| left.sort_order.cmp(&right.sort_order))
            .then_with(|| left.created_seq.cmp(&right.created_seq)),
    });
}

/// Higher priority sorts first, so the rank is negated.
fn rank_priority(task: &TaskViewInput) -> i32 {
    -task.priority.clamp(PRIORITY_NONE, PRIORITY_URGENT)
}

/// Minutes into the day, with all-day tasks after timed ones. A task at 9am
/// outranks one merely due "today".
fn rank_clock(task: &TaskViewInput) -> i32 {
    match task.due_time {
        Some(time) => (time.hour.min(23) * 60 + time.minute.min(59)) as i32,
        None => i32::MAX,
    }
}

/// Days late, capped, so the longest-overdue item leads.
fn rank_lateness(task: &TaskViewInput, today: Option<NaiveDate>) -> i64 {
    match (task.due.and_then(CivilDate::to_naive), today) {
        (Some(due), Some(today)) => {
            let late = today.signed_duration_since(due).num_days();
            if late > 0 {
                -late
            } else {
                0
            }
        }
        _ => 0,
    }
}

/// One cell of the month strip.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct CalendarDay {
    pub day: u32,
    pub open_count: u32,
    pub has_overdue: bool,
    pub has_urgent: bool,
    pub all_done: bool,
}

/// Density for every day of one month, so the calendar can show at a glance
/// where the work is. Counts open tasks only; `all_done` marks a day that had
/// tasks and finished them, which is what earns a day its quiet checkmark.
#[frb(sync)]
pub fn month_density(
    tasks: Vec<TaskViewInput>,
    year: i32,
    month: u32,
    today: CivilDate,
) -> Vec<CalendarDay> {
    let length = days_in_month(year, month);
    let today_date = today.to_naive();
    let mut days: Vec<CalendarDay> = (1..=length)
        .map(|day| CalendarDay {
            day,
            open_count: 0,
            has_overdue: false,
            has_urgent: false,
            all_done: false,
        })
        .collect();
    let mut completed_on_day = vec![false; length as usize];

    for task in &tasks {
        let Some(due) = task.due else { continue };
        if due.year != year || due.month != month || due.day == 0 || due.day > length {
            continue;
        }
        let slot = (due.day - 1) as usize;
        if task.is_completed {
            completed_on_day[slot] = true;
            continue;
        }
        days[slot].open_count += 1;
        if task.priority >= PRIORITY_URGENT {
            days[slot].has_urgent = true;
        }
        if let (Some(due_date), Some(today_date)) = (due.to_naive(), today_date) {
            if due_date < today_date {
                days[slot].has_overdue = true;
            }
        }
    }

    for (slot, day) in days.iter_mut().enumerate() {
        day.all_done = day.open_count == 0 && completed_on_day[slot];
    }
    days
}

/// When a reminder fires, in civil components Dart pins to an instant.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ReminderInstant {
    pub date: CivilDate,
    pub time: CivilTime,
}

/// The instant a reminder should fire, as civil components.
///
/// Returns `None` when the task has no due date to hang a reminder on, or when
/// the lead time would place the reminder before the calendar can express it.
/// A lead of zero means "at the due time".
#[frb(sync)]
pub fn reminder_time(
    due: CivilDate,
    due_time: Option<CivilTime>,
    lead_minutes: i32,
    all_day_hour: u32,
    all_day_minute: u32,
) -> Option<ReminderInstant> {
    let base = due.to_naive()?;
    // An all-day task has no time of its own, so the caller's morning slot is
    // what a reminder for it means.
    let time = due_time.unwrap_or(CivilTime {
        hour: all_day_hour.min(23),
        minute: all_day_minute.min(59),
    });
    let minutes_into_day = (time.hour.min(23) * 60 + time.minute.min(59)) as i64;
    let shifted = minutes_into_day - lead_minutes as i64;
    let day_shift = shifted.div_euclid(1440);
    let minute_of_day = shifted.rem_euclid(1440);
    let date = base.checked_add_signed(Duration::days(day_shift))?;
    Some(ReminderInstant {
        date: CivilDate::from_naive(date),
        time: CivilTime {
            hour: (minute_of_day / 60) as u32,
            minute: (minute_of_day % 60) as u32,
        },
    })
}

/// Renumber a manually reordered list.
///
/// Dart hands over the ids in their new order and gets back only the rows whose
/// rank actually moved, so a drag writes two or three outbox entries instead of
/// rewriting the whole list. Ranks are spaced so the common case — dropping one
/// row between two others — usually changes exactly one number.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SortAssignment {
    pub id: String,
    pub sort_order: i64,
}

#[frb(sync)]
pub fn plan_reorder(ordered_ids: Vec<String>, current: Vec<SortAssignment>) -> Vec<SortAssignment> {
    const SPACING: i64 = 1024;
    let mut changes = Vec::new();
    for (index, id) in ordered_ids.iter().enumerate() {
        let target = (index as i64 + 1) * SPACING;
        let existing = current
            .iter()
            .find(|entry| entry.id == *id)
            .map(|entry| entry.sort_order);
        if existing != Some(target) {
            changes.push(SortAssignment {
                id: id.clone(),
                sort_order: target,
            });
        }
    }
    changes
}

#[cfg(test)]
mod tests {
    use super::*;

    fn date(year: i32, month: u32, day: u32) -> CivilDate {
        CivilDate { year, month, day }
    }

    fn rule(freq: RecurrenceFreq, interval: u32, days: &[u32]) -> RecurrenceRule {
        RecurrenceRule {
            freq,
            interval,
            by_weekday: days.to_vec(),
            mode: RecurrenceMode::Schedule,
        }
    }

    fn task(id: &str, due: Option<CivilDate>) -> TaskViewInput {
        TaskViewInput {
            id: id.to_owned(),
            title: id.to_owned(),
            parent_id: None,
            priority: PRIORITY_NONE,
            due,
            due_time: None,
            is_completed: false,
            completed_on: None,
            sort_order: 0,
            created_seq: 0,
        }
    }

    #[test]
    fn recurrence_round_trips_through_its_stored_form() {
        let original = RecurrenceRule {
            freq: RecurrenceFreq::Weekly,
            interval: 2,
            by_weekday: vec![3, 0],
            mode: RecurrenceMode::Completion,
        };
        let text = serialize_recurrence(original.clone());
        assert_eq!(text, "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TH;MODE=COMPLETION");
        // Serializing sorts the day set, so the parsed rule is the sanitized
        // form of the original rather than the original literally.
        assert_eq!(parse_recurrence(text), Some(original.sanitized()));
    }

    #[test]
    fn a_malformed_rule_reads_as_no_repetition() {
        assert_eq!(parse_recurrence("FREQ=FORTNIGHTLY".to_owned()), None);
        assert_eq!(parse_recurrence("nonsense".to_owned()), None);
        assert_eq!(parse_recurrence(String::new()), None);
        assert_eq!(parse_recurrence("FREQ=WEEKLY;BYDAY=XX".to_owned()), None);
        // An unknown key is ignored rather than fatal, so a newer client's
        // extra parameter still yields a usable rule.
        assert_eq!(
            parse_recurrence("FREQ=DAILY;INTERVAL=2;BYSETPOS=1".to_owned()),
            Some(rule(RecurrenceFreq::Daily, 2, &[])),
        );
    }

    #[test]
    fn daily_and_weekly_advance_by_their_interval() {
        assert_eq!(
            next_occurrence(
                rule(RecurrenceFreq::Daily, 3, &[]),
                date(2026, 8, 10),
                date(2026, 8, 10)
            ),
            Some(date(2026, 8, 13)),
        );
        assert_eq!(
            next_occurrence(
                rule(RecurrenceFreq::Weekly, 2, &[]),
                date(2026, 8, 10),
                date(2026, 8, 10)
            ),
            Some(date(2026, 8, 24)),
        );
    }

    #[test]
    fn a_weekday_set_walks_the_week_then_jumps_the_interval() {
        // 2026-08-10 is a Monday. Mondays and Thursdays, every other week.
        let every_other = rule(RecurrenceFreq::Weekly, 2, &[0, 3]);
        let thursday = next_occurrence(every_other.clone(), date(2026, 8, 10), date(2026, 8, 10));
        assert_eq!(thursday, Some(date(2026, 8, 13)));
        // Past Thursday the cursor leaves the week entirely: back to this
        // Monday, forward two weeks, land on Monday the 24th.
        assert_eq!(
            next_occurrence(every_other, date(2026, 8, 13), date(2026, 8, 13)),
            Some(date(2026, 8, 24)),
        );
    }

    #[test]
    fn every_weekday_skips_the_weekend() {
        let weekdays = rule(RecurrenceFreq::Weekly, 1, &[0, 1, 2, 3, 4]);
        // Friday 2026-08-14 -> Monday 2026-08-17.
        assert_eq!(
            next_occurrence(weekdays, date(2026, 8, 14), date(2026, 8, 14)),
            Some(date(2026, 8, 17)),
        );
    }

    #[test]
    fn monthly_clamps_instead_of_rolling_into_the_next_month() {
        // Jan 31 + 1 month is the last day of February, not March 3rd.
        assert_eq!(
            next_occurrence(
                rule(RecurrenceFreq::Monthly, 1, &[]),
                date(2026, 1, 31),
                date(2026, 1, 31)
            ),
            Some(date(2026, 2, 28)),
        );
        // 2028 is a leap year, so the same rule reaches the 29th.
        assert_eq!(
            next_occurrence(
                rule(RecurrenceFreq::Monthly, 1, &[]),
                date(2028, 1, 31),
                date(2028, 1, 31)
            ),
            Some(date(2028, 2, 29)),
        );
    }

    #[test]
    fn completing_a_late_bill_catches_up_past_today() {
        // Monthly rent due in May, ticked in August: the next one is September,
        // not June, so the task does not reappear already overdue.
        let advance = advance_on_completion(
            Some("FREQ=MONTHLY;INTERVAL=1".to_owned()),
            Some(date(2026, 5, 1)),
            false,
            date(2026, 8, 10),
        );
        assert_eq!(advance.next_due, Some(date(2026, 9, 1)));
    }

    #[test]
    fn completion_mode_measures_from_the_day_the_work_was_done() {
        // Watered late on the 10th: next watering is three days after that,
        // not three days after the date it was nominally due.
        let advance = advance_on_completion(
            Some("FREQ=DAILY;INTERVAL=3;MODE=COMPLETION".to_owned()),
            Some(date(2026, 8, 4)),
            true,
            date(2026, 8, 10),
        );
        assert_eq!(advance.next_due, Some(date(2026, 8, 13)));
        assert!(advance.keeps_time);
    }

    #[test]
    fn a_one_off_task_does_not_advance() {
        let advance =
            advance_on_completion(None, Some(date(2026, 8, 10)), false, date(2026, 8, 10));
        assert_eq!(advance.next_due, None);
    }

    #[test]
    fn descriptions_read_like_english() {
        assert_eq!(
            describe_recurrence(rule(RecurrenceFreq::Weekly, 1, &[0])),
            "Every Monday",
        );
        assert_eq!(
            describe_recurrence(rule(RecurrenceFreq::Weekly, 1, &[0, 1, 2, 3, 4])),
            "Every weekday",
        );
        assert_eq!(
            describe_recurrence(rule(RecurrenceFreq::Weekly, 2, &[0, 3])),
            "Every 2 weeks on Mon, Thu",
        );
        assert_eq!(
            describe_recurrence(rule(RecurrenceFreq::Daily, 1, &[])),
            "Every day",
        );
        assert_eq!(
            describe_recurrence(RecurrenceRule {
                freq: RecurrenceFreq::Daily,
                interval: 3,
                by_weekday: vec![],
                mode: RecurrenceMode::Completion,
            }),
            "Every 3 days after completion",
        );
    }

    fn context(focus: CivilDate) -> TaskViewContext {
        TaskViewContext {
            today: date(2026, 8, 10),
            focus,
            sort: TaskSort::Smart,
            show_completed: true,
            show_anytime: true,
        }
    }

    #[test]
    fn today_shows_overdue_then_today_then_the_backlog() {
        let plan = plan_task_view(
            vec![
                task("late", Some(date(2026, 8, 4))),
                task("now", Some(date(2026, 8, 10))),
                task("someday", None),
                task("future", Some(date(2026, 9, 1))),
            ],
            context(date(2026, 8, 10)),
        );
        let labels: Vec<&str> = plan
            .sections
            .iter()
            .map(|section| section.label.as_str())
            .collect();
        assert_eq!(labels, vec!["OVERDUE", "TODAY", "ANYTIME"]);
        assert_eq!(plan.overdue_count, 1);
        assert_eq!(plan.open_count, 2);
        assert!(plan.sections[0].rows[0].is_overdue);
    }

    #[test]
    fn a_future_day_hides_overdue_and_the_undated_backlog() {
        let plan = plan_task_view(
            vec![
                task("late", Some(date(2026, 8, 4))),
                task("someday", None),
                task("then", Some(date(2026, 8, 11))),
            ],
            context(date(2026, 8, 11)),
        );
        let labels: Vec<&str> = plan
            .sections
            .iter()
            .map(|section| section.label.as_str())
            .collect();
        assert_eq!(labels, vec!["TOMORROW"]);
    }

    #[test]
    fn smart_order_leads_with_the_latest_then_the_most_urgent() {
        let mut very_late = task("very-late", Some(date(2026, 8, 1)));
        let mut slightly_late = task("slightly-late", Some(date(2026, 8, 9)));
        slightly_late.priority = PRIORITY_URGENT;
        let mut urgent_today = task("urgent-today", Some(date(2026, 8, 10)));
        urgent_today.priority = PRIORITY_URGENT;
        let calm_today = task("calm-today", Some(date(2026, 8, 10)));
        very_late.priority = PRIORITY_NONE;

        let plan = plan_task_view(
            vec![slightly_late, very_late, calm_today, urgent_today],
            context(date(2026, 8, 10)),
        );
        let overdue: Vec<&str> = plan.sections[0]
            .rows
            .iter()
            .map(|row| row.id.as_str())
            .collect();
        // Nine days late beats one day late even though the latter is urgent.
        assert_eq!(overdue, vec!["very-late", "slightly-late"]);
        let today: Vec<&str> = plan.sections[1]
            .rows
            .iter()
            .map(|row| row.id.as_str())
            .collect();
        assert_eq!(today, vec!["urgent-today", "calm-today"]);
    }

    #[test]
    fn a_timed_task_sorts_ahead_of_an_all_day_one() {
        let mut timed = task("timed", Some(date(2026, 8, 10)));
        timed.due_time = Some(CivilTime {
            hour: 17,
            minute: 0,
        });
        let all_day = task("all-day", Some(date(2026, 8, 10)));
        let plan = plan_task_view(vec![all_day, timed], context(date(2026, 8, 10)));
        let ids: Vec<&str> = plan.sections[0]
            .rows
            .iter()
            .map(|row| row.id.as_str())
            .collect();
        assert_eq!(ids, vec!["timed", "all-day"]);
    }

    #[test]
    fn subtasks_indent_under_a_visible_parent() {
        let parent = task("parent", Some(date(2026, 8, 10)));
        let mut child = task("child", Some(date(2026, 8, 10)));
        child.parent_id = Some("parent".to_owned());
        let mut done_child = task("done-child", Some(date(2026, 8, 10)));
        done_child.parent_id = Some("parent".to_owned());
        done_child.is_completed = true;
        done_child.completed_on = Some(date(2026, 8, 10));

        let mut view = context(date(2026, 8, 10));
        view.show_completed = false;
        let plan = plan_task_view(vec![child, parent, done_child], view);
        let rows = &plan.sections[0].rows;
        assert_eq!(rows[0].id, "parent");
        assert_eq!(rows[0].depth, 0);
        // The finished child is off screen but still counted in the rollup.
        assert_eq!((rows[0].child_total, rows[0].child_done), (2, 1));
        assert_eq!(rows[1].id, "child");
        assert_eq!(rows[1].depth, 1);
    }

    #[test]
    fn an_orphaned_subtask_is_promoted_rather_than_hidden() {
        // The parent is due next week, the child today: the child must still
        // appear on today's list, flush left.
        let parent = task("parent", Some(date(2026, 8, 20)));
        let mut child = task("child", Some(date(2026, 8, 10)));
        child.parent_id = Some("parent".to_owned());
        let plan = plan_task_view(vec![parent, child], context(date(2026, 8, 10)));
        assert_eq!(plan.sections[0].rows.len(), 1);
        assert_eq!(plan.sections[0].rows[0].id, "child");
        assert_eq!(plan.sections[0].rows[0].depth, 0);
    }

    #[test]
    fn completed_tasks_belong_to_the_day_they_were_finished() {
        let mut done_today = task("done-today", Some(date(2026, 8, 1)));
        done_today.is_completed = true;
        done_today.completed_on = Some(date(2026, 8, 10));
        let mut done_earlier = task("done-earlier", Some(date(2026, 8, 1)));
        done_earlier.is_completed = true;
        done_earlier.completed_on = Some(date(2026, 8, 9));

        let plan = plan_task_view(vec![done_today, done_earlier], context(date(2026, 8, 10)));
        assert_eq!(plan.sections.len(), 1);
        assert_eq!(plan.sections[0].kind, TaskSectionKind::Completed);
        assert_eq!(plan.completed_count, 1);
        assert_eq!(plan.sections[0].rows[0].id, "done-today");
    }

    #[test]
    fn month_density_counts_open_work_and_marks_cleared_days() {
        let mut urgent = task("urgent", Some(date(2026, 8, 12)));
        urgent.priority = PRIORITY_URGENT;
        let mut cleared = task("cleared", Some(date(2026, 8, 3)));
        cleared.is_completed = true;
        cleared.completed_on = Some(date(2026, 8, 3));

        let days = month_density(
            vec![
                task("late", Some(date(2026, 8, 4))),
                urgent,
                cleared,
                task("other-month", Some(date(2026, 9, 1))),
            ],
            2026,
            8,
            date(2026, 8, 10),
        );
        assert_eq!(days.len(), 31);
        assert!(days[3].has_overdue && days[3].open_count == 1);
        assert!(days[11].has_urgent && !days[11].has_overdue);
        assert!(days[2].all_done && days[2].open_count == 0);
        assert_eq!(days[0].open_count, 0);
    }

    #[test]
    fn reminder_lead_can_cross_back_over_midnight() {
        let fired = reminder_time(
            date(2026, 8, 10),
            Some(CivilTime {
                hour: 0,
                minute: 30,
            }),
            60,
            9,
            0,
        )
        .expect("a dated task has a reminder");
        assert_eq!(fired.date, date(2026, 8, 9));
        assert_eq!(
            fired.time,
            CivilTime {
                hour: 23,
                minute: 30
            }
        );
    }

    #[test]
    fn an_all_day_task_reminds_at_the_callers_morning_slot() {
        let fired = reminder_time(date(2026, 8, 10), None, 0, 9, 0).expect("has a reminder");
        assert_eq!(fired.date, date(2026, 8, 10));
        assert_eq!(fired.time, CivilTime { hour: 9, minute: 0 });
    }

    #[test]
    fn reorder_only_reports_the_rows_that_moved() {
        let current = vec![
            SortAssignment {
                id: "a".to_owned(),
                sort_order: 1024,
            },
            SortAssignment {
                id: "b".to_owned(),
                sort_order: 2048,
            },
            SortAssignment {
                id: "c".to_owned(),
                sort_order: 3072,
            },
        ];
        let unchanged = plan_reorder(
            vec!["a".to_owned(), "b".to_owned(), "c".to_owned()],
            current.clone(),
        );
        assert!(unchanged.is_empty());

        let moved = plan_reorder(
            vec!["a".to_owned(), "c".to_owned(), "b".to_owned()],
            current,
        );
        assert_eq!(moved.len(), 2);
        assert_eq!(moved[0].id, "c");
        assert_eq!(moved[0].sort_order, 2048);
        assert_eq!(moved[1].id, "b");
        assert_eq!(moved[1].sort_order, 3072);
    }

    #[test]
    fn impossible_dates_do_not_panic() {
        assert_eq!(
            next_occurrence(
                rule(RecurrenceFreq::Daily, 1, &[]),
                date(2026, 13, 40),
                date(2026, 8, 10)
            ),
            None,
        );
    }

    #[test]
    fn a_task_with_an_unreadable_due_date_is_shown_not_dropped() {
        // February 30th cannot be placed on a calendar, but the task is real
        // and the user has to be able to reach it. It falls back to the
        // undated backlog rather than disappearing from every list.
        let plan = plan_task_view(
            vec![task("bad", Some(date(2026, 2, 30)))],
            context(date(2026, 8, 10)),
        );
        assert_eq!(plan.sections.len(), 1);
        assert_eq!(plan.sections[0].kind, TaskSectionKind::Anytime);
        assert_eq!(plan.sections[0].rows[0].id, "bad");
    }
}
