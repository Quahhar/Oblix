use flutter_rust_bridge::frb;

use super::policy::normalize_task_title;
use crate::dart_string::dart_trim;

const FIELD_CLOCKS: &str = "field_clocks";

const NOTE_FIELDS: &[&str] = &[
    "title",
    "content",
    "content_type",
    "notebook_id",
    "is_pinned",
    "is_archived",
    "tags",
    "is_deleted",
];
const NOTEBOOK_FIELDS: &[&str] = &["name", "parent_id", "sort_order", "is_deleted"];
const TASK_FIELDS: &[&str] = &[
    "title",
    "description",
    "note_id",
    // `due_has_time` is applied with `due_date` rather than stamped on its
    // own: an all-day task and one due at 5pm differ in a single fact, and two
    // registers could converge into a time attached to a date that lost it.
    "due_date",
    "sort_order",
    "is_completed",
    "is_deleted",
    "priority",
    "labels",
    "recurrence",
    "reminder_at",
    "reminder_lead_minutes",
    "notebook_id",
    "parent_id",
];

/// Most labels anyone puts on one task, and the longest a single one may be.
const MAX_LABELS: usize = 32;
const MAX_LABEL_LEN: usize = 64;

/// The outbox action selected by a deterministic mutation planner.
///
/// `Noop` means Dart must not advance the logical clock, stamp registers, or
/// write an outbox row. The planners deliberately preserve the repositories'
/// command semantics: some explicitly provided values are stamped even when
/// they equal the current value.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MutationAction {
    Noop,
    Create,
    Update,
    Delete,
}

/// Common effect-free instructions returned with every entity plan.
///
/// `changed_fields` are CRDT registers Dart must stamp. `patch_fields` are the
/// value keys the outbox payload must contain; `field_clocks` is included for
/// every non-noop plan. IDs, owner IDs, and created/updated timestamps are
/// intentionally absent because Dart supplies that application context.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MutationSelection {
    pub action: MutationAction,
    pub changed_fields: Vec<String>,
    pub patch_fields: Vec<String>,
}

/// A nullable string update with three unambiguous states:
///
/// * `provided == false`: leave the current value unchanged;
/// * `provided == true && value == Some(_)`: set a value;
/// * `provided == true && value == None`: explicitly clear the value.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct NullableStringMutation {
    pub provided: bool,
    pub value: Option<String>,
}

/// Nullable UTC timestamp update, represented as microseconds since epoch.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct NullableTimestampMutation {
    pub provided: bool,
    pub value_micros_utc: Option<i64>,
}

/// Nullable integer update, with the same three states as the others.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct NullableIntMutation {
    pub provided: bool,
    pub value: Option<i32>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NoteMutationState {
    pub title: String,
    pub content: String,
    pub content_type: String,
    pub notebook_id: Option<String>,
    pub is_pinned: bool,
    pub is_archived: bool,
    pub is_deleted: bool,
    pub tag_names: Vec<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NoteCreateInput {
    pub title: String,
    pub content: String,
    pub content_type: String,
    pub notebook_id: Option<String>,
    pub is_pinned: bool,
    pub is_archived: bool,
    pub tag_names: Vec<String>,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct NoteUpdateInput {
    pub title: Option<String>,
    pub content: Option<String>,
    pub content_type: Option<String>,
    pub notebook_id: NullableStringMutation,
    pub is_pinned: Option<bool>,
    pub is_archived: Option<bool>,
    pub tag_names: Option<Vec<String>>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NoteMutationPlan {
    pub value: NoteMutationState,
    pub selection: MutationSelection,
}

/// Plan a new note. The caller supplies identity and timestamps and stamps all
/// mutable registers at the supplied creation time.
#[frb(sync)]
pub fn plan_note_create(input: NoteCreateInput) -> NoteMutationPlan {
    NoteMutationPlan {
        value: NoteMutationState {
            title: input.title,
            content: input.content,
            content_type: input.content_type,
            notebook_id: input.notebook_id,
            is_pinned: input.is_pinned,
            is_archived: input.is_archived,
            is_deleted: false,
            tag_names: input.tag_names,
        },
        selection: selection(MutationAction::Create, NOTE_FIELDS),
    }
}

/// Plan a partial note update using the repositories' command semantics.
/// Every provided parameter is stamped, even when its value is unchanged.
#[frb(sync)]
pub fn plan_note_update(
    mut current: NoteMutationState,
    update: NoteUpdateInput,
) -> NoteMutationPlan {
    let mut changed = Vec::new();

    if let Some(title) = update.title {
        current.title = title;
        changed.push("title");
    }
    if let Some(content) = update.content {
        current.content = content;
        changed.push("content");
    }
    if let Some(content_type) = update.content_type {
        current.content_type = content_type;
        changed.push("content_type");
    }
    if update.notebook_id.provided {
        current.notebook_id = update.notebook_id.value;
        changed.push("notebook_id");
    }
    if let Some(is_pinned) = update.is_pinned {
        current.is_pinned = is_pinned;
        changed.push("is_pinned");
    }
    if let Some(is_archived) = update.is_archived {
        current.is_archived = is_archived;
        changed.push("is_archived");
    }
    if let Some(tag_names) = update.tag_names {
        current.tag_names = tag_names;
        changed.push("tags");
    }

    NoteMutationPlan {
        value: current,
        selection: update_selection(changed),
    }
}

/// Delete also clears archive state. Both registers are intentional command
/// fields, so a concurrent archive operation cannot leave a tombstone in the
/// archive view.
#[frb(sync)]
pub fn plan_note_delete(mut current: NoteMutationState) -> NoteMutationPlan {
    current.is_deleted = true;
    current.is_archived = false;
    NoteMutationPlan {
        value: current,
        selection: selection(MutationAction::Delete, &["is_deleted", "is_archived"]),
    }
}

#[frb(sync)]
pub fn plan_note_restore(mut current: NoteMutationState) -> NoteMutationPlan {
    current.is_deleted = false;
    NoteMutationPlan {
        value: current,
        selection: selection(MutationAction::Update, &["is_deleted"]),
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NotebookMutationState {
    pub name: String,
    pub parent_id: Option<String>,
    pub sort_order: i64,
    pub is_deleted: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NotebookCreateInput {
    pub name: String,
    pub parent_id: Option<String>,
    pub sort_order: i64,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct NotebookUpdateInput {
    pub name: Option<String>,
    pub parent_id: NullableStringMutation,
    pub sort_order: Option<i64>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NotebookMutationPlan {
    pub value: NotebookMutationState,
    pub selection: MutationSelection,
}

#[frb(sync)]
pub fn plan_notebook_create(input: NotebookCreateInput) -> NotebookMutationPlan {
    NotebookMutationPlan {
        value: NotebookMutationState {
            name: input.name,
            parent_id: input.parent_id,
            sort_order: input.sort_order,
            is_deleted: false,
        },
        selection: selection(MutationAction::Create, NOTEBOOK_FIELDS),
    }
}

#[frb(sync)]
pub fn plan_notebook_update(
    mut current: NotebookMutationState,
    update: NotebookUpdateInput,
) -> NotebookMutationPlan {
    let mut changed = Vec::new();
    if let Some(name) = update.name {
        current.name = name;
        changed.push("name");
    }
    if update.parent_id.provided {
        current.parent_id = update.parent_id.value;
        changed.push("parent_id");
    }
    if let Some(sort_order) = update.sort_order {
        current.sort_order = sort_order;
        changed.push("sort_order");
    }
    NotebookMutationPlan {
        value: current,
        selection: update_selection(changed),
    }
}

#[frb(sync)]
pub fn plan_notebook_delete(mut current: NotebookMutationState) -> NotebookMutationPlan {
    current.is_deleted = true;
    NotebookMutationPlan {
        value: current,
        selection: selection(MutationAction::Delete, &["is_deleted"]),
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TaskMutationState {
    pub title: String,
    pub description: String,
    pub note_id: Option<String>,
    pub notebook_id: Option<String>,
    pub parent_id: Option<String>,
    pub due_date_micros_utc: Option<i64>,
    pub due_has_time: bool,
    pub priority: i32,
    pub labels: Vec<String>,
    pub recurrence: Option<String>,
    pub reminder_at_micros_utc: Option<i64>,
    pub reminder_lead_minutes: Option<i32>,
    pub sort_order: i64,
    pub is_completed: bool,
    pub completed_at_micros_utc: Option<i64>,
    pub is_deleted: bool,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct TaskCreateInput {
    pub title: String,
    pub description: String,
    pub note_id: Option<String>,
    pub notebook_id: Option<String>,
    pub parent_id: Option<String>,
    pub due_date_micros_utc: Option<i64>,
    pub due_has_time: bool,
    pub priority: i32,
    pub labels: Vec<String>,
    pub recurrence: Option<String>,
    pub reminder_at_micros_utc: Option<i64>,
    pub reminder_lead_minutes: Option<i32>,
    pub sort_order: i64,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct TaskUpdateInput {
    pub title: Option<String>,
    pub description: Option<String>,
    pub note_id: NullableStringMutation,
    pub notebook_id: NullableStringMutation,
    pub parent_id: NullableStringMutation,
    pub due_date: NullableTimestampMutation,
    /// Only meaningful alongside `due_date`, or on its own to switch an
    /// existing date between all-day and timed. Either way it stamps the
    /// `due_date` register.
    pub due_has_time: Option<bool>,
    pub priority: Option<i32>,
    pub labels: Option<Vec<String>>,
    pub recurrence: NullableStringMutation,
    pub reminder_at: NullableTimestampMutation,
    pub reminder_lead_minutes: NullableIntMutation,
    pub sort_order: Option<i64>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TaskMutationPlan {
    pub value: TaskMutationState,
    pub selection: MutationSelection,
}

#[frb(sync)]
pub fn plan_task_create(input: TaskCreateInput) -> TaskMutationPlan {
    let due_date_micros_utc = input.due_date_micros_utc;
    TaskMutationPlan {
        value: TaskMutationState {
            title: normalize_task_title(input.title),
            description: input.description,
            note_id: input.note_id,
            notebook_id: input.notebook_id,
            parent_id: input.parent_id,
            due_date_micros_utc,
            // A time of day needs a date to sit on.
            due_has_time: input.due_has_time && due_date_micros_utc.is_some(),
            priority: clamp_priority(input.priority),
            labels: normalize_labels(input.labels),
            recurrence: normalize_recurrence(input.recurrence),
            reminder_at_micros_utc: input.reminder_at_micros_utc,
            reminder_lead_minutes: clamp_lead(input.reminder_lead_minutes),
            sort_order: input.sort_order,
            is_completed: false,
            completed_at_micros_utc: None,
            is_deleted: false,
        },
        selection: selection(MutationAction::Create, TASK_FIELDS),
    }
}

#[frb(sync)]
pub fn plan_task_update(
    mut current: TaskMutationState,
    update: TaskUpdateInput,
) -> TaskMutationPlan {
    let mut changed = Vec::new();
    if let Some(title) = update.title {
        assign_if_changed(&mut current.title, title, "title", &mut changed);
    }
    if let Some(description) = update.description {
        assign_if_changed(
            &mut current.description,
            description,
            "description",
            &mut changed,
        );
    }
    if update.note_id.provided {
        current.note_id = update.note_id.value;
        changed.push("note_id");
    }
    if update.notebook_id.provided {
        current.notebook_id = update.notebook_id.value;
        changed.push("notebook_id");
    }
    if update.parent_id.provided {
        current.parent_id = update.parent_id.value;
        changed.push("parent_id");
    }
    // `due_has_time` shares the `due_date` register, so either one changing
    // stamps that register once and both values travel together.
    if update.due_date.provided || update.due_has_time.is_some() {
        if update.due_date.provided {
            current.due_date_micros_utc = update.due_date.value_micros_utc;
        }
        let wants_time = update.due_has_time.unwrap_or(current.due_has_time);
        current.due_has_time = wants_time && current.due_date_micros_utc.is_some();
        changed.push("due_date");
    }
    if let Some(priority) = update.priority {
        assign_if_changed(
            &mut current.priority,
            clamp_priority(priority),
            "priority",
            &mut changed,
        );
    }
    if let Some(labels) = update.labels {
        assign_if_changed(
            &mut current.labels,
            normalize_labels(labels),
            "labels",
            &mut changed,
        );
    }
    if update.recurrence.provided {
        current.recurrence = normalize_recurrence(update.recurrence.value);
        changed.push("recurrence");
    }
    if update.reminder_at.provided {
        current.reminder_at_micros_utc = update.reminder_at.value_micros_utc;
        changed.push("reminder_at");
    }
    if update.reminder_lead_minutes.provided {
        current.reminder_lead_minutes = clamp_lead(update.reminder_lead_minutes.value);
        changed.push("reminder_lead_minutes");
    }
    if let Some(sort_order) = update.sort_order {
        assign_if_changed(
            &mut current.sort_order,
            sort_order,
            "sort_order",
            &mut changed,
        );
    }
    TaskMutationPlan {
        value: current,
        selection: update_selection(changed),
    }
}

/// Toggle completion while keeping `completed_at` in the same logical
/// register as `is_completed`. The timestamp is supplied by Dart's clock.
#[frb(sync)]
pub fn plan_task_completion(
    mut current: TaskMutationState,
    completed: bool,
    timestamp_micros_utc: i64,
) -> TaskMutationPlan {
    if current.is_completed == completed {
        return TaskMutationPlan {
            value: current,
            selection: noop_selection(),
        };
    }
    current.is_completed = completed;
    current.completed_at_micros_utc = completed.then_some(timestamp_micros_utc);
    TaskMutationPlan {
        value: current,
        selection: selection(MutationAction::Update, &["is_completed"]),
    }
}

/// Roll a repeating task onto its next occurrence instead of completing it.
///
/// Ticking "water the plants every 3 days" should not retire the task; it
/// should move. The caller has already asked `tasks::advance_on_completion`
/// where the next occurrence falls and converted that civil date — plus any
/// reminder lead — into instants, because only Dart knows the device's zone.
/// This planner records the move.
///
/// `next_due_micros_utc` of `None` means the rule could not advance, which the
/// caller should treat as an ordinary completion rather than as a task that
/// silently lost its date.
#[frb(sync)]
pub fn plan_task_rollover(
    mut current: TaskMutationState,
    next_due_micros_utc: Option<i64>,
    next_reminder_micros_utc: Option<i64>,
) -> TaskMutationPlan {
    if next_due_micros_utc.is_none() {
        return TaskMutationPlan {
            value: current,
            selection: noop_selection(),
        };
    }
    let mut changed = vec!["due_date"];
    current.due_date_micros_utc = next_due_micros_utc;
    // The occurrence moved, so a reminder pinned to the old one must move or
    // go; leaving it would fire for a date that has already passed.
    if current.reminder_at_micros_utc != next_reminder_micros_utc {
        current.reminder_at_micros_utc = next_reminder_micros_utc;
        changed.push("reminder_at");
    }
    // A rolled task is emphatically not complete.
    if current.is_completed {
        current.is_completed = false;
        current.completed_at_micros_utc = None;
        changed.push("is_completed");
    }
    TaskMutationPlan {
        value: current,
        selection: selection(MutationAction::Update, &changed),
    }
}

#[frb(sync)]
pub fn plan_task_delete(mut current: TaskMutationState) -> TaskMutationPlan {
    current.is_deleted = true;
    TaskMutationPlan {
        value: current,
        selection: selection(MutationAction::Delete, &["is_deleted"]),
    }
}

/// Ranks outside the known set read as "no priority" rather than persisting a
/// value the rest of the app cannot order.
fn clamp_priority(value: i32) -> i32 {
    value.clamp(0, 3)
}

/// Four weeks of lead time is past anything a person means by "before".
fn clamp_lead(value: Option<i32>) -> Option<i32> {
    value.map(|minutes| minutes.clamp(0, 40_320))
}

/// An empty rule is no rule, so a cleared field and an empty string agree.
fn normalize_recurrence(value: Option<String>) -> Option<String> {
    value.filter(|rule| !rule.is_empty())
}

/// Trim, bound and de-duplicate label names while keeping their display case.
/// Two labels differing only in case are the same label.
fn normalize_labels(labels: Vec<String>) -> Vec<String> {
    let mut seen: Vec<String> = Vec::new();
    let mut out: Vec<String> = Vec::new();
    for label in labels {
        let trimmed = dart_trim(&label);
        if trimmed.is_empty() {
            continue;
        }
        let bounded: String = trimmed.chars().take(MAX_LABEL_LEN).collect();
        let key = bounded.to_lowercase();
        if seen.contains(&key) {
            continue;
        }
        seen.push(key);
        out.push(bounded);
        if out.len() >= MAX_LABELS {
            break;
        }
    }
    out
}

fn assign_if_changed<T: PartialEq>(
    current: &mut T,
    next: T,
    field: &'static str,
    changed: &mut Vec<&'static str>,
) {
    if *current != next {
        *current = next;
        changed.push(field);
    }
}

fn update_selection(changed: Vec<&'static str>) -> MutationSelection {
    if changed.is_empty() {
        noop_selection()
    } else {
        selection(MutationAction::Update, &changed)
    }
}

fn selection(action: MutationAction, changed: &[&str]) -> MutationSelection {
    let changed_fields = changed
        .iter()
        .map(|field| (*field).to_owned())
        .collect::<Vec<_>>();
    let mut patch_fields = Vec::with_capacity(changed.len() + 3);
    for field in changed {
        patch_fields.push((*field).to_owned());
        // Companions: values that are carried by another field's register
        // rather than converging on their own.
        if *field == "is_completed" {
            patch_fields.push("completed_at".to_owned());
        }
        if *field == "due_date" {
            patch_fields.push("due_has_time".to_owned());
        }
    }
    patch_fields.push(FIELD_CLOCKS.to_owned());
    MutationSelection {
        action,
        changed_fields,
        patch_fields,
    }
}

fn noop_selection() -> MutationSelection {
    MutationSelection {
        action: MutationAction::Noop,
        changed_fields: Vec::new(),
        patch_fields: Vec::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn note() -> NoteMutationState {
        NoteMutationState {
            title: "Current".to_owned(),
            content: "Body".to_owned(),
            content_type: "plain".to_owned(),
            notebook_id: Some("inbox".to_owned()),
            is_pinned: false,
            is_archived: false,
            is_deleted: false,
            tag_names: vec!["work".to_owned()],
        }
    }

    fn notebook() -> NotebookMutationState {
        NotebookMutationState {
            name: "Projects".to_owned(),
            parent_id: Some("work".to_owned()),
            sort_order: 3,
            is_deleted: false,
        }
    }

    fn task() -> TaskMutationState {
        TaskMutationState {
            title: "Current task".to_owned(),
            description: "Description".to_owned(),
            note_id: Some("note-1".to_owned()),
            notebook_id: None,
            parent_id: None,
            due_date_micros_utc: Some(1_000),
            due_has_time: false,
            priority: 0,
            labels: Vec::new(),
            recurrence: None,
            reminder_at_micros_utc: None,
            reminder_lead_minutes: None,
            sort_order: 4,
            is_completed: false,
            completed_at_micros_utc: None,
            is_deleted: false,
        }
    }

    #[test]
    fn note_create_preserves_title_and_selects_every_register() {
        let plan = plan_note_create(NoteCreateInput {
            title: "  ".to_owned(),
            content: "Body".to_owned(),
            content_type: "markdown".to_owned(),
            notebook_id: None,
            is_pinned: true,
            is_archived: false,
            tag_names: vec!["one".to_owned()],
        });

        assert_eq!(plan.value.title, "  ");
        assert_eq!(plan.selection.action, MutationAction::Create);
        assert_eq!(plan.selection.changed_fields, strings(NOTE_FIELDS));
        assert_eq!(
            plan.selection.patch_fields,
            strings(&[
                "title",
                "content",
                "content_type",
                "notebook_id",
                "is_pinned",
                "is_archived",
                "tags",
                "is_deleted",
                "field_clocks",
            ])
        );
    }

    #[test]
    fn note_update_stamps_every_provided_parameter_and_preserves_raw_title() {
        let no_parameters = plan_note_update(note(), NoteUpdateInput::default());
        assert_eq!(no_parameters.selection, noop_selection());

        let equal_values = plan_note_update(
            note(),
            NoteUpdateInput {
                title: Some("Current".to_owned()),
                content: Some("Body".to_owned()),
                is_pinned: Some(false),
                tag_names: Some(vec!["work".to_owned()]),
                ..NoteUpdateInput::default()
            },
        );
        assert_eq!(equal_values.selection.action, MutationAction::Update);
        assert_eq!(
            equal_values.selection.changed_fields,
            strings(&["title", "content", "is_pinned", "tags"])
        );

        let changed = plan_note_update(
            note(),
            NoteUpdateInput {
                title: Some("  New title  ".to_owned()),
                is_pinned: Some(true),
                tag_names: Some(vec!["work".to_owned(), "urgent".to_owned()]),
                ..NoteUpdateInput::default()
            },
        );
        assert_eq!(changed.value.title, "  New title  ");
        assert!(changed.value.is_pinned);
        assert_eq!(
            changed.selection.changed_fields,
            strings(&["title", "is_pinned", "tags"])
        );
        assert_eq!(
            changed.selection.patch_fields,
            strings(&["title", "is_pinned", "tags", "field_clocks"])
        );
    }

    #[test]
    fn nullable_note_link_distinguishes_unchanged_set_and_clear_commands() {
        let ignored = plan_note_update(
            note(),
            NoteUpdateInput {
                notebook_id: NullableStringMutation {
                    provided: false,
                    value: Some("ignored".to_owned()),
                },
                ..NoteUpdateInput::default()
            },
        );
        assert_eq!(ignored.value.notebook_id.as_deref(), Some("inbox"));
        assert_eq!(ignored.selection.action, MutationAction::Noop);

        let set = plan_note_update(
            note(),
            NoteUpdateInput {
                notebook_id: NullableStringMutation {
                    provided: true,
                    value: Some("inbox".to_owned()),
                },
                ..NoteUpdateInput::default()
            },
        );
        assert_eq!(set.value.notebook_id.as_deref(), Some("inbox"));
        assert_eq!(set.selection.action, MutationAction::Update);
        assert_eq!(set.selection.changed_fields, strings(&["notebook_id"]));

        let cleared = plan_note_update(
            note(),
            NoteUpdateInput {
                notebook_id: NullableStringMutation {
                    provided: true,
                    value: None,
                },
                ..NoteUpdateInput::default()
            },
        );
        assert_eq!(cleared.value.notebook_id, None);
        assert_eq!(
            cleared.selection.patch_fields,
            strings(&["notebook_id", "field_clocks"])
        );
    }

    #[test]
    fn note_delete_and_restore_repeat_the_repository_commands() {
        let mut archived = note();
        archived.is_archived = true;
        let deleted = plan_note_delete(archived);
        assert!(deleted.value.is_deleted);
        assert!(!deleted.value.is_archived);
        assert_eq!(deleted.selection.action, MutationAction::Delete);
        assert_eq!(
            deleted.selection.changed_fields,
            strings(&["is_deleted", "is_archived"])
        );

        let deleted_again = plan_note_delete(deleted.value.clone());
        assert_eq!(deleted_again.selection.action, MutationAction::Delete);
        assert_eq!(
            deleted_again.selection.changed_fields,
            strings(&["is_deleted", "is_archived"])
        );
        let restored = plan_note_restore(deleted.value);
        assert!(!restored.value.is_deleted);
        assert_eq!(restored.selection.action, MutationAction::Update);
        assert_eq!(
            plan_note_restore(restored.value).selection.action,
            MutationAction::Update
        );
    }

    #[test]
    fn notebook_plans_create_update_clear_and_delete() {
        let created = plan_notebook_create(NotebookCreateInput {
            name: "Inbox".to_owned(),
            parent_id: None,
            sort_order: 0,
        });
        assert_eq!(created.selection.action, MutationAction::Create);
        assert_eq!(created.selection.changed_fields, strings(NOTEBOOK_FIELDS));

        let updated = plan_notebook_update(
            notebook(),
            NotebookUpdateInput {
                name: Some("Projects".to_owned()),
                parent_id: NullableStringMutation {
                    provided: true,
                    value: None,
                },
                sort_order: Some(9),
            },
        );
        assert_eq!(updated.value.parent_id, None);
        assert_eq!(updated.value.sort_order, 9);
        assert_eq!(
            updated.selection.changed_fields,
            strings(&["name", "parent_id", "sort_order"])
        );
        let deleted = plan_notebook_delete(updated.value.clone());
        assert_eq!(deleted.selection.action, MutationAction::Delete);
        let mut already_deleted = updated.value;
        already_deleted.is_deleted = true;
        assert_eq!(
            plan_notebook_delete(already_deleted).selection.action,
            MutationAction::Delete
        );
    }

    #[test]
    fn sort_order_preserves_full_dart_integer_boundaries_on_unrelated_updates() {
        const POSITIVE_BOUNDARY: i64 = 2_147_483_648;
        const NEGATIVE_BOUNDARY: i64 = -2_147_483_649;

        let created_notebook = plan_notebook_create(NotebookCreateInput {
            name: "Wide notebook".to_owned(),
            parent_id: None,
            sort_order: POSITIVE_BOUNDARY,
        });
        assert_eq!(created_notebook.value.sort_order, POSITIVE_BOUNDARY);

        let mut wide_notebook = notebook();
        wide_notebook.sort_order = POSITIVE_BOUNDARY;
        let renamed_notebook = plan_notebook_update(
            wide_notebook,
            NotebookUpdateInput {
                name: Some("Renamed".to_owned()),
                ..NotebookUpdateInput::default()
            },
        );
        assert_eq!(renamed_notebook.value.sort_order, POSITIVE_BOUNDARY);
        assert_eq!(
            renamed_notebook.selection.changed_fields,
            strings(&["name"])
        );

        let created_task = plan_task_create(TaskCreateInput {
            title: "Wide task".to_owned(),
            description: String::new(),
            note_id: None,
            due_date_micros_utc: None,
            sort_order: NEGATIVE_BOUNDARY,
            ..TaskCreateInput::default()
        });
        assert_eq!(created_task.value.sort_order, NEGATIVE_BOUNDARY);

        let mut wide_task = task();
        wide_task.sort_order = NEGATIVE_BOUNDARY;
        let described_task = plan_task_update(
            wide_task,
            TaskUpdateInput {
                description: Some("Changed only description".to_owned()),
                ..TaskUpdateInput::default()
            },
        );
        assert_eq!(described_task.value.sort_order, NEGATIVE_BOUNDARY);
        assert_eq!(
            described_task.selection.changed_fields,
            strings(&["description"])
        );
    }

    #[test]
    fn task_create_canonicalizes_title_and_includes_completion_companion() {
        let plan = plan_task_create(TaskCreateInput {
            title: " \t ".to_owned(),
            description: "Body".to_owned(),
            note_id: None,
            due_date_micros_utc: None,
            sort_order: 0,
            ..TaskCreateInput::default()
        });
        assert_eq!(plan.value.title, "Untitled task");
        assert!(!plan.value.is_completed);
        assert_eq!(plan.value.completed_at_micros_utc, None);
        assert_eq!(plan.selection.changed_fields, strings(TASK_FIELDS));
        // `completed_at` rides with `is_completed`, `due_has_time` with
        // `due_date`, and `field_clocks` accompanies every non-noop plan — so
        // the payload carries three keys that are not registers of their own.
        assert_eq!(
            plan.selection.patch_fields,
            strings(&[
                "title",
                "description",
                "note_id",
                "due_date",
                "due_has_time",
                "sort_order",
                "is_completed",
                "completed_at",
                "is_deleted",
                "priority",
                "labels",
                "recurrence",
                "reminder_at",
                "reminder_lead_minutes",
                "notebook_id",
                "parent_id",
                "field_clocks",
            ])
        );
    }

    #[test]
    fn task_update_compares_raw_scalars_and_honors_explicit_operations() {
        let no_change = plan_task_update(
            task(),
            TaskUpdateInput {
                title: Some("Current task".to_owned()),
                description: Some("Description".to_owned()),
                due_date: NullableTimestampMutation {
                    provided: false,
                    value_micros_utc: Some(999_999),
                },
                sort_order: Some(4),
                ..TaskUpdateInput::default()
            },
        );
        assert_eq!(no_change.selection.action, MutationAction::Noop);

        let equal_explicit_operations = plan_task_update(
            task(),
            TaskUpdateInput {
                note_id: NullableStringMutation {
                    provided: true,
                    value: Some("note-1".to_owned()),
                },
                due_date: NullableTimestampMutation {
                    provided: true,
                    value_micros_utc: Some(1_000),
                },
                ..TaskUpdateInput::default()
            },
        );
        assert_eq!(
            equal_explicit_operations.selection.changed_fields,
            strings(&["note_id", "due_date"])
        );

        let changed = plan_task_update(
            task(),
            TaskUpdateInput {
                title: Some("  Next task  ".to_owned()),
                description: Some("New description".to_owned()),
                note_id: NullableStringMutation {
                    provided: true,
                    value: None,
                },
                due_date: NullableTimestampMutation {
                    provided: true,
                    value_micros_utc: None,
                },
                sort_order: Some(8),
                ..TaskUpdateInput::default()
            },
        );
        assert_eq!(changed.value.title, "  Next task  ");
        assert_eq!(changed.value.note_id, None);
        assert_eq!(changed.value.due_date_micros_utc, None);
        assert_eq!(
            changed.selection.changed_fields,
            strings(&["title", "description", "note_id", "due_date", "sort_order",])
        );
    }

    #[test]
    fn task_completion_owns_its_timestamp_and_noops_on_same_state() {
        let done = plan_task_completion(task(), true, 42_000);
        assert!(done.value.is_completed);
        assert_eq!(done.value.completed_at_micros_utc, Some(42_000));
        assert_eq!(done.selection.changed_fields, strings(&["is_completed"]));
        assert_eq!(
            done.selection.patch_fields,
            strings(&["is_completed", "completed_at", "field_clocks"])
        );

        let same = plan_task_completion(done.value.clone(), true, 99_000);
        assert_eq!(same.selection.action, MutationAction::Noop);
        assert_eq!(same.value.completed_at_micros_utc, Some(42_000));

        let reopened = plan_task_completion(done.value, false, 100_000);
        assert!(!reopened.value.is_completed);
        assert_eq!(reopened.value.completed_at_micros_utc, None);
    }

    #[test]
    fn due_has_time_travels_inside_the_due_date_register() {
        // Setting a date and a time stamps one register, not two.
        let timed = plan_task_update(
            task(),
            TaskUpdateInput {
                due_date: NullableTimestampMutation {
                    provided: true,
                    value_micros_utc: Some(9_000),
                },
                due_has_time: Some(true),
                ..TaskUpdateInput::default()
            },
        );
        assert_eq!(timed.selection.changed_fields, vec!["due_date".to_owned()]);
        assert!(timed.value.due_has_time);

        // Switching an existing date to all-day also stamps due_date.
        let all_day = plan_task_update(
            timed.value.clone(),
            TaskUpdateInput {
                due_has_time: Some(false),
                ..TaskUpdateInput::default()
            },
        );
        assert_eq!(
            all_day.selection.changed_fields,
            vec!["due_date".to_owned()]
        );
        assert!(!all_day.value.due_has_time);

        // Clearing the date drops the time with it: 5pm on no day is not a
        // state the rest of the app should ever have to render.
        let cleared = plan_task_update(
            timed.value,
            TaskUpdateInput {
                due_date: NullableTimestampMutation {
                    provided: true,
                    value_micros_utc: None,
                },
                ..TaskUpdateInput::default()
            },
        );
        assert_eq!(cleared.value.due_date_micros_utc, None);
        assert!(!cleared.value.due_has_time);
    }

    #[test]
    fn labels_are_trimmed_deduplicated_and_bounded() {
        let plan = plan_task_update(
            task(),
            TaskUpdateInput {
                labels: Some(vec![
                    "  Email  ".to_owned(),
                    "email".to_owned(),
                    String::new(),
                    "Calls".to_owned(),
                ]),
                ..TaskUpdateInput::default()
            },
        );
        assert_eq!(
            plan.value.labels,
            vec!["Email".to_owned(), "Calls".to_owned()]
        );
        assert_eq!(plan.selection.changed_fields, vec!["labels".to_owned()]);

        // Re-applying the same set in a different spelling is not a change,
        // so it must not burn a sync round trip.
        let again = plan_task_update(
            plan.value,
            TaskUpdateInput {
                labels: Some(vec!["Email".to_owned(), "Calls".to_owned()]),
                ..TaskUpdateInput::default()
            },
        );
        assert_eq!(again.selection.action, MutationAction::Noop);
    }

    #[test]
    fn priority_outside_the_known_ranks_falls_back_to_none() {
        let plan = plan_task_create(TaskCreateInput {
            title: "x".to_owned(),
            priority: 99,
            ..TaskCreateInput::default()
        });
        assert_eq!(plan.value.priority, 3);

        let negative = plan_task_create(TaskCreateInput {
            title: "x".to_owned(),
            priority: -4,
            ..TaskCreateInput::default()
        });
        assert_eq!(negative.value.priority, 0);
    }

    #[test]
    fn a_rollover_moves_the_date_and_its_reminder_without_completing() {
        let mut repeating = task();
        repeating.recurrence = Some("FREQ=DAILY;INTERVAL=3".to_owned());
        repeating.reminder_at_micros_utc = Some(500);
        repeating.is_completed = true;
        repeating.completed_at_micros_utc = Some(400);

        let plan = plan_task_rollover(repeating, Some(50_000), Some(49_000));
        assert_eq!(plan.value.due_date_micros_utc, Some(50_000));
        assert_eq!(plan.value.reminder_at_micros_utc, Some(49_000));
        assert!(!plan.value.is_completed);
        assert_eq!(plan.value.completed_at_micros_utc, None);
        assert_eq!(
            plan.selection.changed_fields,
            vec![
                "due_date".to_owned(),
                "reminder_at".to_owned(),
                "is_completed".to_owned(),
            ],
        );
    }

    #[test]
    fn a_rule_that_cannot_advance_leaves_the_task_alone() {
        // The caller then completes the task normally rather than stranding it
        // on a date that never moved.
        let plan = plan_task_rollover(task(), None, None);
        assert_eq!(plan.selection.action, MutationAction::Noop);
        assert_eq!(plan.value.due_date_micros_utc, Some(1_000));
    }

    #[test]
    fn task_delete_repeats_and_selects_only_tombstone_register() {
        let deleted = plan_task_delete(task());
        assert!(deleted.value.is_deleted);
        assert_eq!(deleted.selection.action, MutationAction::Delete);
        assert_eq!(deleted.selection.changed_fields, strings(&["is_deleted"]));
        assert_eq!(
            deleted.selection.patch_fields,
            strings(&["is_deleted", "field_clocks"])
        );
        assert_eq!(
            plan_task_delete(deleted.value).selection.action,
            MutationAction::Delete
        );
    }

    fn strings(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| (*value).to_owned()).collect()
    }
}
