use std::collections::{HashMap, HashSet};

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use flutter_rust_bridge::frb;
use serde_json::Value;

use crate::dart_string::{dart_trim, is_dart_regexp_whitespace};

/// Minimal outbox identity needed by the deterministic sync planner.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SyncBatchEntryInput {
    pub seq: i64,
    pub entity_type: String,
    pub entity_id: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SyncSettlementPlan {
    pub acked_seqs: Vec<i64>,
    pub retry_seqs: Vec<i64>,
    pub pulled_count: i32,
    pub anything_changed: bool,
    pub continue_draining: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NotebookNodeInput {
    pub id: String,
    pub name: String,
    pub parent_id: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NotebookPathOutput {
    pub id: String,
    pub path: Vec<String>,
    pub path_key: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PendingOutboxRowInput {
    pub seq: i64,
    pub action: String,
    pub data_json: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PendingOutboxFieldSeqs {
    pub field: String,
    pub seqs: Vec<i64>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PendingOutboxSummaryOutput {
    pub fields: Vec<String>,
    pub update_seqs_by_field: Vec<PendingOutboxFieldSeqs>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct OutboxRetirementOutput {
    pub changed: bool,
    pub delete_row: bool,
    pub data_json: String,
}

/// Keep protected live-collaboration notes out of the HTTP sync batch.
#[frb(sync)]
pub fn eligible_sync_sequences(
    entries: Vec<SyncBatchEntryInput>,
    protected_note_ids: Vec<String>,
) -> Vec<i64> {
    let protected: HashSet<String> = protected_note_ids.into_iter().collect();
    entries
        .into_iter()
        .filter(|entry| entry.entity_type != "note" || !protected.contains(&entry.entity_id))
        .map(|entry| entry.seq)
        .collect()
}

/// Classify a server response and decide whether the outbox can keep draining.
#[frb(sync)]
pub fn plan_sync_settlement(
    entries: Vec<SyncBatchEntryInput>,
    decided_entity_ids: Vec<String>,
    protected_server_note_seen: bool,
    batch_size: i32,
    pulled_entity_counts: Vec<i32>,
    dropped_count: i32,
) -> SyncSettlementPlan {
    let decided: HashSet<String> = decided_entity_ids.into_iter().collect();
    let ack_all = !entries.is_empty() && decided.is_empty();
    let mut acked_seqs = Vec::new();
    let mut retry_seqs = Vec::new();
    for entry in &entries {
        if ack_all || decided.contains(&entry.entity_id) {
            acked_seqs.push(entry.seq);
        } else {
            retry_seqs.push(entry.seq);
        }
    }

    let pulled_count = pulled_entity_counts.into_iter().sum();
    let anything_changed = pulled_count > 0 || !acked_seqs.is_empty() || dropped_count > 0;
    let continue_draining = !protected_server_note_seen
        && entries.len() >= usize::try_from(batch_size.max(0)).unwrap_or(usize::MAX)
        && retry_seqs.is_empty();

    SyncSettlementPlan {
        acked_seqs,
        retry_seqs,
        pulled_count,
        anything_changed,
        continue_draining,
    }
}

/// Enforce a monotonic logical edit time over a skew-corrected wall clock.
#[frb(sync)]
pub fn next_logical_timestamp_micros(now_micros_utc: i64, previous_micros_utc: Option<i64>) -> i64 {
    match previous_micros_utc {
        Some(previous) if now_micros_utc <= previous => previous.saturating_add(1_000),
        _ => now_micros_utc,
    }
}

/// JWT expiry policy used before opening a collaboration WebSocket.
#[frb(sync)]
pub fn token_needs_refresh(token: String, now_epoch_seconds: i64) -> bool {
    let Some(payload) = token.split('.').nth(1) else {
        return true;
    };
    let Ok(decoded) = URL_SAFE_NO_PAD.decode(payload) else {
        return true;
    };
    let Ok(json) = serde_json::from_slice::<Value>(&decoded) else {
        return true;
    };
    let Some(expires) = json.get("exp").and_then(Value::as_i64) else {
        return true;
    };
    expires <= now_epoch_seconds.saturating_add(60)
}

/// Extract an unverified JWT subject for local account cache isolation.
#[frb(sync)]
pub fn jwt_subject(token: String) -> Option<String> {
    let mut pieces = token.split('.');
    let (_header, payload, _signature) = (pieces.next()?, pieces.next()?, pieces.next()?);
    if pieces.next().is_some() {
        return None;
    }
    let decoded = URL_SAFE_NO_PAD.decode(payload).ok()?;
    let json = serde_json::from_slice::<Value>(&decoded).ok()?;
    json.get("sub")?.as_str().map(ToOwned::to_owned)
}

/// Decide whether an ordered collaboration snapshot can replace local state.
#[frb(sync)]
pub fn collaboration_snapshot_is_stale(
    last_epoch: Option<String>,
    last_revision: Option<i64>,
    incoming_epoch: String,
    incoming_revision: i64,
) -> bool {
    last_epoch.as_deref() == Some(incoming_epoch.as_str())
        && last_revision.is_some_and(|revision| incoming_revision <= revision)
}

/// Normalize a user-entered task title exactly once in the domain core.
#[frb(sync)]
pub fn normalize_task_title(title: String) -> String {
    let trimmed = dart_trim(&title);
    if trimmed.is_empty() {
        "Untitled task".to_owned()
    } else {
        trimmed.to_owned()
    }
}

/// Canonical persisted note title used by autosave and close fallback.
#[frb(sync)]
pub fn normalize_note_title(title: String) -> String {
    let trimmed = dart_trim(&title);
    if trimmed.is_empty() {
        "Untitled".to_owned()
    } else {
        trimmed.to_owned()
    }
}

#[frb(sync)]
pub fn note_draft_is_empty(title: String, content: String) -> bool {
    dart_trim(&title).is_empty() && dart_trim(&content).is_empty()
}

#[frb(sync)]
pub fn note_share_text(title: String, content: String) -> String {
    if title.is_empty() || title == "Untitled" {
        content
    } else {
        format!("{title}\n\n{content}")
    }
}

#[frb(sync)]
pub fn parse_tag_names(raw: String) -> Vec<String> {
    let mut names = Vec::new();
    let mut seen = HashSet::new();
    for part in raw.split(',') {
        let name = dart_trim(part);
        if !name.is_empty() && seen.insert(name.to_owned()) {
            names.push(name.to_owned());
        }
    }
    names
}

#[frb(sync)]
pub fn sanitize_single_export_stem(title: String) -> String {
    let source = if title == "Untitled" { "note" } else { &title };
    let mut output = String::new();
    let mut whitespace = false;
    for character in source.chars() {
        let allowed = character.is_ascii_alphanumeric()
            || character == '-'
            || character == '_'
            || is_dart_regexp_whitespace(character);
        if !allowed {
            continue;
        }
        if is_dart_regexp_whitespace(character) {
            if !whitespace {
                output.push('_');
                whitespace = true;
            }
        } else {
            output.push(character);
            whitespace = false;
        }
    }
    if output.is_empty() {
        "note".to_owned()
    } else {
        output
    }
}

/// Clamp imported timestamps so a bogus future date cannot win LWW forever.
#[frb(sync)]
pub fn clamp_imported_timestamp_micros(timestamp_micros_utc: i64, now_micros_utc: i64) -> i64 {
    timestamp_micros_utc.min(now_micros_utc)
}

/// Tag sync deliberately lets the server win an exact timestamp tie.
#[frb(sync)]
pub fn remote_timestamp_wins_equal(
    local_timestamp_micros_utc: i64,
    remote_timestamp_micros_utc: i64,
) -> bool {
    remote_timestamp_micros_utc >= local_timestamp_micros_utc
}

/// Exponential scheduler backoff capped after ten shifts and at `max_millis`.
#[frb(sync)]
pub fn sync_backoff_millis(consecutive_failures: i32, base_millis: i64, max_millis: i64) -> i64 {
    if consecutive_failures <= 0 || base_millis <= 0 || max_millis <= 0 {
        return 0;
    }
    let shift = u32::try_from((consecutive_failures - 1).min(10)).unwrap_or(0);
    base_millis.saturating_mul(1_i64 << shift).min(max_millis)
}

/// Summarize durable payload fields and the update rows that supplied them.
#[frb(sync)]
pub fn summarize_pending_outbox(rows: Vec<PendingOutboxRowInput>) -> PendingOutboxSummaryOutput {
    let mut fields = Vec::new();
    let mut seen_fields = HashSet::new();
    let mut seqs_by_field: HashMap<String, Vec<i64>> = HashMap::new();
    for row in rows {
        let Ok(Value::Object(data)) = serde_json::from_str::<Value>(&row.data_json) else {
            if seen_fields.insert("*".to_owned()) {
                fields.push("*".to_owned());
            }
            continue;
        };
        for field in data.keys() {
            if seen_fields.insert(field.clone()) {
                fields.push(field.clone());
            }
            if row.action == "update" {
                seqs_by_field
                    .entry(field.clone())
                    .or_default()
                    .push(row.seq);
            }
        }
    }
    let update_seqs_by_field = fields
        .iter()
        .filter_map(|field| {
            seqs_by_field
                .remove(field)
                .map(|seqs| PendingOutboxFieldSeqs {
                    field: field.clone(),
                    seqs,
                })
        })
        .collect();
    PendingOutboxSummaryOutput {
        fields,
        update_seqs_by_field,
    }
}

/// Remove one acknowledged field and its field clock from an update payload.
#[frb(sync)]
pub fn retire_acknowledged_outbox_field(
    data_json: String,
    field: String,
) -> OutboxRetirementOutput {
    let Ok(Value::Object(mut data)) = serde_json::from_str::<Value>(&data_json) else {
        return OutboxRetirementOutput {
            changed: false,
            delete_row: false,
            data_json,
        };
    };
    if data.remove(&field).is_none() {
        return OutboxRetirementOutput {
            changed: false,
            delete_row: false,
            data_json,
        };
    }
    if let Some(Value::Object(clocks)) = data.get_mut("field_clocks") {
        clocks.remove(&field);
        if clocks.is_empty() {
            data.remove("field_clocks");
        }
    }
    let delete_row = data.is_empty();
    OutboxRetirementOutput {
        changed: true,
        delete_row,
        data_json: if delete_row {
            String::new()
        } else {
            serde_json::to_string(&data).unwrap_or(data_json)
        },
    }
}

/// Resolve complete notebook paths while tolerating missing parents and cycles.
#[frb(sync)]
pub fn resolve_notebook_paths(nodes: Vec<NotebookNodeInput>) -> Vec<NotebookPathOutput> {
    let by_id: HashMap<String, NotebookNodeInput> = nodes
        .iter()
        .cloned()
        .map(|node| (node.id.clone(), node))
        .collect();
    let mut memo: HashMap<String, Vec<String>> = HashMap::new();

    fn resolve(
        node: &NotebookNodeInput,
        by_id: &HashMap<String, NotebookNodeInput>,
        memo: &mut HashMap<String, Vec<String>>,
        visiting: &mut HashSet<String>,
    ) -> Vec<String> {
        if let Some(cached) = memo.get(&node.id) {
            return cached.clone();
        }
        if !visiting.insert(node.id.clone()) {
            return vec![node.name.clone()];
        }
        let path = match node.parent_id.as_ref().and_then(|id| by_id.get(id)) {
            Some(parent) => {
                let mut path = resolve(parent, by_id, memo, visiting);
                path.push(node.name.clone());
                path
            }
            None => vec![node.name.clone()],
        };
        visiting.remove(&node.id);
        memo.insert(node.id.clone(), path.clone());
        path
    }

    nodes
        .iter()
        .map(|node| {
            let path = resolve(node, &by_id, &mut memo, &mut HashSet::new());
            NotebookPathOutput {
                id: node.id.clone(),
                path_key: notebook_path_key_slice(&path),
                path,
            }
        })
        .collect()
}

/// Include each selected note's notebook and every reachable ancestor.
#[frb(sync)]
pub fn select_export_notebook_ids(
    note_notebook_ids: Vec<String>,
    nodes: Vec<NotebookNodeInput>,
) -> Vec<String> {
    let by_id: HashMap<String, NotebookNodeInput> = nodes
        .iter()
        .cloned()
        .map(|node| (node.id.clone(), node))
        .collect();
    let mut selected = HashSet::new();
    for start in note_notebook_ids {
        let mut current = Some(start);
        while let Some(id) = current {
            if !selected.insert(id.clone()) {
                break;
            }
            current = by_id.get(&id).and_then(|node| node.parent_id.clone());
        }
    }
    nodes
        .into_iter()
        .filter(|node| selected.contains(&node.id))
        .map(|node| node.id)
        .collect()
}

#[frb(sync)]
pub fn notebook_path_key(path: Vec<String>) -> String {
    notebook_path_key_slice(&path)
}

fn notebook_path_key_slice(path: &[String]) -> String {
    path.iter()
        .map(|part| format!("{}:{part}", part.encode_utf16().count()))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plans_legacy_ack_all_and_retry_rounds() {
        let entries = vec![
            SyncBatchEntryInput {
                seq: 1,
                entity_type: "note".to_owned(),
                entity_id: "a".to_owned(),
            },
            SyncBatchEntryInput {
                seq: 2,
                entity_type: "task".to_owned(),
                entity_id: "b".to_owned(),
            },
        ];
        let plan = plan_sync_settlement(entries.clone(), vec![], false, 2, vec![1, 2], 0);
        assert_eq!(plan.acked_seqs, vec![1, 2]);
        assert!(plan.continue_draining);
        assert_eq!(plan.pulled_count, 3);

        let retry = plan_sync_settlement(entries, vec!["a".to_owned()], false, 2, vec![], 0);
        assert_eq!(retry.acked_seqs, vec![1]);
        assert_eq!(retry.retry_seqs, vec![2]);
        assert!(!retry.continue_draining);
    }

    #[test]
    fn logical_timestamp_moves_one_millisecond_past_previous() {
        assert_eq!(next_logical_timestamp_micros(4_000, Some(5_000)), 6_000);
        assert_eq!(next_logical_timestamp_micros(6_001, Some(5_000)), 6_001);
    }

    #[test]
    fn caps_exponential_sync_backoff() {
        assert_eq!(sync_backoff_millis(1, 1_000, 60_000), 1_000);
        assert_eq!(sync_backoff_millis(3, 1_000, 60_000), 4_000);
        assert_eq!(sync_backoff_millis(99, 1_000, 60_000), 60_000);
    }

    #[test]
    fn summarizes_and_retires_outbox_fields() {
        let summary = summarize_pending_outbox(vec![
            PendingOutboxRowInput {
                seq: 7,
                action: "update".to_owned(),
                data_json: r#"{"title":"a","field_clocks":{"title":{}}}"#.to_owned(),
            },
            PendingOutboxRowInput {
                seq: 8,
                action: "delete".to_owned(),
                data_json: "broken".to_owned(),
            },
        ]);
        assert!(summary.fields.contains(&"title".to_owned()));
        assert!(summary.fields.contains(&"*".to_owned()));
        assert_eq!(summary.update_seqs_by_field[0].seqs, vec![7]);

        let retired = retire_acknowledged_outbox_field(
            r#"{"title":"a","tags":["x"],"field_clocks":{"title":{},"tags":{}}}"#.to_owned(),
            "title".to_owned(),
        );
        assert!(retired.changed);
        assert!(!retired.delete_row);
        let value: Value = serde_json::from_str(&retired.data_json).expect("valid JSON");
        assert!(value.get("title").is_none());
        assert!(value["field_clocks"].get("title").is_none());
        assert!(value.get("tags").is_some());
    }

    #[test]
    fn resolves_paths_and_selects_ancestors() {
        let nodes = vec![
            NotebookNodeInput {
                id: "root".to_owned(),
                name: "Work".to_owned(),
                parent_id: None,
            },
            NotebookNodeInput {
                id: "leaf".to_owned(),
                name: "Projects".to_owned(),
                parent_id: Some("root".to_owned()),
            },
        ];
        let paths = resolve_notebook_paths(nodes.clone());
        assert_eq!(paths[1].path, vec!["Work", "Projects"]);
        assert_eq!(paths[1].path_key, "4:Work8:Projects");
        assert_eq!(
            select_export_notebook_ids(vec!["leaf".to_owned()], nodes),
            vec!["root", "leaf"]
        );
    }

    #[test]
    fn refreshes_malformed_or_expiring_tokens() {
        assert!(token_needs_refresh("bad".to_owned(), 100));
        let token = "x.eyJleHAiOjE2MX0.y".to_owned();
        assert!(token_needs_refresh(token.clone(), 101));
        assert!(!token_needs_refresh(token, 100));
    }

    #[test]
    fn title_draft_tag_and_filename_policies_match_dart_bom_whitespace() {
        let bom = "\u{feff}";
        assert_eq!(normalize_task_title(bom.to_owned()), "Untitled task");
        assert_eq!(normalize_note_title(bom.to_owned()), "Untitled");
        assert!(note_draft_is_empty(bom.to_owned(), "\u{0085}".to_owned()));
        assert_eq!(
            note_share_text(bom.to_owned(), bom.to_owned()),
            format!("{bom}\n\n{bom}")
        );
        assert_eq!(
            parse_tag_names("\u{feff}work\u{feff}, \u{0085}ideas\u{0085}".to_owned()),
            vec!["work", "ideas"]
        );
        assert_eq!(
            sanitize_single_export_stem("\u{feff}A\u{0085}B\u{feff}".to_owned()),
            "_AB_"
        );
    }
}
