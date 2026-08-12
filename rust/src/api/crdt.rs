use std::cmp::Ordering;
use std::collections::HashMap;

use flutter_rust_bridge::frb;

/// A normalized LWW register clock passed across the Dart/Rust boundary.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CrdtClockInput {
    /// UTC microseconds since Unix epoch. Dart normalizes DateTime before this.
    pub timestamp_micros_utc: i64,
    pub device_id: String,
}

/// One known entity field and the two clocks competing for that field.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CrdtFieldInput {
    pub field: String,
    pub local: CrdtClockInput,
    pub remote: CrdtClockInput,
    /// Live collaboration can protect title/body from whole-document sync.
    pub excluded: bool,
}

/// A named clock used when Dart needs Rust to update a complete clock map.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NamedCrdtClockInput {
    pub field: String,
    pub clock: CrdtClockInput,
}

/// Return fields for which the remote LWW register strictly wins.
///
/// The input order is retained so Dart gets deterministic model reconstruction.
/// Equal clocks keep the local value. Device ids are compared as UTF-16 code
/// units to exactly match Dart's `String.compareTo`, including non-ASCII ids.
#[frb(sync)]
pub fn remote_winning_fields(inputs: Vec<CrdtFieldInput>) -> Vec<String> {
    inputs
        .into_iter()
        .filter(|input| !input.excluded && compare_clock(&input.remote, &input.local).is_gt())
        .map(|input| input.field)
        .collect()
}

/// Stamp selected registers while retaining unknown clocks and map order.
///
/// Existing fields remain at their current position. Newly introduced fields
/// are appended in the order supplied by Dart's insertion-ordered set.
#[frb(sync)]
pub fn stamp_crdt_fields(
    mut existing: Vec<NamedCrdtClockInput>,
    fields: Vec<String>,
    timestamp_micros_utc: i64,
    device_id: String,
) -> Vec<NamedCrdtClockInput> {
    let mut positions: HashMap<String, usize> = existing
        .iter()
        .enumerate()
        .map(|(index, item)| (item.field.clone(), index))
        .collect();

    for field in fields {
        let stamped = NamedCrdtClockInput {
            field: field.clone(),
            clock: CrdtClockInput {
                timestamp_micros_utc,
                device_id: device_id.clone(),
            },
        };
        if let Some(index) = positions.get(&field).copied() {
            existing[index] = stamped;
        } else {
            positions.insert(field, existing.len());
            existing.push(stamped);
        }
    }
    existing
}

fn compare_clock(left: &CrdtClockInput, right: &CrdtClockInput) -> Ordering {
    left.timestamp_micros_utc
        .cmp(&right.timestamp_micros_utc)
        .then_with(|| compare_utf16(&left.device_id, &right.device_id))
}

fn compare_utf16(left: &str, right: &str) -> Ordering {
    left.encode_utf16().cmp(right.encode_utf16())
}

#[frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

#[cfg(test)]
mod tests {
    use super::*;

    fn clock(timestamp_micros_utc: i64, device_id: &str) -> CrdtClockInput {
        CrdtClockInput {
            timestamp_micros_utc,
            device_id: device_id.to_owned(),
        }
    }

    fn field(name: &str, local: CrdtClockInput, remote: CrdtClockInput) -> CrdtFieldInput {
        CrdtFieldInput {
            field: name.to_owned(),
            local,
            remote,
            excluded: false,
        }
    }

    #[test]
    fn newer_timestamp_wins_and_ties_stay_local() {
        let winners = remote_winning_fields(vec![
            field("newer", clock(10, "a"), clock(11, "a")),
            field("older", clock(10, "a"), clock(9, "z")),
            field("tie", clock(10, "a"), clock(10, "a")),
        ]);

        assert_eq!(winners, vec!["newer"]);
    }

    #[test]
    fn device_id_breaks_equal_timestamp_ties() {
        let winners = remote_winning_fields(vec![
            field("remote", clock(10, "device-a"), clock(10, "device-b")),
            field("local", clock(10, "device-b"), clock(10, "device-a")),
        ]);

        assert_eq!(winners, vec!["remote"]);
    }

    #[test]
    fn exclusions_never_win() {
        let mut protected = field("content", clock(1, "a"), clock(2, "b"));
        protected.excluded = true;

        assert!(remote_winning_fields(vec![protected]).is_empty());
    }

    #[test]
    fn compares_non_ascii_ids_like_utf16_not_utf8() {
        // U+10000 is a surrogate pair starting at 0xD800; U+E000 is one code
        // unit. UTF-8 orders these the other way around, so this catches drift.
        let supplementary = "\u{10000}";
        let private_use = "\u{e000}";
        assert_eq!(compare_utf16(supplementary, private_use), Ordering::Less);

        let winners = remote_winning_fields(vec![field(
            "unicode",
            clock(10, supplementary),
            clock(10, private_use),
        )]);
        assert_eq!(winners, vec!["unicode"]);
    }

    #[test]
    fn stamping_preserves_unknown_clocks_and_insertion_order() {
        let stamped = stamp_crdt_fields(
            vec![
                NamedCrdtClockInput {
                    field: "unknown".to_owned(),
                    clock: clock(1, "old"),
                },
                NamedCrdtClockInput {
                    field: "title".to_owned(),
                    clock: clock(2, "old"),
                },
            ],
            vec!["title".to_owned(), "content".to_owned()],
            99,
            "phone".to_owned(),
        );

        assert_eq!(
            stamped
                .iter()
                .map(|entry| entry.field.as_str())
                .collect::<Vec<_>>(),
            vec!["unknown", "title", "content"]
        );
        assert_eq!(stamped[0].clock, clock(1, "old"));
        assert_eq!(stamped[1].clock, clock(99, "phone"));
        assert_eq!(stamped[2].clock, clock(99, "phone"));
    }
}
