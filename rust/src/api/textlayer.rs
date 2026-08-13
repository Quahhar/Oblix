//! Keeping the page after the words have been taken off it.
//!
//! Shaping a scan into a note throws away everything except the prose: the
//! boxes, the confidences, the page size. That is a lot to lose, because
//! almost everything a scan could go on to do needs to know *where* a word was
//! — searching a photograph and highlighting the hit, selecting text off the
//! image, copying one region of a form, re-reading a page as two columns after
//! deciding it was one, noticing that this receipt has been scanned before.
//!
//! A text layer is that geometry, in a form small enough to store beside the
//! image and stable enough to still be readable in a year. It is deliberately
//! independent of [`crate::api::ocr`]'s reconstruction: the layer records what
//! the recognizer saw, not what the reconstruction concluded, so a better
//! reconstruction later can be run over an old scan without the original
//! photograph.
//!
//! The encoding is JSON with the lines as flat arrays rather than objects,
//! which keeps a dense page to a few tens of kilobytes — trivial next to the
//! JPEG it accompanies — while staying readable when something goes wrong.

use std::fmt;

use flutter_rust_bridge::frb;
use serde_json::{json, Value};

use crate::api::ocr::{OcrLineInput, OcrPageInput, OcrWordInput};
use crate::dart_string::{dart_trim, is_dart_regexp_whitespace};

/// Bumped only for a change that older readers could not understand. New
/// optional trailing fields do not need it.
const FORMAT_VERSION: i64 = 1;

/// Guards against a malformed or hostile blob turning into an allocation
/// storm. A 10-page dense scan is around 5000 lines.
const MAX_PAGES: usize = 2_000;
const MAX_LINES: usize = 500_000;
/// Words on one line are bounded separately: [MAX_LINES] says nothing about
/// how long a single line's word array claims to be.
const MAX_WORDS_PER_LINE: usize = 512;

/// Words of this length or shorter are ignored when fingerprinting, so that
/// "the" and "of" do not dominate the comparison.
const MIN_SHINGLE_UNITS: usize = 3;

/// Hamming distance between two 64-bit fingerprints below which two scans are
/// called the same document. Around a tenth of the bits.
const DUPLICATE_DISTANCE: i32 = 6;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TextLayerErrorKind {
    InvalidJson,
    UnsupportedVersion,
    InvalidShape,
    LimitExceeded,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TextLayerError {
    pub kind: TextLayerErrorKind,
    pub message: String,
}

impl TextLayerError {
    fn new(kind: TextLayerErrorKind, message: impl Into<String>) -> Self {
        Self {
            kind,
            message: message.into(),
        }
    }
}

impl fmt::Display for TextLayerError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for TextLayerError {}

/// Internal only. Public signatures spell the result out, because the bridge
/// generator resolves types by name and cannot see through a private alias.
type LayerResult<T> = Result<T, TextLayerError>;

/// One recognized word inside a line, where the recognizer reported them.
#[derive(Clone, Debug, PartialEq)]
pub struct TextLayerWord {
    pub text: String,
    pub left: f32,
    pub top: f32,
    pub right: f32,
    pub bottom: f32,
}

/// One recognized line, exactly as the recognizer reported it.
#[derive(Clone, Debug, PartialEq)]
pub struct TextLayerLine {
    pub text: String,
    pub left: f32,
    pub top: f32,
    pub right: f32,
    pub bottom: f32,
    pub confidence: Option<f32>,
    /// Word boxes, empty when the source did not break the line down. Stored
    /// because a highlight interpolated along a line is only ever an estimate,
    /// and these are the real thing.
    pub words: Vec<TextLayerWord>,
}

/// One page of the capture.
#[derive(Clone, Debug, PartialEq)]
pub struct TextLayerPage {
    /// Source pixel size, needed to map a box onto the image as displayed.
    pub width: f32,
    pub height: f32,
    pub lines: Vec<TextLayerLine>,
}

/// Everything recognized in one capture.
#[derive(Clone, Debug, PartialEq)]
pub struct TextLayer {
    /// Where the pages came from: `camera`, `document`, `gallery`, `pdf`.
    /// Free-form, recorded so a later re-read knows what it is dealing with.
    pub source: String,
    pub pages: Vec<TextLayerPage>,
}

/// One place a query matched.
#[derive(Clone, Debug, PartialEq)]
pub struct TextLayerHit {
    pub page: i32,
    /// Index of the line within its page.
    pub line: i32,
    /// The whole line, for showing context around the hit.
    pub text: String,
    /// Box around the matched words, narrowed from the line's own box.
    pub left: f32,
    pub top: f32,
    pub right: f32,
    pub bottom: f32,
}

// --- Building -------------------------------------------------------------

/// Capture the recognizer's output as a layer, before any reconstruction.
#[frb(sync)]
pub fn build_text_layer(pages: Vec<OcrPageInput>, source: String) -> TextLayer {
    TextLayer {
        source,
        pages: pages
            .into_iter()
            .map(|page| TextLayerPage {
                width: page.width,
                height: page.height,
                lines: page
                    .lines
                    .into_iter()
                    .map(|line| TextLayerLine {
                        text: line.text,
                        left: line.left,
                        top: line.top,
                        right: line.right,
                        bottom: line.bottom,
                        confidence: line.confidence,
                        words: line
                            .words
                            .into_iter()
                            .map(|word| TextLayerWord {
                                text: word.text,
                                left: word.left,
                                top: word.top,
                                right: word.right,
                                bottom: word.bottom,
                            })
                            .collect(),
                    })
                    .collect(),
            })
            .collect(),
    }
}

/// Feed a stored layer back into reconstruction, so a page can be re-read with
/// different options without the original image.
#[frb(sync)]
pub fn text_layer_to_pages(layer: TextLayer) -> Vec<OcrPageInput> {
    layer
        .pages
        .into_iter()
        .map(|page| OcrPageInput {
            width: page.width,
            height: page.height,
            lines: page
                .lines
                .into_iter()
                .map(|line| OcrLineInput {
                    text: line.text,
                    left: line.left,
                    top: line.top,
                    right: line.right,
                    bottom: line.bottom,
                    // Block grouping is not preserved: reconstruction works
                    // off geometry, and a stale grouping would only mislead.
                    block_index: 0,
                    confidence: line.confidence,
                    words: line
                        .words
                        .into_iter()
                        .map(|word| OcrWordInput {
                            text: word.text,
                            left: word.left,
                            top: word.top,
                            right: word.right,
                            bottom: word.bottom,
                            // Per-word confidence is not stored: it costs a
                            // number per word to keep and nothing downstream
                            // of a re-read consults it.
                            confidence: None,
                        })
                        .collect(),
                })
                .collect(),
        })
        .collect()
}

// --- Encoding -------------------------------------------------------------

#[frb(sync)]
pub fn encode_text_layer(layer: TextLayer) -> String {
    let pages: Vec<Value> = layer
        .pages
        .iter()
        .map(|page| {
            let lines: Vec<Value> = page
                .lines
                .iter()
                .map(|line| {
                    // A seventh element, so a reader of the older six-element
                    // shape ignores it and a reader of this one finds it —
                    // which is what the format's rule about new trailing
                    // fields is for. Words are omitted entirely when there are
                    // none rather than written as an empty array, keeping a
                    // layer from a source without them byte-identical to what
                    // it encoded before.
                    let mut fields = vec![
                        json!(line.text),
                        json!(round(line.left)),
                        json!(round(line.top)),
                        json!(round(line.right)),
                        json!(round(line.bottom)),
                        json!(line.confidence.map(round2)),
                    ];
                    if !line.words.is_empty() {
                        fields.push(json!(line
                            .words
                            .iter()
                            .map(|word| json!([
                                word.text,
                                round(word.left),
                                round(word.top),
                                round(word.right),
                                round(word.bottom),
                            ]))
                            .collect::<Vec<Value>>()));
                    }
                    Value::Array(fields)
                })
                .collect();
            json!({ "w": round(page.width), "h": round(page.height), "l": lines })
        })
        .collect();
    json!({ "v": FORMAT_VERSION, "src": layer.source, "p": pages }).to_string()
}

/// Pixel positions to a tenth of a pixel — far finer than any recognizer's
/// accuracy, and it keeps the encoded size down.
fn round(value: f32) -> f32 {
    (value * 10.0).round() / 10.0
}

fn round2(value: f32) -> f32 {
    (value * 100.0).round() / 100.0
}

#[frb(sync)]
pub fn decode_text_layer(encoded: String) -> Result<TextLayer, TextLayerError> {
    let root: Value = serde_json::from_str(&encoded)
        .map_err(|error| TextLayerError::new(TextLayerErrorKind::InvalidJson, error.to_string()))?;
    let version = root.get("v").and_then(Value::as_i64).unwrap_or(0);
    if version != FORMAT_VERSION {
        return Err(TextLayerError::new(
            TextLayerErrorKind::UnsupportedVersion,
            format!("text layer version {version} cannot be read"),
        ));
    }
    let source = root
        .get("src")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned();
    let raw_pages = root.get("p").and_then(Value::as_array).ok_or_else(|| {
        TextLayerError::new(TextLayerErrorKind::InvalidShape, "text layer has no pages")
    })?;
    if raw_pages.len() > MAX_PAGES {
        return Err(TextLayerError::new(
            TextLayerErrorKind::LimitExceeded,
            format!("{} pages exceeds the limit of {MAX_PAGES}", raw_pages.len()),
        ));
    }

    let mut total_lines = 0usize;
    let mut pages = Vec::with_capacity(raw_pages.len());
    for raw_page in raw_pages {
        let raw_lines = raw_page.get("l").and_then(Value::as_array).ok_or_else(|| {
            TextLayerError::new(TextLayerErrorKind::InvalidShape, "a page has no lines")
        })?;
        total_lines += raw_lines.len();
        if total_lines > MAX_LINES {
            return Err(TextLayerError::new(
                TextLayerErrorKind::LimitExceeded,
                format!("more than {MAX_LINES} lines"),
            ));
        }
        let mut lines = Vec::with_capacity(raw_lines.len());
        for raw_line in raw_lines {
            lines.push(decode_line(raw_line)?);
        }
        pages.push(TextLayerPage {
            width: number(raw_page.get("w")),
            height: number(raw_page.get("h")),
            lines,
        });
    }
    Ok(TextLayer { source, pages })
}

fn decode_line(raw: &Value) -> LayerResult<TextLayerLine> {
    let fields = raw.as_array().ok_or_else(|| {
        TextLayerError::new(TextLayerErrorKind::InvalidShape, "a line is not an array")
    })?;
    if fields.len() < 5 {
        return Err(TextLayerError::new(
            TextLayerErrorKind::InvalidShape,
            "a line is missing its box",
        ));
    }
    Ok(TextLayerLine {
        text: fields[0].as_str().unwrap_or_default().to_owned(),
        left: number(fields.get(1)),
        top: number(fields.get(2)),
        right: number(fields.get(3)),
        bottom: number(fields.get(4)),
        confidence: fields
            .get(5)
            .and_then(Value::as_f64)
            .map(|value| value as f32),
        // Absent in a layer written before words were stored, and in one whose
        // source never reported them. Both are ordinary, so a missing or
        // malformed seventh field means "no words", never an error.
        words: fields
            .get(6)
            .and_then(Value::as_array)
            .map(|raw| {
                raw.iter()
                    .take(MAX_WORDS_PER_LINE)
                    .filter_map(decode_word)
                    .collect()
            })
            .unwrap_or_default(),
    })
}

fn decode_word(raw: &Value) -> Option<TextLayerWord> {
    let fields = raw.as_array()?;
    if fields.len() < 5 {
        return None;
    }
    Some(TextLayerWord {
        text: fields[0].as_str().unwrap_or_default().to_owned(),
        left: number(fields.get(1)),
        top: number(fields.get(2)),
        right: number(fields.get(3)),
        bottom: number(fields.get(4)),
    })
}

fn number(value: Option<&Value>) -> f32 {
    value.and_then(Value::as_f64).unwrap_or(0.0) as f32
}

// --- Search ---------------------------------------------------------------

/// Everything the layer read, as one string, for the note search index.
///
/// Pages are separated by a blank line so a phrase cannot appear to run across
/// a page boundary that it never crossed.
#[frb(sync)]
pub fn text_layer_search_text(layer: TextLayer) -> String {
    layer
        .pages
        .iter()
        .map(|page| {
            page.lines
                .iter()
                .map(|line| line.text.as_str())
                .collect::<Vec<_>>()
                .join("\n")
        })
        .collect::<Vec<_>>()
        .join("\n\n")
}

/// Find a query in the layer and say where on the page it sat.
///
/// Matching ignores case and treats any run of whitespace as one space, which
/// is what makes a phrase findable when the recognizer padded it out.
///
/// The returned box is narrowed to the matched words. Where the layer carries
/// word boxes the narrowing is exact — the hit is the union of the words it
/// actually covers. Where it does not, the box is interpolated along the line's
/// own extent, which is accurate for even-width text and close enough elsewhere
/// to put a highlight on the right words rather than on the whole line.
#[frb(sync)]
pub fn find_in_text_layer(layer: TextLayer, query: String) -> Vec<TextLayerHit> {
    let needle = normalize(&query);
    if needle.is_empty() {
        return Vec::new();
    }
    let mut hits = Vec::new();
    for (page_index, page) in layer.pages.iter().enumerate() {
        for (line_index, line) in page.lines.iter().enumerate() {
            let haystack = normalize(&line.text);
            let Some(offset) = haystack.find(&needle) else {
                continue;
            };
            let start = haystack[..offset].chars().count();
            let end = start + needle.chars().count();
            let (left, top, right, bottom) = hit_box(line, &haystack, start, end);
            hits.push(TextLayerHit {
                page: page_index as i32,
                line: line_index as i32,
                text: line.text.clone(),
                left,
                top,
                right,
                bottom,
            });
        }
    }
    hits
}

/// The box around the matched characters `start..end` of a line.
///
/// Prefers the union of the word boxes the match actually covers, and falls
/// back to interpolating along the line when the layer has no words — or when
/// they do not spell the line, in which case the character offsets found in
/// the line's text do not address them and snapping would highlight the wrong
/// span with false precision.
fn hit_box(line: &TextLayerLine, haystack: &str, start: usize, end: usize) -> (f32, f32, f32, f32) {
    if let Some(exact) = word_box(line, haystack, start, end) {
        return exact;
    }
    let units = haystack.chars().count().max(1) as f32;
    let width = line.right - line.left;
    let from = (start as f32 / units).clamp(0.0, 1.0);
    let to = (end as f32 / units).clamp(from, 1.0);
    (
        line.left + width * from,
        line.top,
        line.left + width * to,
        line.bottom,
    )
}

fn word_box(
    line: &TextLayerLine,
    haystack: &str,
    start: usize,
    end: usize,
) -> Option<(f32, f32, f32, f32)> {
    if line.words.is_empty() {
        return None;
    }
    let mut spans: Vec<(usize, usize, &TextLayerWord)> = Vec::with_capacity(line.words.len());
    let mut rebuilt = String::with_capacity(line.text.len());
    let mut cursor = 0usize;
    for word in &line.words {
        let text = normalize(&word.text);
        if text.is_empty() {
            continue;
        }
        if cursor > 0 {
            rebuilt.push(' ');
            cursor += 1;
        }
        let from = cursor;
        cursor += text.chars().count();
        rebuilt.push_str(&text);
        spans.push((from, cursor, word));
    }
    if rebuilt != haystack {
        return None;
    }

    let mut bounds: Option<(f32, f32, f32, f32)> = None;
    for (from, to, word) in spans {
        // Half-open overlap, so a match ending exactly where a word begins does
        // not drag that word into the highlight.
        if from >= end || to <= start {
            continue;
        }
        bounds = Some(match bounds {
            None => (word.left, word.top, word.right, word.bottom),
            Some((left, top, right, bottom)) => (
                left.min(word.left),
                top.min(word.top),
                right.max(word.right),
                bottom.max(word.bottom),
            ),
        });
    }
    bounds
}

/// Lower-case, whitespace-collapsed text for matching.
fn normalize(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut in_space = false;
    for character in text.chars() {
        if is_dart_regexp_whitespace(character) {
            if !in_space && !out.is_empty() {
                out.push(' ');
                in_space = true;
            }
        } else {
            out.extend(character.to_lowercase());
            in_space = false;
        }
    }
    dart_trim(&out).to_owned()
}

/// The text inside a rectangle on one page, in reading order.
///
/// Used for copying part of a scan — a single column of a form, one paragraph
/// of a page. A line counts as inside when its centre is, so a box that clips
/// a line's tail does not drag the whole line in.
#[frb(sync)]
pub fn text_layer_region(
    layer: TextLayer,
    page: i32,
    left: f32,
    top: f32,
    right: f32,
    bottom: f32,
) -> String {
    let Some(page) = usize::try_from(page)
        .ok()
        .and_then(|index| layer.pages.get(index))
    else {
        return String::new();
    };
    let mut inside: Vec<&TextLayerLine> = page
        .lines
        .iter()
        .filter(|line| {
            let centre_x = (line.left + line.right) / 2.0;
            let centre_y = (line.top + line.bottom) / 2.0;
            centre_x >= left && centre_x <= right && centre_y >= top && centre_y <= bottom
        })
        .collect();
    inside.sort_by(|a, b| {
        a.top
            .total_cmp(&b.top)
            .then_with(|| a.left.total_cmp(&b.left))
    });
    inside
        .iter()
        .map(|line| line.text.as_str())
        .collect::<Vec<_>>()
        .join("\n")
}

// --- Duplicates -----------------------------------------------------------

/// A 64-bit simhash of the layer's words, as hex.
///
/// Simhash rather than a plain digest because the same document scanned twice
/// never recognizes identically — a comma becomes a full stop, a word at the
/// edge drops out. A plain hash of the text would call those two different
/// documents; a simhash puts them a few bits apart, which
/// [`text_layer_looks_duplicate`] can then act on.
#[frb(sync)]
pub fn text_layer_fingerprint(layer: TextLayer) -> String {
    let mut weights = [0i32; 64];
    let mut any = false;
    for page in &layer.pages {
        for line in &page.lines {
            for word in normalize(&line.text).split(' ') {
                let word: String = word.chars().filter(|c| c.is_alphanumeric()).collect();
                if word.chars().count() < MIN_SHINGLE_UNITS {
                    continue;
                }
                any = true;
                let hash = fnv1a(&word);
                for (bit, weight) in weights.iter_mut().enumerate() {
                    if hash >> bit & 1 == 1 {
                        *weight += 1;
                    } else {
                        *weight -= 1;
                    }
                }
            }
        }
    }
    if !any {
        return String::new();
    }
    let mut fingerprint = 0u64;
    for (bit, weight) in weights.iter().enumerate() {
        if *weight > 0 {
            fingerprint |= 1 << bit;
        }
    }
    format!("{fingerprint:016x}")
}

fn fnv1a(text: &str) -> u64 {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in text.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    hash
}

/// Differing bits between two fingerprints, or -1 if either is unreadable.
#[frb(sync)]
pub fn fingerprint_distance(left: String, right: String) -> i32 {
    match (
        u64::from_str_radix(&left, 16),
        u64::from_str_radix(&right, 16),
    ) {
        (Ok(left), Ok(right)) => (left ^ right).count_ones() as i32,
        _ => -1,
    }
}

/// Whether two captures are near enough to be the same document.
#[frb(sync)]
pub fn text_layer_looks_duplicate(left: String, right: String) -> bool {
    let distance = fingerprint_distance(left, right);
    (0..=DUPLICATE_DISTANCE).contains(&distance)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn line(text: &str, left: f32, top: f32, right: f32, bottom: f32) -> TextLayerLine {
        TextLayerLine {
            text: text.to_owned(),
            left,
            top,
            right,
            bottom,
            confidence: None,
            words: Vec::new(),
        }
    }

    /// The same line with a box per word, laid out evenly across its extent.
    fn worded(line: TextLayerLine) -> TextLayerLine {
        let words: Vec<&str> = line.text.split(' ').filter(|w| !w.is_empty()).collect();
        let units: usize =
            words.iter().map(|word| word.chars().count()).sum::<usize>() + words.len() - 1;
        let per_unit = (line.right - line.left) / units as f32;
        let mut cursor = line.left;
        let boxes = words
            .iter()
            .map(|word| {
                let width = word.chars().count() as f32 * per_unit;
                let left = cursor;
                cursor += width + per_unit;
                TextLayerWord {
                    text: (*word).to_owned(),
                    left,
                    top: line.top,
                    right: left + width,
                    bottom: line.bottom,
                }
            })
            .collect();
        TextLayerLine {
            words: boxes,
            ..line
        }
    }

    fn layer(lines: Vec<TextLayerLine>) -> TextLayer {
        TextLayer {
            source: "camera".to_owned(),
            pages: vec![TextLayerPage {
                width: 1000.0,
                height: 1400.0,
                lines,
            }],
        }
    }

    #[test]
    fn a_layer_survives_a_round_trip_unchanged() {
        let original = TextLayer {
            source: "document".to_owned(),
            pages: vec![
                TextLayerPage {
                    width: 1080.0,
                    height: 1920.0,
                    lines: vec![
                        TextLayerLine {
                            text: "first line".to_owned(),
                            left: 10.5,
                            top: 20.0,
                            right: 300.25,
                            bottom: 44.0,
                            confidence: Some(0.93),
                            words: vec![TextLayerWord {
                                text: "first".to_owned(),
                                left: 10.5,
                                top: 20.0,
                                right: 140.0,
                                bottom: 44.0,
                            }],
                        },
                        line("second line", 10.0, 50.0, 280.0, 74.0),
                    ],
                },
                TextLayerPage {
                    width: 1080.0,
                    height: 1920.0,
                    lines: vec![line("page two", 0.0, 0.0, 100.0, 20.0)],
                },
            ],
        };
        let decoded = decode_text_layer(encode_text_layer(original.clone()))
            .expect("a layer we just encoded must decode");
        assert_eq!(decoded.source, "document");
        assert_eq!(decoded.pages.len(), 2);
        assert_eq!(decoded.pages[0].lines[0].text, "first line");
        assert_eq!(decoded.pages[0].lines[0].confidence, Some(0.93));
        assert_eq!(decoded.pages[0].lines[1].confidence, None);
        assert_eq!(decoded.pages[1].lines[0].text, "page two");
        // Positions round to a tenth of a pixel, which is finer than any
        // recognizer resolves.
        assert!((decoded.pages[0].lines[0].right - 300.25).abs() <= 0.05);
    }

    #[test]
    fn quotes_and_newlines_in_recognized_text_survive_encoding() {
        let original = layer(vec![line(
            "he said \"stop\"\nthen \\ left",
            0.0,
            0.0,
            10.0,
            10.0,
        )]);
        let decoded = decode_text_layer(encode_text_layer(original)).expect("decodes");
        assert_eq!(
            decoded.pages[0].lines[0].text,
            "he said \"stop\"\nthen \\ left"
        );
    }

    #[test]
    fn a_layer_from_a_future_version_is_refused_rather_than_misread() {
        let error = decode_text_layer(r#"{"v":99,"src":"camera","p":[]}"#.to_owned())
            .expect_err("a version we do not know cannot be trusted");
        assert_eq!(error.kind, TextLayerErrorKind::UnsupportedVersion);
    }

    #[test]
    fn malformed_layers_return_typed_errors() {
        assert_eq!(
            decode_text_layer("not json".to_owned())
                .expect_err("invalid")
                .kind,
            TextLayerErrorKind::InvalidJson
        );
        assert_eq!(
            decode_text_layer(r#"{"v":1,"src":"x"}"#.to_owned())
                .expect_err("no pages")
                .kind,
            TextLayerErrorKind::InvalidShape
        );
        assert_eq!(
            decode_text_layer(r#"{"v":1,"src":"x","p":[{"l":[[1,2]]}]}"#.to_owned())
                .expect_err("a truncated line")
                .kind,
            TextLayerErrorKind::InvalidShape
        );
    }

    #[test]
    fn a_layer_round_trips_through_reconstruction_input() {
        let original = layer(vec![line("some text", 5.0, 6.0, 105.0, 26.0)]);
        let pages = text_layer_to_pages(original.clone());
        assert_eq!(pages.len(), 1);
        assert_eq!(pages[0].width, 1000.0);
        assert_eq!(pages[0].lines[0].text, "some text");
        let rebuilt = build_text_layer(pages, "camera".to_owned());
        assert_eq!(rebuilt.pages[0].lines, original.pages[0].lines);
    }

    // --- Search ---

    #[test]
    fn search_text_keeps_pages_apart() {
        let split = TextLayer {
            source: "pdf".to_owned(),
            pages: vec![
                TextLayerPage {
                    width: 0.0,
                    height: 0.0,
                    lines: vec![line("ends here", 0.0, 0.0, 10.0, 10.0)],
                },
                TextLayerPage {
                    width: 0.0,
                    height: 0.0,
                    lines: vec![line("starts there", 0.0, 0.0, 10.0, 10.0)],
                },
            ],
        };
        assert_eq!(text_layer_search_text(split), "ends here\n\nstarts there");
    }

    #[test]
    fn a_query_is_found_regardless_of_case_and_spacing() {
        let found = find_in_text_layer(
            layer(vec![line("Invoice   Number 4471", 0.0, 0.0, 400.0, 20.0)]),
            "invoice number".to_owned(),
        );
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].page, 0);
        assert_eq!(found[0].text, "Invoice   Number 4471");
    }

    #[test]
    fn a_hit_is_narrowed_to_the_matched_words_not_the_whole_line() {
        let found = find_in_text_layer(
            layer(vec![line("aaaa bbbb cccc", 0.0, 0.0, 300.0, 20.0)]),
            "cccc".to_owned(),
        );
        assert_eq!(found.len(), 1);
        // "cccc" is the last third of the line, so the box should sit in the
        // right-hand third rather than spanning the line.
        assert!(found[0].left > 150.0, "left was {}", found[0].left);
        assert!((found[0].right - 300.0).abs() < 1.0);
        assert_eq!(found[0].top, 0.0);
        assert_eq!(found[0].bottom, 20.0);
    }

    #[test]
    fn a_hit_lands_on_the_word_boxes_rather_than_an_interpolation() {
        // Proportional spacing is what the interpolation cannot know about: a
        // line of narrow letters followed by wide ones does not divide by
        // character count. Here "iiii" occupies the first 40 pixels of a 300
        // pixel line rather than its first third, and only the word boxes say
        // so.
        let mut narrow = line("iiii wwww", 0.0, 0.0, 300.0, 20.0);
        narrow.words = vec![
            TextLayerWord {
                text: "iiii".to_owned(),
                left: 0.0,
                top: 0.0,
                right: 40.0,
                bottom: 20.0,
            },
            TextLayerWord {
                text: "wwww".to_owned(),
                left: 60.0,
                top: 0.0,
                right: 300.0,
                bottom: 20.0,
            },
        ];
        let found = find_in_text_layer(layer(vec![narrow]), "iiii".to_owned());
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].left, 0.0);
        assert_eq!(found[0].right, 40.0);
    }

    #[test]
    fn a_hit_spanning_words_covers_all_of_them_and_no_more() {
        let found = find_in_text_layer(
            layer(vec![worded(line(
                "alpha beta gamma delta",
                0.0,
                0.0,
                400.0,
                20.0,
            ))]),
            "beta gamma".to_owned(),
        );
        assert_eq!(found.len(), 1);
        // Starts where "beta" starts and ends where "gamma" ends: "alpha" is
        // to its left and "delta" to its right, neither included.
        let whole = worded(line("alpha beta gamma delta", 0.0, 0.0, 400.0, 20.0));
        assert_eq!(found[0].left, whole.words[1].left);
        assert_eq!(found[0].right, whole.words[2].right);
    }

    #[test]
    fn words_that_do_not_spell_their_line_fall_back_to_interpolating() {
        // A source that reported words inconsistent with the line text cannot
        // be addressed by the offsets found in that text, so snapping to them
        // would highlight a confidently wrong span.
        let mut mismatched = line("aaaa bbbb cccc", 0.0, 0.0, 300.0, 20.0);
        mismatched.words = vec![TextLayerWord {
            text: "something else entirely".to_owned(),
            left: 0.0,
            top: 0.0,
            right: 10.0,
            bottom: 20.0,
        }];
        let found = find_in_text_layer(layer(vec![mismatched]), "cccc".to_owned());
        assert_eq!(found.len(), 1);
        assert!(found[0].left > 150.0, "left was {}", found[0].left);
    }

    #[test]
    fn a_layer_without_words_encodes_exactly_as_it_did_before_they_existed() {
        // The six-element line shape is what every already-stored layer is
        // written in. Adding a field must not rewrite them, or every scan on
        // the device is re-encoded to say the same thing.
        let encoded = encode_text_layer(layer(vec![line("plain", 1.0, 2.0, 3.0, 4.0)]));
        assert!(
            encoded.contains(r#"["plain",1.0,2.0,3.0,4.0,null]"#),
            "encoded as {encoded}"
        );
    }

    #[test]
    fn word_boxes_survive_a_round_trip() {
        let original = layer(vec![worded(line("alpha beta", 0.0, 0.0, 200.0, 20.0))]);
        let decoded = decode_text_layer(encode_text_layer(original.clone())).expect("decodes");
        assert_eq!(decoded, original);
    }

    #[test]
    fn a_layer_stored_before_words_existed_still_decodes() {
        let old = r#"{"v":1,"src":"camera","p":[{"w":100.0,"h":200.0,"l":[["old line",0.0,0.0,50.0,10.0,null]]}]}"#;
        let decoded = decode_text_layer(old.to_owned()).expect("an older layer still reads");
        assert_eq!(decoded.pages[0].lines[0].text, "old line");
        assert!(decoded.pages[0].lines[0].words.is_empty());
    }

    #[test]
    fn a_query_that_is_not_there_finds_nothing_and_an_empty_one_is_refused() {
        let page = layer(vec![line("nothing to see", 0.0, 0.0, 100.0, 20.0)]);
        assert!(find_in_text_layer(page.clone(), "absent".to_owned()).is_empty());
        assert!(find_in_text_layer(page, "   ".to_owned()).is_empty());
    }

    #[test]
    fn every_page_a_query_appears_on_is_reported() {
        let repeated = TextLayer {
            source: "pdf".to_owned(),
            pages: (0..3)
                .map(|_| TextLayerPage {
                    width: 0.0,
                    height: 0.0,
                    lines: vec![line("total due", 0.0, 0.0, 100.0, 20.0)],
                })
                .collect(),
        };
        let found = find_in_text_layer(repeated, "total".to_owned());
        assert_eq!(found.len(), 3);
        assert_eq!(found[2].page, 2);
    }

    // --- Regions ---

    #[test]
    fn a_region_returns_only_the_lines_inside_it_in_reading_order() {
        let page = layer(vec![
            line("bottom left", 0.0, 100.0, 100.0, 120.0),
            line("top left", 0.0, 0.0, 100.0, 20.0),
            line("far right", 800.0, 0.0, 900.0, 20.0),
        ]);
        assert_eq!(
            text_layer_region(page, 0, -10.0, -10.0, 200.0, 200.0),
            "top left\nbottom left"
        );
    }

    #[test]
    fn a_region_on_a_page_that_does_not_exist_is_empty_not_a_panic() {
        let page = layer(vec![line("text", 0.0, 0.0, 10.0, 10.0)]);
        assert_eq!(text_layer_region(page.clone(), 7, 0.0, 0.0, 10.0, 10.0), "");
        assert_eq!(text_layer_region(page, -1, 0.0, 0.0, 10.0, 10.0), "");
    }

    // --- Duplicates ---

    #[test]
    fn the_same_document_scanned_twice_fingerprints_the_same() {
        let first = layer(vec![
            line("Corner Grocer Market Street", 0.0, 0.0, 300.0, 20.0),
            line("Bread butter cheese apples", 0.0, 30.0, 300.0, 50.0),
            line("Total fourteen pounds sixty", 0.0, 60.0, 300.0, 80.0),
        ]);
        // The second read misplaces one word and shifts every box.
        let second = layer(vec![
            line("Corner Grocer Market Street", 5.0, 2.0, 305.0, 22.0),
            line("Bread butter cheese apples", 5.0, 32.0, 305.0, 52.0),
            line("Total fourteen pounds sixly", 5.0, 62.0, 305.0, 82.0),
        ]);
        let a = text_layer_fingerprint(first);
        let b = text_layer_fingerprint(second);
        assert!(
            text_layer_looks_duplicate(a.clone(), b.clone()),
            "distance was {}",
            fingerprint_distance(a, b)
        );
    }

    #[test]
    fn a_different_document_does_not_look_like_a_duplicate() {
        let receipt = layer(vec![
            line("Corner Grocer Market Street", 0.0, 0.0, 300.0, 20.0),
            line("Bread butter cheese apples", 0.0, 30.0, 300.0, 50.0),
        ]);
        let letter = layer(vec![
            line("Dear Madam thank you for writing", 0.0, 0.0, 300.0, 20.0),
            line("regarding the tenancy agreement", 0.0, 30.0, 300.0, 50.0),
        ]);
        assert!(!text_layer_looks_duplicate(
            text_layer_fingerprint(receipt),
            text_layer_fingerprint(letter)
        ));
    }

    #[test]
    fn an_empty_layer_has_no_fingerprint_and_never_matches() {
        let blank = text_layer_fingerprint(layer(vec![]));
        assert_eq!(blank, "");
        // An unreadable fingerprint must not be treated as "the same as".
        assert_eq!(fingerprint_distance(blank.clone(), blank), -1);
        assert!(!text_layer_looks_duplicate(String::new(), String::new()));
    }

    #[test]
    fn short_words_do_not_dominate_the_fingerprint() {
        // Two documents sharing only filler words are not duplicates.
        let one = layer(vec![line("the of and to a in", 0.0, 0.0, 300.0, 20.0)]);
        let two = layer(vec![line("the of and to a in", 0.0, 0.0, 300.0, 20.0)]);
        // Both reduce to the same handful of long-enough words, so they do
        // match — the point is that neither had any content to tell apart.
        assert_eq!(text_layer_fingerprint(one), text_layer_fingerprint(two));
    }
}
