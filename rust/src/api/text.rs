use dissimilar::Chunk;
use flutter_rust_bridge::frb;

const MAX_COMPONENTS: usize = 1_000;
const MAX_INSERTED_UNITS: usize = 100_000;
const MAX_COMPONENT_UNITS: usize = 2_000_000;

/// One plain-text Quill delta component. Exactly one field is populated.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TextDeltaOp {
    pub retain: Option<i32>,
    pub delete: Option<i32>,
    pub insert: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TextOperationResult {
    pub value: String,
    pub error: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum Op {
    Retain(usize),
    Delete(usize),
    Insert(String),
}

impl Op {
    fn len_utf16(&self) -> usize {
        match self {
            Self::Retain(length) | Self::Delete(length) => *length,
            Self::Insert(text) => text.encode_utf16().count(),
        }
    }
}

/// Diff two documents into normalized Quill operations using a semantic
/// diff-match-patch implementation. Operation lengths are UTF-16 code units.
#[frb(sync)]
pub fn plain_text_diff(before: String, after: String) -> Vec<TextDeltaOp> {
    if before == after {
        return Vec::new();
    }
    let mut operations = Vec::new();
    for chunk in dissimilar::diff(&before, &after) {
        match chunk {
            Chunk::Equal(text) => push_op(&mut operations, Op::Retain(utf16_len(text))),
            Chunk::Delete(text) => push_op(&mut operations, Op::Delete(utf16_len(text))),
            Chunk::Insert(text) => push_op(&mut operations, Op::Insert(text.to_owned())),
        }
    }
    trim_trailing_retain(&mut operations);
    to_public(operations)
}

/// Apply a plain-text delta, rejecting malformed/out-of-bounds UTF-16 edits.
#[frb(sync)]
pub fn apply_plain_text_delta(text: String, operations: Vec<TextDeltaOp>) -> TextOperationResult {
    run_text_operation(|| {
        let operations = parse_public(operations)?;
        apply_ops(&text, &operations)
    })
}

/// Rebase local text over a newly committed canonical document.
#[frb(sync)]
pub fn rebase_plain_text(
    old_server: String,
    new_server: String,
    local: String,
    server_change: Option<Vec<TextDeltaOp>>,
) -> TextOperationResult {
    run_text_operation(|| {
        if local == old_server {
            return Ok(new_server);
        }
        let local_change = parse_public(plain_text_diff(old_server.clone(), local))?;
        let canonical_change = match server_change {
            Some(operations) => parse_public(operations)?,
            None => parse_public(plain_text_diff(old_server, new_server.clone()))?,
        };
        let transformed = transform_ops(&canonical_change, &local_change, true)?;
        apply_ops(&new_server, &transformed)
    })
}

/// Transform editor selection endpoints through the same UTF-16 diff used for
/// the remote replacement. Negative endpoints move to the end, matching Dart.
#[frb(sync)]
pub fn transform_text_positions(before: String, after: String, positions: Vec<i32>) -> Vec<i32> {
    let operations = parse_public(plain_text_diff(before, after.clone())).unwrap_or_default();
    let limit = utf16_len(&after);
    positions
        .into_iter()
        .map(|position| {
            if position < 0 {
                return i32::try_from(limit).unwrap_or(i32::MAX);
            }
            let mut index = usize::try_from(position).unwrap_or(limit);
            let mut offset = 0usize;
            for operation in &operations {
                if offset > index {
                    break;
                }
                match operation {
                    Op::Delete(length) => {
                        index = index.saturating_sub((*length).min(index.saturating_sub(offset)));
                        continue;
                    }
                    Op::Insert(text) => {
                        let length = utf16_len(text);
                        if offset <= index {
                            index = index.saturating_add(length);
                        }
                        offset = offset.saturating_add(length);
                    }
                    Op::Retain(length) => offset = offset.saturating_add(*length),
                }
            }
            i32::try_from(index.min(limit)).unwrap_or(i32::MAX)
        })
        .collect()
}

fn run_text_operation(operation: impl FnOnce() -> Result<String, String>) -> TextOperationResult {
    match operation() {
        Ok(value) => TextOperationResult { value, error: None },
        Err(error) => TextOperationResult {
            value: String::new(),
            error: Some(error),
        },
    }
}

fn utf16_len(text: &str) -> usize {
    text.encode_utf16().count()
}

fn parse_public(operations: Vec<TextDeltaOp>) -> Result<Vec<Op>, String> {
    if operations.len() > MAX_COMPONENTS {
        return Err("Collaboration delta has too many components".to_owned());
    }
    let mut parsed = Vec::new();
    let mut inserted_units = 0usize;
    for operation in operations {
        // Match the existing Dart application precedence for malformed maps.
        let item = if let Some(length) = operation.retain {
            Op::Retain(valid_count(length)?)
        } else if let Some(length) = operation.delete {
            Op::Delete(valid_count(length)?)
        } else if let Some(text) = operation.insert {
            inserted_units = inserted_units.saturating_add(utf16_len(&text));
            if inserted_units > MAX_INSERTED_UNITS {
                return Err("Collaboration delta inserts too much text".to_owned());
            }
            Op::Insert(text)
        } else {
            return Err("Unsupported collaboration delta".to_owned());
        };
        push_op(&mut parsed, item);
    }
    Ok(parsed)
}

fn valid_count(length: i32) -> Result<usize, String> {
    let length = usize::try_from(length)
        .map_err(|_| "Collaboration delta lengths cannot be negative".to_owned())?;
    if length > MAX_COMPONENT_UNITS {
        return Err("Collaboration delta component is too large".to_owned());
    }
    Ok(length)
}

fn to_public(operations: Vec<Op>) -> Vec<TextDeltaOp> {
    operations
        .into_iter()
        .map(|operation| match operation {
            Op::Retain(length) => TextDeltaOp {
                retain: Some(i32::try_from(length).unwrap_or(i32::MAX)),
                delete: None,
                insert: None,
            },
            Op::Delete(length) => TextDeltaOp {
                retain: None,
                delete: Some(i32::try_from(length).unwrap_or(i32::MAX)),
                insert: None,
            },
            Op::Insert(text) => TextDeltaOp {
                retain: None,
                delete: None,
                insert: Some(text),
            },
        })
        .collect()
}

fn push_op(operations: &mut Vec<Op>, operation: Op) {
    if operation.len_utf16() == 0 {
        return;
    }
    match (operations.last_mut(), operation) {
        (Some(Op::Delete(previous)), Op::Delete(length)) => {
            *previous = previous.saturating_add(length);
        }
        (Some(Op::Insert(previous)), Op::Insert(text)) => previous.push_str(&text),
        (Some(Op::Retain(previous)), Op::Retain(length)) => {
            *previous = previous.saturating_add(length);
        }
        (Some(Op::Delete(_)), Op::Insert(text)) => {
            let index = operations.len() - 1;
            operations.insert(index, Op::Insert(text));
        }
        (_, operation) => operations.push(operation),
    }
}

fn trim_trailing_retain(operations: &mut Vec<Op>) {
    if matches!(operations.last(), Some(Op::Retain(_))) {
        operations.pop();
    }
}

fn apply_ops(text: &str, operations: &[Op]) -> Result<String, String> {
    let source: Vec<u16> = text.encode_utf16().collect();
    let mut cursor = 0usize;
    let mut output = Vec::with_capacity(source.len());
    for operation in operations {
        match operation {
            Op::Retain(length) => {
                let end = cursor
                    .checked_add(*length)
                    .filter(|end| *end <= source.len())
                    .ok_or_else(|| "Collaboration retain exceeds document length".to_owned())?;
                ensure_utf16_boundary(&source, cursor)?;
                ensure_utf16_boundary(&source, end)?;
                output.extend_from_slice(&source[cursor..end]);
                cursor = end;
            }
            Op::Delete(length) => {
                let end = cursor
                    .checked_add(*length)
                    .filter(|end| *end <= source.len())
                    .ok_or_else(|| "Collaboration delete exceeds document length".to_owned())?;
                ensure_utf16_boundary(&source, cursor)?;
                ensure_utf16_boundary(&source, end)?;
                cursor = end;
            }
            Op::Insert(value) => output.extend(value.encode_utf16()),
        }
    }
    ensure_utf16_boundary(&source, cursor)?;
    output.extend_from_slice(&source[cursor..]);
    String::from_utf16(&output).map_err(|_| "Collaboration delta split a surrogate pair".to_owned())
}

fn ensure_utf16_boundary(text: &[u16], index: usize) -> Result<(), String> {
    if index > 0
        && index < text.len()
        && (0xD800..=0xDBFF).contains(&text[index - 1])
        && (0xDC00..=0xDFFF).contains(&text[index])
    {
        Err("Collaboration delta split a surrogate pair".to_owned())
    } else {
        Ok(())
    }
}

#[derive(Clone)]
struct OpIterator<'a> {
    operations: &'a [Op],
    index: usize,
    offset: usize,
}

impl<'a> OpIterator<'a> {
    fn new(operations: &'a [Op]) -> Self {
        Self {
            operations,
            index: 0,
            offset: 0,
        }
    }

    fn has_next(&self) -> bool {
        self.index < self.operations.len()
    }

    fn next_is_insert(&self) -> bool {
        matches!(self.operations.get(self.index), Some(Op::Insert(_)))
    }

    fn peek_length(&self) -> usize {
        self.operations
            .get(self.index)
            .map_or(usize::MAX / 4, |operation| {
                operation.len_utf16() - self.offset
            })
    }

    fn next(&mut self, requested: usize) -> Result<Op, String> {
        let Some(operation) = self.operations.get(self.index) else {
            return Ok(Op::Retain(requested));
        };
        let available = operation.len_utf16() - self.offset;
        let actual = available.min(requested);
        let result = match operation {
            Op::Retain(_) => Op::Retain(actual),
            Op::Delete(_) => Op::Delete(actual),
            Op::Insert(text) => Op::Insert(utf16_substring(text, self.offset, actual)?),
        };
        if actual == available {
            self.index += 1;
            self.offset = 0;
        } else {
            self.offset += actual;
        }
        Ok(result)
    }
}

fn utf16_substring(text: &str, start: usize, length: usize) -> Result<String, String> {
    let units: Vec<u16> = text.encode_utf16().collect();
    let end = start
        .checked_add(length)
        .filter(|end| *end <= units.len())
        .ok_or_else(|| "Collaboration insert slice is out of bounds".to_owned())?;
    ensure_utf16_boundary(&units, start)?;
    ensure_utf16_boundary(&units, end)?;
    String::from_utf16(&units[start..end])
        .map_err(|_| "Collaboration delta split a surrogate pair".to_owned())
}

fn transform_ops(applied: &[Op], incoming: &[Op], priority: bool) -> Result<Vec<Op>, String> {
    let mut result = Vec::new();
    let mut applied_iter = OpIterator::new(applied);
    let mut incoming_iter = OpIterator::new(incoming);
    while applied_iter.has_next() || incoming_iter.has_next() {
        if applied_iter.next_is_insert() && (priority || !incoming_iter.next_is_insert()) {
            let length = applied_iter.peek_length();
            let _ = applied_iter.next(length)?;
            push_op(&mut result, Op::Retain(length));
            continue;
        }
        if incoming_iter.next_is_insert() {
            let length = incoming_iter.peek_length();
            push_op(&mut result, incoming_iter.next(length)?);
            continue;
        }

        let length = applied_iter.peek_length().min(incoming_iter.peek_length());
        let applied_operation = applied_iter.next(length)?;
        let incoming_operation = incoming_iter.next(length)?;
        if matches!(applied_operation, Op::Delete(_)) {
            continue;
        }
        if matches!(incoming_operation, Op::Delete(_)) {
            push_op(&mut result, incoming_operation);
        } else {
            push_op(&mut result, Op::Retain(length));
        }
    }
    trim_trailing_retain(&mut result);
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn success(result: TextOperationResult) -> String {
        assert_eq!(result.error, None);
        result.value
    }

    #[test]
    fn diff_round_trips_plain_text() {
        let before = "alpha beta gamma".to_owned();
        let after = "ALPHA beta delta".to_owned();
        let delta = plain_text_diff(before.clone(), after.clone());
        assert_eq!(success(apply_plain_text_delta(before, delta)), after);
    }

    #[test]
    fn server_insert_has_priority_during_rebase() {
        let rebased = rebase_plain_text("ab".to_owned(), "aSb".to_owned(), "aLb".to_owned(), None);
        assert_eq!(success(rebased), "aSLb");
    }

    #[test]
    fn uses_utf16_lengths_and_rejects_surrogate_splits() {
        let delta = plain_text_diff("A😀B".to_owned(), "AB".to_owned());
        assert_eq!(
            delta,
            vec![
                TextDeltaOp {
                    retain: Some(1),
                    delete: None,
                    insert: None,
                },
                TextDeltaOp {
                    retain: None,
                    delete: Some(2),
                    insert: None,
                },
            ]
        );
        let invalid = apply_plain_text_delta(
            "A😀B".to_owned(),
            vec![TextDeltaOp {
                retain: Some(2),
                delete: None,
                insert: None,
            }],
        );
        assert!(invalid.error.is_some());
    }

    #[test]
    fn rejects_out_of_bounds_operations_without_panicking() {
        let result = apply_plain_text_delta(
            "short".to_owned(),
            vec![TextDeltaOp {
                retain: Some(99),
                delete: None,
                insert: None,
            }],
        );
        assert!(result.error.is_some());
    }
}
