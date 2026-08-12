//! Portable import/export codecs for formats that do not depend on Flutter.
//!
//! The public boundary deliberately receives clocks and UUIDs from Dart. This
//! keeps tests reproducible and prevents the native core from acquiring hidden
//! platform dependencies. Text budgets are measured in UTF-16 code units so a
//! limit has the same meaning on Dart and Rust, including for supplementary
//! Unicode characters.

use std::collections::{HashMap, HashSet};
use std::fmt;
use std::io::{Cursor, Read, Write};

use chrono::{DateTime, Duration, TimeZone, Utc};
use flutter_rust_bridge::frb;
use regex::Regex;
use roxmltree::{Document, Node, NodeType};
use serde_json::{Map, Value};
use zip::write::SimpleFileOptions;
use zip::{CompressionMethod, ZipArchive, ZipWriter};

use crate::dart_string::{dart_trim, dart_trim_end, DART_REGEXP_WHITESPACE_CLASS};

const OBLIX_FORMAT_ID: &str = "oblix-export";
const OBLIX_FORMAT_VERSION: i64 = 2;
const OBLIX_MANIFEST_NAME: &str = "manifest.json";
const OBLIX_DATA_NAME: &str = "data.json";
const EPUB_MEDIA_TYPE: &str = "application/epub+zip";

// These caps apply before or during decompression. They are intentionally well
// above normal note exports while preventing a small hostile ZIP from expanding
// without bound inside the client process.
const MAX_ARCHIVE_INPUT_BYTES: usize = 256 * 1024 * 1024;
const MAX_ARCHIVE_OUTPUT_BYTES: usize = 256 * 1024 * 1024;
const MAX_ARCHIVE_ENTRIES: usize = 10_000;
const MAX_ENTRY_UNCOMPRESSED_BYTES: u64 = 128 * 1024 * 1024;
const MAX_TOTAL_UNCOMPRESSED_BYTES: u64 = 512 * 1024 * 1024;
const MAX_XML_OR_JSON_BYTES: usize = 64 * 1024 * 1024;
const MAX_NOTES: usize = 10_000;
const MAX_NOTE_TEXT_UTF16_UNITS: usize = 4_000_000;
const MAX_TOTAL_TEXT_UTF16_UNITS: usize = 32_000_000;
const MAX_ATTACHMENTS: usize = 10_000;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CodecErrorKindDto {
    InvalidArchive,
    InvalidXml,
    InvalidJson,
    InvalidUtf8,
    InvalidInput,
    MissingEntry,
    UnsupportedVersion,
    UnsafeArchivePath,
    LimitExceeded,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CodecErrorDto {
    pub kind: CodecErrorKindDto,
    pub message: String,
}

impl CodecErrorDto {
    fn new(kind: CodecErrorKindDto, message: impl Into<String>) -> Self {
        Self {
            kind,
            message: message.into(),
        }
    }
}

impl fmt::Display for CodecErrorDto {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for CodecErrorDto {}

type CodecResult<T> = Result<T, CodecErrorDto>;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ImportedAttachmentDto {
    pub original_name: String,
    pub mime_type: Option<String>,
    pub bytes: Vec<u8>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ImportedNoteDto {
    pub title: String,
    pub content: String,
    pub content_type: String,
    pub tag_names: Vec<String>,
    pub is_pinned: bool,
    pub is_archived: bool,
    pub created_at_micros_utc: i64,
    pub updated_at_micros_utc: i64,
    /// Present only for Oblix archives. Dart parses these with
    /// `DateTime.tryParse` so local-zone/DST and permissive grammar semantics
    /// remain exact. An empty string represents a missing/null source field.
    pub created_at_raw: Option<String>,
    pub updated_at_raw: Option<String>,
    pub notebook_name: Option<String>,
    pub notebook_path: Option<Vec<String>>,
    pub attachments: Vec<ImportedAttachmentDto>,
    pub skipped_attachments: i32,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ImportBundleDto {
    pub notes: Vec<ImportedNoteDto>,
    pub notebook_names: Vec<String>,
    pub notebook_paths: Vec<Vec<String>>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct EpubNoteInputDto {
    pub title: String,
    pub content: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct EpubExportRequestDto {
    pub notes: Vec<EpubNoteInputDto>,
    pub exported_at_micros_utc: i64,
    /// UUID text without the `urn:uuid:` prefix.
    pub book_uuid: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct OblixNoteInputDto {
    pub id: String,
    pub notebook_id: Option<String>,
    pub title: String,
    pub content: String,
    pub content_type: String,
    pub tag_names: Vec<String>,
    pub is_pinned: bool,
    pub is_archived: bool,
    /// Exact `DateTime.toUtc().toIso8601String()` output supplied by Dart.
    /// Keeping this as text preserves Dart years outside Chrono's range.
    pub created_at_iso_utc: String,
    pub updated_at_iso_utc: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct OblixNotebookInputDto {
    pub id: String,
    pub name: String,
    pub parent_id: Option<String>,
    pub sort_order: i64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct OblixAttachmentInputDto {
    pub id: String,
    pub original_name: String,
    pub mime_type: String,
    pub bytes: Vec<u8>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct OblixAttachmentGroupInputDto {
    pub note_id: String,
    pub attachments: Vec<OblixAttachmentInputDto>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct OblixEncodeRequestDto {
    pub notes: Vec<OblixNoteInputDto>,
    pub notebooks: Vec<OblixNotebookInputDto>,
    /// The Dart encoder only serializes each tag's name.
    pub tag_names: Vec<String>,
    pub attachment_groups: Vec<OblixAttachmentGroupInputDto>,
    pub exported_at_micros_utc: i64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct OblixDecodeRequestDto {
    pub bytes: Vec<u8>,
    /// Used whenever an imported timestamp is absent or invalid.
    pub now_micros_utc: i64,
}

#[derive(Clone, Debug)]
#[cfg_attr(not(test), allow(dead_code))]
struct ReadZipEntry {
    name: String,
    bytes: Vec<u8>,
    compression: CompressionMethod,
}

#[derive(Clone, Debug)]
struct ReadZip {
    entries: Vec<ReadZipEntry>,
    indexes: HashMap<String, usize>,
}

impl ReadZip {
    fn get(&self, name: &str) -> Option<&ReadZipEntry> {
        self.indexes
            .get(name)
            .and_then(|index| self.entries.get(*index))
    }
}

struct WriteZipEntry {
    name: String,
    bytes: Vec<u8>,
    compression: CompressionMethod,
}

fn utf16_len(value: &str) -> usize {
    value.encode_utf16().count()
}

fn enforce_text_budget(notes: &[ImportedNoteDto]) -> CodecResult<()> {
    if notes.len() > MAX_NOTES {
        return Err(CodecErrorDto::new(
            CodecErrorKindDto::LimitExceeded,
            format!("Import contains more than {MAX_NOTES} notes."),
        ));
    }
    let mut total = 0usize;
    for note in notes {
        let note_units = utf16_len(&note.title)
            .checked_add(utf16_len(&note.content))
            .ok_or_else(|| {
                CodecErrorDto::new(
                    CodecErrorKindDto::LimitExceeded,
                    "Imported text size overflowed.",
                )
            })?;
        if note_units > MAX_NOTE_TEXT_UTF16_UNITS {
            return Err(CodecErrorDto::new(
                CodecErrorKindDto::LimitExceeded,
                format!("A note exceeds the {MAX_NOTE_TEXT_UTF16_UNITS} UTF-16 unit limit."),
            ));
        }
        total = total.checked_add(note_units).ok_or_else(|| {
            CodecErrorDto::new(
                CodecErrorKindDto::LimitExceeded,
                "Imported text size overflowed.",
            )
        })?;
        if total > MAX_TOTAL_TEXT_UTF16_UNITS {
            return Err(CodecErrorDto::new(
                CodecErrorKindDto::LimitExceeded,
                format!("Import exceeds the {MAX_TOTAL_TEXT_UTF16_UNITS} UTF-16 unit limit."),
            ));
        }
    }
    Ok(())
}

fn validate_archive_path(name: &str, directory: bool) -> CodecResult<()> {
    let candidate = if directory {
        name.strip_suffix('/').unwrap_or(name)
    } else {
        name
    };
    if candidate.is_empty()
        || candidate.starts_with('/')
        || candidate.starts_with('\\')
        || candidate.contains('\\')
        || candidate.contains('\0')
        || candidate
            .split('/')
            .any(|part| part.is_empty() || part == "." || part == ".." || part.contains(':'))
    {
        return Err(CodecErrorDto::new(
            CodecErrorKindDto::UnsafeArchivePath,
            format!("Unsafe archive path: {name}"),
        ));
    }
    Ok(())
}

fn read_zip(bytes: &[u8]) -> CodecResult<ReadZip> {
    if bytes.len() > MAX_ARCHIVE_INPUT_BYTES {
        return Err(CodecErrorDto::new(
            CodecErrorKindDto::LimitExceeded,
            format!("Archive exceeds {MAX_ARCHIVE_INPUT_BYTES} bytes."),
        ));
    }
    let mut archive = ZipArchive::new(Cursor::new(bytes)).map_err(|error| {
        CodecErrorDto::new(
            CodecErrorKindDto::InvalidArchive,
            format!("Invalid ZIP archive: {error}"),
        )
    })?;
    if archive.len() > MAX_ARCHIVE_ENTRIES {
        return Err(CodecErrorDto::new(
            CodecErrorKindDto::LimitExceeded,
            format!("Archive contains more than {MAX_ARCHIVE_ENTRIES} entries."),
        ));
    }

    let mut entries = Vec::with_capacity(archive.len());
    let mut indexes = HashMap::with_capacity(archive.len());
    let mut total_uncompressed = 0u64;
    for index in 0..archive.len() {
        let mut file = archive.by_index(index).map_err(|error| {
            CodecErrorDto::new(
                CodecErrorKindDto::InvalidArchive,
                format!("Cannot read ZIP entry {index}: {error}"),
            )
        })?;
        let is_directory = file.is_dir();
        let name = file.name().to_owned();
        validate_archive_path(&name, is_directory)?;
        if is_directory {
            continue;
        }
        if file.size() > MAX_ENTRY_UNCOMPRESSED_BYTES {
            return Err(CodecErrorDto::new(
                CodecErrorKindDto::LimitExceeded,
                format!("Archive entry {name} is too large."),
            ));
        }
        total_uncompressed = total_uncompressed.checked_add(file.size()).ok_or_else(|| {
            CodecErrorDto::new(
                CodecErrorKindDto::LimitExceeded,
                "Archive uncompressed size overflowed.",
            )
        })?;
        if total_uncompressed > MAX_TOTAL_UNCOMPRESSED_BYTES {
            return Err(CodecErrorDto::new(
                CodecErrorKindDto::LimitExceeded,
                "Archive expands beyond the safe total size limit.",
            ));
        }

        let declared_capacity = usize::try_from(file.size()).map_err(|_| {
            CodecErrorDto::new(
                CodecErrorKindDto::LimitExceeded,
                format!("Archive entry {name} does not fit in memory."),
            )
        })?;
        let mut content = Vec::with_capacity(declared_capacity);
        (&mut file)
            .take(MAX_ENTRY_UNCOMPRESSED_BYTES + 1)
            .read_to_end(&mut content)
            .map_err(|error| {
                CodecErrorDto::new(
                    CodecErrorKindDto::InvalidArchive,
                    format!("Cannot decompress ZIP entry {name}: {error}"),
                )
            })?;
        if content.len() as u64 > MAX_ENTRY_UNCOMPRESSED_BYTES {
            return Err(CodecErrorDto::new(
                CodecErrorKindDto::LimitExceeded,
                format!("Archive entry {name} expanded beyond its safe limit."),
            ));
        }
        if indexes.contains_key(&name) {
            return Err(CodecErrorDto::new(
                CodecErrorKindDto::InvalidArchive,
                format!("Archive contains duplicate entry {name}."),
            ));
        }
        let compression = file.compression();
        indexes.insert(name.clone(), entries.len());
        entries.push(ReadZipEntry {
            name,
            bytes: content,
            compression,
        });
    }
    Ok(ReadZip { entries, indexes })
}

fn write_zip(entries: Vec<WriteZipEntry>) -> CodecResult<Vec<u8>> {
    if entries.len() > MAX_ARCHIVE_ENTRIES {
        return Err(CodecErrorDto::new(
            CodecErrorKindDto::LimitExceeded,
            format!("Archive contains more than {MAX_ARCHIVE_ENTRIES} entries."),
        ));
    }
    let mut names = HashSet::with_capacity(entries.len());
    let mut total = 0u64;
    for entry in &entries {
        validate_archive_path(&entry.name, false)?;
        if !names.insert(entry.name.clone()) {
            return Err(CodecErrorDto::new(
                CodecErrorKindDto::InvalidInput,
                format!("Duplicate output archive entry {}.", entry.name),
            ));
        }
        if entry.bytes.len() as u64 > MAX_ENTRY_UNCOMPRESSED_BYTES {
            return Err(CodecErrorDto::new(
                CodecErrorKindDto::LimitExceeded,
                format!("Output entry {} is too large.", entry.name),
            ));
        }
        total = total.checked_add(entry.bytes.len() as u64).ok_or_else(|| {
            CodecErrorDto::new(
                CodecErrorKindDto::LimitExceeded,
                "Output archive size overflowed.",
            )
        })?;
        if total > MAX_TOTAL_UNCOMPRESSED_BYTES {
            return Err(CodecErrorDto::new(
                CodecErrorKindDto::LimitExceeded,
                "Output archive exceeds the safe total size limit.",
            ));
        }
    }

    let cursor = Cursor::new(Vec::new());
    let mut writer = ZipWriter::new(cursor);
    for entry in entries {
        let options = SimpleFileOptions::default()
            .compression_method(entry.compression)
            .unix_permissions(0o644);
        writer.start_file(&entry.name, options).map_err(|error| {
            CodecErrorDto::new(
                CodecErrorKindDto::InvalidArchive,
                format!("Cannot create ZIP entry {}: {error}", entry.name),
            )
        })?;
        writer.write_all(&entry.bytes).map_err(|error| {
            CodecErrorDto::new(
                CodecErrorKindDto::InvalidArchive,
                format!("Cannot write ZIP entry {}: {error}", entry.name),
            )
        })?;
    }
    let bytes = writer
        .finish()
        .map_err(|error| {
            CodecErrorDto::new(
                CodecErrorKindDto::InvalidArchive,
                format!("Cannot finish ZIP archive: {error}"),
            )
        })?
        .into_inner();
    if bytes.len() > MAX_ARCHIVE_OUTPUT_BYTES {
        return Err(CodecErrorDto::new(
            CodecErrorKindDto::LimitExceeded,
            format!("Output archive exceeds {MAX_ARCHIVE_OUTPUT_BYTES} bytes."),
        ));
    }
    Ok(bytes)
}

fn read_utf8_entry<'a>(archive: &'a ReadZip, name: &str) -> CodecResult<Option<&'a str>> {
    let Some(entry) = archive.get(name) else {
        return Ok(None);
    };
    if entry.bytes.len() > MAX_XML_OR_JSON_BYTES {
        return Err(CodecErrorDto::new(
            CodecErrorKindDto::LimitExceeded,
            format!("Text entry {name} is too large."),
        ));
    }
    std::str::from_utf8(&entry.bytes)
        .map(Some)
        .map_err(|error| {
            CodecErrorDto::new(
                CodecErrorKindDto::InvalidUtf8,
                format!("Archive entry {name} is not valid UTF-8: {error}"),
            )
        })
}

fn utc_datetime_from_micros(micros: i64) -> CodecResult<DateTime<Utc>> {
    let seconds = micros.div_euclid(1_000_000);
    let subsecond_micros = micros.rem_euclid(1_000_000) as u32;
    Utc.timestamp_opt(seconds, subsecond_micros * 1_000)
        .single()
        .ok_or_else(|| {
            CodecErrorDto::new(
                CodecErrorKindDto::InvalidInput,
                format!("UTC timestamp {micros} is outside the supported range."),
            )
        })
}

fn datetime_to_micros(datetime: DateTime<Utc>) -> CodecResult<i64> {
    datetime
        .timestamp()
        .checked_mul(1_000_000)
        .and_then(|value| value.checked_add(i64::from(datetime.timestamp_subsec_micros())))
        .ok_or_else(|| {
            CodecErrorDto::new(
                CodecErrorKindDto::InvalidInput,
                "Timestamp does not fit into signed UTC microseconds.",
            )
        })
}

fn format_dart_iso_utc(micros: i64) -> CodecResult<String> {
    let datetime = utc_datetime_from_micros(micros)?;
    let fraction = datetime.timestamp_subsec_micros();
    if fraction % 1_000 == 0 {
        Ok(format!(
            "{}.{:03}Z",
            datetime.format("%Y-%m-%dT%H:%M:%S"),
            fraction / 1_000
        ))
    } else {
        Ok(format!(
            "{}.{fraction:06}Z",
            datetime.format("%Y-%m-%dT%H:%M:%S")
        ))
    }
}

fn direct_child<'a, 'input>(node: Node<'a, 'input>, local_name: &str) -> Option<Node<'a, 'input>> {
    node.children()
        .find(|child| child.is_element() && child.tag_name().name() == local_name)
}

fn node_inner_text(node: Node<'_, '_>) -> String {
    let mut output = String::new();
    for descendant in node.descendants() {
        if descendant.node_type() == NodeType::Text {
            if let Some(text) = descendant.text() {
                output.push_str(text);
            }
        }
    }
    output
}

fn ensure_newline(output: &mut String) {
    if !output.is_empty() && !output.ends_with('\n') {
        output.push('\n');
    }
}

fn tidy_flattened_text(value: &str) -> String {
    let normalized = value.replace("\r\n", "\n");
    let mut output = Vec::new();
    let mut blanks = 0usize;
    for line in normalized.split('\n') {
        let line = dart_trim_end(line);
        if dart_trim(line).is_empty() {
            blanks += 1;
            if blanks <= 1 {
                output.push(String::new());
            }
        } else {
            blanks = 0;
            output.push(line.to_owned());
        }
    }
    dart_trim(&output.join("\n")).to_owned()
}

fn walk_text(node: Node<'_, '_>, block_tags: &[&str], output: &mut String) {
    for child in node.children() {
        match child.node_type() {
            NodeType::Text => {
                if let Some(text) = child.text() {
                    output.push_str(text);
                }
            }
            NodeType::Element => {
                let tag = child.tag_name().name().to_ascii_lowercase();
                if tag == "br" {
                    ensure_newline(output);
                    continue;
                }
                let block = block_tags.contains(&tag.as_str());
                if block {
                    ensure_newline(output);
                }
                walk_text(child, block_tags, output);
                if block {
                    ensure_newline(output);
                }
            }
            _ => {}
        }
    }
}

const ENML_BLOCK_TAGS: &[&str] = &[
    "div",
    "p",
    "br",
    "li",
    "tr",
    "h1",
    "h2",
    "h3",
    "h4",
    "h5",
    "h6",
    "blockquote",
    "ul",
    "ol",
    "table",
];

fn enml_to_text(enml: &str) -> CodecResult<String> {
    if dart_trim(enml).is_empty() {
        return Ok(String::new());
    }
    if let Ok(document) = Document::parse(enml) {
        let root = document
            .root()
            .children()
            .find(|node| node.is_element() && node.tag_name().name() == "en-note")
            .unwrap_or_else(|| document.root_element());
        let mut output = String::new();
        walk_text(root, ENML_BLOCK_TAGS, &mut output);
        return Ok(tidy_flattened_text(&output));
    }

    // Deliberately mirrors the Dart fallback's three ordered regex passes.
    // In particular, `&amp;lt;` is double-decoded because `&amp;` is replaced
    // before `&lt;`; preserving this quirk keeps malformed imports stable.
    let br_pattern = format!(r"(?i)<{0}*br{0}*/?>", DART_REGEXP_WHITESPACE_CLASS);
    let br = Regex::new(&br_pattern).map_err(|error| {
        CodecErrorDto::new(
            CodecErrorKindDto::InvalidInput,
            format!("Cannot compile ENML fallback expression: {error}"),
        )
    })?;
    let closing_block_pattern = format!(
        r"(?i)</{0}*(div|p|li|h[1-6]|tr){0}*>",
        DART_REGEXP_WHITESPACE_CLASS
    );
    let closing_block = Regex::new(&closing_block_pattern).map_err(|error| {
        CodecErrorDto::new(
            CodecErrorKindDto::InvalidInput,
            format!("Cannot compile ENML fallback expression: {error}"),
        )
    })?;
    let tags = Regex::new(r"<[^>]+>").map_err(|error| {
        CodecErrorDto::new(
            CodecErrorKindDto::InvalidInput,
            format!("Cannot compile ENML fallback expression: {error}"),
        )
    })?;
    let with_breaks = br.replace_all(enml, "\n");
    let with_blocks = closing_block.replace_all(&with_breaks, "\n");
    let stripped = tags.replace_all(&with_blocks, "");
    let unescaped = stripped
        .replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'");
    Ok(tidy_flattened_text(&unescaped))
}

fn parse_fixed_decimal(bytes: &[u8]) -> Option<i64> {
    if bytes.is_empty() || !bytes.iter().all(u8::is_ascii_digit) {
        return None;
    }
    std::str::from_utf8(bytes).ok()?.parse().ok()
}

/// Parse Evernote basic ISO timestamps while retaining Dart DateTime.utc's
/// overflow normalization (month 13, hour 24, and similar values roll over).
fn parse_enex_timestamp(raw: Option<&str>) -> Option<i64> {
    let raw = dart_trim(raw?);
    let core = match raw.as_bytes() {
        bytes if bytes.len() == 15 => bytes,
        bytes if bytes.len() == 16 && bytes[15] == b'Z' => &bytes[..15],
        _ => return None,
    };
    if core[8] != b'T' {
        return None;
    }
    let year = parse_fixed_decimal(&core[0..4])? as i32;
    let month = parse_fixed_decimal(&core[4..6])?;
    let day = parse_fixed_decimal(&core[6..8])?;
    let hour = parse_fixed_decimal(&core[9..11])?;
    let minute = parse_fixed_decimal(&core[11..13])?;
    let second = parse_fixed_decimal(&core[13..15])?;

    let zero_based_month = month - 1;
    let normalized_year = year.checked_add(zero_based_month.div_euclid(12) as i32)?;
    let normalized_month = zero_based_month.rem_euclid(12) as u32 + 1;
    let base = Utc
        .with_ymd_and_hms(normalized_year, normalized_month, 1, 0, 0, 0)
        .single()?;
    let normalized = base
        .checked_add_signed(Duration::days(day - 1))?
        .checked_add_signed(Duration::hours(hour))?
        .checked_add_signed(Duration::minutes(minute))?
        .checked_add_signed(Duration::seconds(second))?;
    datetime_to_micros(normalized).ok()
}

/// roxmltree intentionally rejects DTDs. ENEX commonly carries Evernote's
/// external DOCTYPE declaration, but the client never needs DTD expansion, so
/// remove declarations before parsing while retaining the document itself.
fn strip_xml_doctypes(xml: &str) -> CodecResult<String> {
    let mut sanitized = xml.to_owned();
    loop {
        let lower = sanitized.to_ascii_lowercase();
        let Some(start) = lower.find("<!doctype") else {
            return Ok(sanitized);
        };
        let bytes = sanitized.as_bytes();
        let mut quote = None;
        let mut subset_depth = 0usize;
        let mut end = None;
        for (offset, byte) in bytes[start + 9..].iter().copied().enumerate() {
            let index = start + 9 + offset;
            if let Some(delimiter) = quote {
                if byte == delimiter {
                    quote = None;
                }
                continue;
            }
            match byte {
                b'\'' | b'"' => quote = Some(byte),
                b'[' => subset_depth = subset_depth.saturating_add(1),
                b']' => subset_depth = subset_depth.saturating_sub(1),
                b'>' if subset_depth == 0 => {
                    end = Some(index + 1);
                    break;
                }
                _ => {}
            }
        }
        let end = end.ok_or_else(|| {
            CodecErrorDto::new(
                CodecErrorKindDto::InvalidXml,
                "Invalid ENEX DOCTYPE declaration.",
            )
        })?;
        sanitized.replace_range(start..end, "");
    }
}

/// Parse Evernote ENEX into the same plain-text import DTO used by Dart.
/// `now_micros_utc` replaces every missing/invalid source timestamp.
#[frb(sync)]
pub fn parse_enex(
    xml: String,
    notebook_name: Option<String>,
    now_micros_utc: i64,
) -> Result<ImportBundleDto, CodecErrorDto> {
    if xml.len() > MAX_XML_OR_JSON_BYTES {
        return Err(CodecErrorDto::new(
            CodecErrorKindDto::LimitExceeded,
            "ENEX document is too large.",
        ));
    }
    // Validate the explicit fallback even if every note carries timestamps.
    utc_datetime_from_micros(now_micros_utc)?;
    let sanitized_xml = strip_xml_doctypes(&xml)?;
    let document = Document::parse(&sanitized_xml).map_err(|error| {
        CodecErrorDto::new(
            CodecErrorKindDto::InvalidXml,
            format!("Invalid ENEX XML: {error}"),
        )
    })?;
    let mut notes = Vec::new();
    for note in document
        .descendants()
        .filter(|node| node.is_element() && node.tag_name().name() == "note")
    {
        if notes.len() == MAX_NOTES {
            return Err(CodecErrorDto::new(
                CodecErrorKindDto::LimitExceeded,
                format!("ENEX contains more than {MAX_NOTES} notes."),
            ));
        }
        let raw_title = direct_child(note, "title")
            .map(node_inner_text)
            .unwrap_or_default();
        let title = dart_trim(&raw_title).to_owned();
        let enml = direct_child(note, "content")
            .map(node_inner_text)
            .unwrap_or_default();
        let content = enml_to_text(&enml)?;
        let created = parse_enex_timestamp(
            direct_child(note, "created")
                .as_ref()
                .map(|node| node_inner_text(*node))
                .as_deref(),
        );
        let updated = parse_enex_timestamp(
            direct_child(note, "updated")
                .as_ref()
                .map(|node| node_inner_text(*node))
                .as_deref(),
        )
        .or(created);
        let tag_names = note
            .children()
            .filter(|child| child.is_element() && child.tag_name().name() == "tag")
            .map(node_inner_text)
            .map(|tag| dart_trim(&tag).to_owned())
            .filter(|tag| !tag.is_empty())
            .collect();
        let is_pinned = direct_child(note, "note-attributes")
            .and_then(|attributes| direct_child(attributes, "reminder-order"))
            .map(node_inner_text)
            .is_some_and(|value| !dart_trim(&value).is_empty());
        let skipped_attachments = note
            .children()
            .filter(|child| child.is_element() && child.tag_name().name() == "resource")
            .count();
        let skipped_attachments = i32::try_from(skipped_attachments).map_err(|_| {
            CodecErrorDto::new(
                CodecErrorKindDto::LimitExceeded,
                "ENEX resource count exceeds the supported range.",
            )
        })?;
        notes.push(ImportedNoteDto {
            title: if title.is_empty() {
                "Untitled".to_owned()
            } else {
                title
            },
            content,
            content_type: "plain".to_owned(),
            tag_names,
            is_pinned,
            is_archived: false,
            created_at_micros_utc: created.unwrap_or(now_micros_utc),
            updated_at_micros_utc: updated.unwrap_or(now_micros_utc),
            created_at_raw: None,
            updated_at_raw: None,
            notebook_name: notebook_name.clone(),
            notebook_path: None,
            attachments: Vec::new(),
            skipped_attachments,
        });
    }
    enforce_text_budget(&notes)?;
    let notebook_names = if notes.is_empty() {
        Vec::new()
    } else {
        notebook_name.into_iter().collect()
    };
    Ok(ImportBundleDto {
        notes,
        notebook_names,
        notebook_paths: Vec::new(),
    })
}

const XHTML_BLOCK_TAGS: &[&str] = &[
    "div",
    "p",
    "br",
    "li",
    "tr",
    "h1",
    "h2",
    "h3",
    "h4",
    "h5",
    "h6",
    "blockquote",
    "ul",
    "ol",
    "table",
    "section",
    "article",
    "header",
    "footer",
    "nav",
    "pre",
    "hr",
];

fn escape_xml(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

fn epub_container_xml() -> String {
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\
<container version=\"1.0\" xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\">\n\
  <rootfiles>\n\
    <rootfile full-path=\"OEBPS/content.opf\" media-type=\"application/oebps-package+xml\"/>\n\
  </rootfiles>\n\
</container>\n"
        .to_owned()
}

fn epub_opf(title: &str, book_id: &str, modified: &str, notes: &[EpubNoteInputDto]) -> String {
    let mut output = String::new();
    output.push_str("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    output.push_str(
        "<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"bookid\" xml:lang=\"en\">\n",
    );
    output.push_str("  <metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\">\n");
    output.push_str(&format!(
        "    <dc:identifier id=\"bookid\">{book_id}</dc:identifier>\n"
    ));
    output.push_str(&format!("    <dc:title>{}</dc:title>\n", escape_xml(title)));
    output.push_str("    <dc:language>en</dc:language>\n");
    output.push_str(&format!(
        "    <meta property=\"dcterms:modified\">{modified}</meta>\n"
    ));
    output.push_str("  </metadata>\n  <manifest>\n");
    output.push_str(
        "    <item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>\n",
    );
    for index in 0..notes.len() {
        output.push_str(&format!(
            "    <item id=\"note-{index}\" href=\"note-{index}.xhtml\" media-type=\"application/xhtml+xml\"/>\n"
        ));
    }
    output.push_str("  </manifest>\n  <spine>\n");
    for index in 0..notes.len() {
        output.push_str(&format!("    <itemref idref=\"note-{index}\"/>\n"));
    }
    output.push_str("  </spine>\n</package>\n");
    output
}

fn epub_nav(title: &str, notes: &[EpubNoteInputDto]) -> String {
    let mut output = String::new();
    output.push_str("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    output.push_str(
        "<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\" xml:lang=\"en\" lang=\"en\">\n",
    );
    output.push_str(&format!(
        "<head><title>{}</title></head>\n",
        escape_xml(title)
    ));
    output.push_str("<body>\n<nav epub:type=\"toc\">\n");
    output.push_str(&format!("<h1>{}</h1>\n<ol>\n", escape_xml(title)));
    for (index, note) in notes.iter().enumerate() {
        output.push_str(&format!(
            "<li><a href=\"note-{index}.xhtml\">{}</a></li>\n",
            escape_xml(&note.title)
        ));
    }
    output.push_str("</ol>\n</nav>\n</body>\n</html>\n");
    output
}

fn epub_chapter(note: &EpubNoteInputDto, paragraph_split: &Regex) -> String {
    let mut output = String::new();
    output.push_str("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    output.push_str("<html xmlns=\"http://www.w3.org/1999/xhtml\" xml:lang=\"en\" lang=\"en\">\n");
    output.push_str(&format!(
        "<head><title>{}</title></head>\n<body>\n<h1>{}</h1>\n",
        escape_xml(&note.title),
        escape_xml(&note.title)
    ));
    for paragraph in paragraph_split.split(&note.content) {
        let paragraph = dart_trim(paragraph);
        if paragraph.is_empty() {
            continue;
        }
        let body = escape_xml(paragraph).replace('\n', "<br/>");
        output.push_str(&format!("<p>{body}</p>\n"));
    }
    output.push_str("</body>\n</html>\n");
    output
}

/// Create an EPUB 3 file. The caller supplies both timestamp and UUID so the
/// output shape is deterministic. ZIP metadata uses a stable default timestamp.
#[frb(sync)]
pub fn export_epub(request: EpubExportRequestDto) -> Result<Vec<u8>, CodecErrorDto> {
    if request.notes.len() > MAX_NOTES {
        return Err(CodecErrorDto::new(
            CodecErrorKindDto::LimitExceeded,
            format!("EPUB contains more than {MAX_NOTES} notes."),
        ));
    }
    if dart_trim(&request.book_uuid).is_empty() {
        return Err(CodecErrorDto::new(
            CodecErrorKindDto::InvalidInput,
            "EPUB book UUID must not be empty.",
        ));
    }
    let mut total_units = 0usize;
    for note in &request.notes {
        let units = utf16_len(&note.title)
            .checked_add(utf16_len(&note.content))
            .ok_or_else(|| {
                CodecErrorDto::new(
                    CodecErrorKindDto::LimitExceeded,
                    "EPUB text size overflowed.",
                )
            })?;
        if units > MAX_NOTE_TEXT_UTF16_UNITS {
            return Err(CodecErrorDto::new(
                CodecErrorKindDto::LimitExceeded,
                "An EPUB note exceeds the safe UTF-16 text limit.",
            ));
        }
        total_units = total_units.checked_add(units).ok_or_else(|| {
            CodecErrorDto::new(
                CodecErrorKindDto::LimitExceeded,
                "EPUB text size overflowed.",
            )
        })?;
        if total_units > MAX_TOTAL_TEXT_UTF16_UNITS {
            return Err(CodecErrorDto::new(
                CodecErrorKindDto::LimitExceeded,
                "EPUB text exceeds the safe total UTF-16 limit.",
            ));
        }
    }

    let exported_at = utc_datetime_from_micros(request.exported_at_micros_utc)?;
    let date = exported_at.format("%Y-%m-%d").to_string();
    let modified = format!("{}Z", exported_at.format("%Y-%m-%dT%H:%M:%S"));
    let title = format!("Oblix export {date}");
    let book_id = format!("urn:uuid:{}", request.book_uuid);
    let paragraph_split_pattern = format!(r"\n{}*\n", DART_REGEXP_WHITESPACE_CLASS);
    let paragraph_split = Regex::new(&paragraph_split_pattern).map_err(|error| {
        CodecErrorDto::new(
            CodecErrorKindDto::InvalidInput,
            format!("Cannot compile EPUB paragraph expression: {error}"),
        )
    })?;

    let mut entries = vec![WriteZipEntry {
        name: "mimetype".to_owned(),
        bytes: EPUB_MEDIA_TYPE.as_bytes().to_vec(),
        compression: CompressionMethod::Stored,
    }];
    entries.push(WriteZipEntry {
        name: "META-INF/container.xml".to_owned(),
        bytes: epub_container_xml().into_bytes(),
        compression: CompressionMethod::Deflated,
    });
    entries.push(WriteZipEntry {
        name: "OEBPS/content.opf".to_owned(),
        bytes: epub_opf(&title, &book_id, &modified, &request.notes).into_bytes(),
        compression: CompressionMethod::Deflated,
    });
    entries.push(WriteZipEntry {
        name: "OEBPS/nav.xhtml".to_owned(),
        bytes: epub_nav(&title, &request.notes).into_bytes(),
        compression: CompressionMethod::Deflated,
    });
    for (index, note) in request.notes.iter().enumerate() {
        entries.push(WriteZipEntry {
            name: format!("OEBPS/note-{index}.xhtml"),
            bytes: epub_chapter(note, &paragraph_split).into_bytes(),
            compression: CompressionMethod::Deflated,
        });
    }
    write_zip(entries)
}

fn epub_opf_path(container_xml: &str) -> CodecResult<Option<String>> {
    let document = Document::parse(container_xml).map_err(|error| {
        CodecErrorDto::new(
            CodecErrorKindDto::InvalidXml,
            format!("Invalid EPUB container.xml: {error}"),
        )
    })?;
    Ok(document
        .descendants()
        .find(|node| node.is_element() && node.tag_name().name() == "rootfile")
        .and_then(|node| node.attribute("full-path"))
        .map(str::to_owned))
}

fn epub_book_title(document: &Document<'_>) -> Option<String> {
    for node in document
        .descendants()
        .filter(|node| node.is_element() && node.tag_name().name() == "title")
    {
        if node
            .parent_element()
            .is_some_and(|parent| parent.tag_name().name() == "metadata")
        {
            let title = node_inner_text(node);
            return Some(dart_trim(&title).to_owned());
        }
    }
    document
        .descendants()
        .find(|node| {
            node.is_element()
                && node.tag_name().name() == "title"
                && node.tag_name().namespace() == Some("http://purl.org/dc/elements/1.1/")
        })
        .map(|node| {
            let title = node_inner_text(node);
            dart_trim(&title).to_owned()
        })
}

fn epub_spine_hrefs(document: &Document<'_>) -> Vec<String> {
    let mut manifest = HashMap::new();
    for item in document
        .descendants()
        .filter(|node| node.is_element() && node.tag_name().name() == "item")
    {
        if let (Some(id), Some(href)) = (item.attribute("id"), item.attribute("href")) {
            manifest.insert(id.to_owned(), href.to_owned());
        }
    }
    let mut hrefs = Vec::new();
    for itemref in document
        .descendants()
        .filter(|node| node.is_element() && node.tag_name().name() == "itemref")
    {
        if let Some(href) = itemref
            .attribute("idref")
            .and_then(|idref| manifest.get(idref))
        {
            hrefs.push(href.clone());
        }
    }
    hrefs
}

fn dirname(path: &str) -> &str {
    path.rfind('/').map_or("", |index| &path[..index])
}

fn sanitize_xhtml(raw: &str) -> CodecResult<&str> {
    if Document::parse(raw).is_ok() {
        return Ok(raw);
    }
    let expression = Regex::new(r"(?is)<html[^>]*>.*</html>").map_err(|error| {
        CodecErrorDto::new(
            CodecErrorKindDto::InvalidInput,
            format!("Cannot compile XHTML recovery expression: {error}"),
        )
    })?;
    Ok(expression.find(raw).map_or(raw, |found| found.as_str()))
}

fn parse_epub_chapter(xhtml: &str, spine_index: usize) -> CodecResult<(String, String)> {
    let sanitized = sanitize_xhtml(xhtml)?;
    let document = Document::parse(sanitized).map_err(|error| {
        CodecErrorDto::new(
            CodecErrorKindDto::InvalidXml,
            format!("Invalid EPUB chapter XHTML: {error}"),
        )
    })?;
    let root = document.root_element();
    let h1 = root
        .descendants()
        .find(|node| node.is_element() && node.tag_name().name() == "h1")
        .map(node_inner_text)
        .map(|title| dart_trim(&title).to_owned())
        .filter(|title| !title.is_empty());
    let html_title = root
        .descendants()
        .find(|node| node.is_element() && node.tag_name().name() == "title")
        .map(node_inner_text)
        .map(|title| dart_trim(&title).to_owned())
        .filter(|title| !title.is_empty());
    let title = h1
        .or(html_title)
        .unwrap_or_else(|| format!("Chapter {}", spine_index + 1));
    let mut output = String::new();
    walk_text(root, XHTML_BLOCK_TAGS, &mut output);
    Ok((title, tidy_flattened_text(&output)))
}

/// Parse an EPUB ZIP into one plain-text note per readable spine chapter.
#[frb(sync)]
pub fn import_epub(bytes: Vec<u8>, now_micros_utc: i64) -> Result<ImportBundleDto, CodecErrorDto> {
    utc_datetime_from_micros(now_micros_utc)?;
    let archive = read_zip(&bytes)?;
    let container_xml = read_utf8_entry(&archive, "META-INF/container.xml")?.ok_or_else(|| {
        CodecErrorDto::new(
            CodecErrorKindDto::MissingEntry,
            "Not a valid EPUB (missing container.xml).",
        )
    })?;
    let opf_path = epub_opf_path(container_xml)?.ok_or_else(|| {
        CodecErrorDto::new(
            CodecErrorKindDto::InvalidXml,
            "EPUB container.xml has no rootfile.",
        )
    })?;
    let opf_xml = read_utf8_entry(&archive, &opf_path)?.ok_or_else(|| {
        CodecErrorDto::new(
            CodecErrorKindDto::MissingEntry,
            format!("EPUB missing OPF at {opf_path}."),
        )
    })?;
    let opf = Document::parse(opf_xml).map_err(|error| {
        CodecErrorDto::new(
            CodecErrorKindDto::InvalidXml,
            format!("Invalid EPUB OPF XML: {error}"),
        )
    })?;
    let book_title = epub_book_title(&opf).unwrap_or_else(|| "Imported EPUB".to_owned());
    let hrefs = epub_spine_hrefs(&opf);
    let base_dir = dirname(&opf_path);
    let mut notes = Vec::new();
    for (index, href) in hrefs.iter().enumerate() {
        let path = if base_dir.is_empty() {
            href.clone()
        } else {
            format!("{base_dir}/{href}")
        };
        let Some(xhtml) = read_utf8_entry(&archive, &path)? else {
            continue;
        };
        let (chapter_title, content) = parse_epub_chapter(xhtml, index)?;
        notes.push(ImportedNoteDto {
            title: chapter_title,
            content,
            content_type: "plain".to_owned(),
            tag_names: Vec::new(),
            is_pinned: false,
            is_archived: false,
            created_at_micros_utc: now_micros_utc,
            updated_at_micros_utc: now_micros_utc,
            created_at_raw: None,
            updated_at_raw: None,
            notebook_name: Some(book_title.clone()),
            notebook_path: None,
            attachments: Vec::new(),
            skipped_attachments: 0,
        });
    }
    if notes.is_empty() {
        return Err(CodecErrorDto::new(
            CodecErrorKindDto::InvalidInput,
            "EPUB has no readable chapters.",
        ));
    }
    enforce_text_budget(&notes)?;
    Ok(ImportBundleDto {
        notes,
        notebook_names: vec![book_title],
        notebook_paths: Vec::new(),
    })
}

fn notebook_path(
    notebook: &OblixNotebookInputDto,
    by_id: &HashMap<&str, &OblixNotebookInputDto>,
) -> Vec<String> {
    let mut path = Vec::new();
    let mut seen = HashSet::new();
    let mut current = notebook;
    while seen.insert(current.id.as_str()) {
        path.insert(0, current.name.clone());
        let Some(parent_id) = current.parent_id.as_deref() else {
            break;
        };
        let Some(parent) = by_id.get(parent_id) else {
            break;
        };
        current = parent;
    }
    path
}

fn attachment_extension(original_name: &str) -> String {
    let Some(dot) = original_name.rfind('.') else {
        return String::new();
    };
    if dot == 0 || dot + 1 == original_name.len() {
        return String::new();
    }
    original_name[dot..].to_lowercase()
}

fn validate_archive_id_segment(value: &str, label: &str) -> CodecResult<()> {
    if value.is_empty()
        || value == "."
        || value == ".."
        || value.contains('/')
        || value.contains('\\')
        || value.contains(':')
        || value.contains('\0')
    {
        return Err(CodecErrorDto::new(
            CodecErrorKindDto::UnsafeArchivePath,
            format!("{label} cannot safely be used in an archive path."),
        ));
    }
    Ok(())
}

fn attachment_blob_ref(note_id: &str, attachment: &OblixAttachmentInputDto) -> CodecResult<String> {
    validate_archive_id_segment(note_id, "Note id")?;
    validate_archive_id_segment(&attachment.id, "Attachment id")?;
    let reference = format!(
        "files/{note_id}/{}{}",
        attachment.id,
        attachment_extension(&attachment.original_name)
    );
    validate_archive_path(&reference, false)?;
    Ok(reference)
}

fn value_string(value: impl Into<String>) -> Value {
    Value::String(value.into())
}

fn value_string_array(values: &[String]) -> Value {
    Value::Array(values.iter().cloned().map(Value::String).collect())
}

/// Encode the v2 native Oblix archive. Input ordering is retained. Broken or
/// cyclic notebook parent links truncate exactly like the Dart path walker.
#[frb(sync)]
pub fn encode_oblix_archive(request: OblixEncodeRequestDto) -> Result<Vec<u8>, CodecErrorDto> {
    if request.notes.len() > MAX_NOTES {
        return Err(CodecErrorDto::new(
            CodecErrorKindDto::LimitExceeded,
            format!("Export contains more than {MAX_NOTES} notes."),
        ));
    }
    utc_datetime_from_micros(request.exported_at_micros_utc)?;

    let mut total_text = 0usize;
    for note in &request.notes {
        let units = utf16_len(&note.title)
            .checked_add(utf16_len(&note.content))
            .ok_or_else(|| {
                CodecErrorDto::new(
                    CodecErrorKindDto::LimitExceeded,
                    "Export text size overflowed.",
                )
            })?;
        if units > MAX_NOTE_TEXT_UTF16_UNITS {
            return Err(CodecErrorDto::new(
                CodecErrorKindDto::LimitExceeded,
                "An exported note exceeds the safe UTF-16 text limit.",
            ));
        }
        total_text = total_text.checked_add(units).ok_or_else(|| {
            CodecErrorDto::new(
                CodecErrorKindDto::LimitExceeded,
                "Export text size overflowed.",
            )
        })?;
        if total_text > MAX_TOTAL_TEXT_UTF16_UNITS {
            return Err(CodecErrorDto::new(
                CodecErrorKindDto::LimitExceeded,
                "Export text exceeds the safe total UTF-16 limit.",
            ));
        }
    }

    let mut groups_by_note = HashMap::with_capacity(request.attachment_groups.len());
    let mut attachment_count = 0usize;
    for group in &request.attachment_groups {
        if groups_by_note
            .insert(group.note_id.as_str(), &group.attachments)
            .is_some()
        {
            return Err(CodecErrorDto::new(
                CodecErrorKindDto::InvalidInput,
                format!("Duplicate attachment group for note {}.", group.note_id),
            ));
        }
        attachment_count = attachment_count
            .checked_add(group.attachments.len())
            .ok_or_else(|| {
                CodecErrorDto::new(
                    CodecErrorKindDto::LimitExceeded,
                    "Attachment count overflowed.",
                )
            })?;
    }
    if attachment_count > MAX_ATTACHMENTS {
        return Err(CodecErrorDto::new(
            CodecErrorKindDto::LimitExceeded,
            format!("Export contains more than {MAX_ATTACHMENTS} attachments."),
        ));
    }

    // Dart's map comprehension gives the last duplicate notebook id priority.
    let mut notebooks_by_id = HashMap::with_capacity(request.notebooks.len());
    for notebook in &request.notebooks {
        notebooks_by_id.insert(notebook.id.as_str(), notebook);
    }
    let mut paths_by_id = HashMap::with_capacity(request.notebooks.len());
    for notebook in &request.notebooks {
        paths_by_id.insert(
            notebook.id.clone(),
            notebook_path(notebook, &notebooks_by_id),
        );
    }

    let mut note_values = Vec::with_capacity(request.notes.len());
    let mut attachment_entries = Vec::new();
    let mut generated_blob_names = HashSet::new();
    for note in &request.notes {
        let mut object = Map::new();
        object.insert("title".to_owned(), value_string(&note.title));
        object.insert("content".to_owned(), value_string(&note.content));
        object.insert("content_type".to_owned(), value_string(&note.content_type));
        object.insert("tags".to_owned(), value_string_array(&note.tag_names));
        object.insert("is_pinned".to_owned(), Value::Bool(note.is_pinned));
        object.insert("is_archived".to_owned(), Value::Bool(note.is_archived));
        object.insert(
            "notebook_path".to_owned(),
            note.notebook_id
                .as_ref()
                .and_then(|id| paths_by_id.get(id))
                .map_or(Value::Null, |path| value_string_array(path)),
        );

        if let Some(attachments) = groups_by_note.get(note.id.as_str()) {
            if !attachments.is_empty() {
                let mut attachment_values = Vec::with_capacity(attachments.len());
                for attachment in attachments.iter() {
                    let reference = attachment_blob_ref(&note.id, attachment)?;
                    if !generated_blob_names.insert(reference.clone()) {
                        return Err(CodecErrorDto::new(
                            CodecErrorKindDto::InvalidInput,
                            format!("Duplicate generated attachment path {reference}."),
                        ));
                    }
                    let mut attachment_object = Map::new();
                    attachment_object.insert("ref".to_owned(), value_string(&reference));
                    attachment_object.insert(
                        "original_name".to_owned(),
                        value_string(&attachment.original_name),
                    );
                    attachment_object
                        .insert("mime_type".to_owned(), value_string(&attachment.mime_type));
                    attachment_values.push(Value::Object(attachment_object));
                    attachment_entries.push(WriteZipEntry {
                        name: reference,
                        bytes: attachment.bytes.clone(),
                        compression: CompressionMethod::Deflated,
                    });
                }
                object.insert("attachments".to_owned(), Value::Array(attachment_values));
            }
        }
        object.insert(
            "created_at".to_owned(),
            value_string(note.created_at_iso_utc.as_str()),
        );
        object.insert(
            "updated_at".to_owned(),
            value_string(note.updated_at_iso_utc.as_str()),
        );
        note_values.push(Value::Object(object));
    }

    let notebook_values = request
        .notebooks
        .iter()
        .map(|notebook| {
            let mut object = Map::new();
            object.insert("name".to_owned(), value_string(&notebook.name));
            object.insert(
                "sort_order".to_owned(),
                Value::Number(notebook.sort_order.into()),
            );
            object.insert(
                "path".to_owned(),
                paths_by_id
                    .get(&notebook.id)
                    .map_or(Value::Null, |path| value_string_array(path)),
            );
            Value::Object(object)
        })
        .collect();
    let tag_values = request
        .tag_names
        .iter()
        .map(|name| {
            let mut object = Map::new();
            object.insert("name".to_owned(), value_string(name));
            Value::Object(object)
        })
        .collect();
    let mut data = Map::new();
    data.insert("notes".to_owned(), Value::Array(note_values));
    data.insert("notebooks".to_owned(), Value::Array(notebook_values));
    data.insert("tags".to_owned(), Value::Array(tag_values));

    let mut counts = Map::new();
    counts.insert(
        "notes".to_owned(),
        Value::Number((request.notes.len() as u64).into()),
    );
    counts.insert(
        "notebooks".to_owned(),
        Value::Number((request.notebooks.len() as u64).into()),
    );
    counts.insert(
        "tags".to_owned(),
        Value::Number((request.tag_names.len() as u64).into()),
    );
    counts.insert(
        "attachments".to_owned(),
        Value::Number((attachment_count as u64).into()),
    );
    let mut manifest = Map::new();
    manifest.insert("format".to_owned(), value_string(OBLIX_FORMAT_ID));
    manifest.insert(
        "version".to_owned(),
        Value::Number(OBLIX_FORMAT_VERSION.into()),
    );
    manifest.insert("app".to_owned(), value_string("Oblix"));
    manifest.insert(
        "exported_at".to_owned(),
        value_string(format_dart_iso_utc(request.exported_at_micros_utc)?),
    );
    manifest.insert("counts".to_owned(), Value::Object(counts));

    let manifest_bytes = serde_json::to_vec_pretty(&Value::Object(manifest)).map_err(|error| {
        CodecErrorDto::new(
            CodecErrorKindDto::InvalidJson,
            format!("Cannot encode Oblix manifest: {error}"),
        )
    })?;
    let data_bytes = serde_json::to_vec_pretty(&Value::Object(data)).map_err(|error| {
        CodecErrorDto::new(
            CodecErrorKindDto::InvalidJson,
            format!("Cannot encode Oblix data: {error}"),
        )
    })?;
    if manifest_bytes.len() > MAX_XML_OR_JSON_BYTES || data_bytes.len() > MAX_XML_OR_JSON_BYTES {
        return Err(CodecErrorDto::new(
            CodecErrorKindDto::LimitExceeded,
            "Oblix JSON exceeds the safe text-entry limit.",
        ));
    }

    let mut entries = vec![
        WriteZipEntry {
            name: OBLIX_MANIFEST_NAME.to_owned(),
            bytes: manifest_bytes,
            compression: CompressionMethod::Deflated,
        },
        WriteZipEntry {
            name: OBLIX_DATA_NAME.to_owned(),
            bytes: data_bytes,
            compression: CompressionMethod::Deflated,
        },
    ];
    entries.extend(attachment_entries);
    write_zip(entries)
}

fn optional_array<'a>(object: &'a Map<String, Value>, key: &str) -> CodecResult<&'a [Value]> {
    match object.get(key) {
        None | Some(Value::Null) => Ok(&[]),
        Some(Value::Array(values)) => Ok(values),
        Some(_) => Err(CodecErrorDto::new(
            CodecErrorKindDto::InvalidJson,
            format!("Oblix field {key} must be an array."),
        )),
    }
}

fn optional_string(object: &Map<String, Value>, key: &str) -> CodecResult<Option<String>> {
    match object.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) => Ok(Some(value.clone())),
        Some(_) => Err(CodecErrorDto::new(
            CodecErrorKindDto::InvalidJson,
            format!("Oblix field {key} must be a string or null."),
        )),
    }
}

fn string_or(object: &Map<String, Value>, key: &str, fallback: &str) -> CodecResult<String> {
    Ok(optional_string(object, key)?.unwrap_or_else(|| fallback.to_owned()))
}

fn bool_or(object: &Map<String, Value>, key: &str, fallback: bool) -> CodecResult<bool> {
    match object.get(key) {
        None | Some(Value::Null) => Ok(fallback),
        Some(Value::Bool(value)) => Ok(*value),
        Some(_) => Err(CodecErrorDto::new(
            CodecErrorKindDto::InvalidJson,
            format!("Oblix field {key} must be a boolean or null."),
        )),
    }
}

fn dart_value_to_string(value: &Value) -> String {
    match value {
        Value::Null => "null".to_owned(),
        Value::Bool(value) => value.to_string(),
        Value::Number(value) => value.to_string(),
        Value::String(value) => value.clone(),
        Value::Array(values) => format!(
            "[{}]",
            values
                .iter()
                .map(dart_value_to_string)
                .collect::<Vec<_>>()
                .join(", ")
        ),
        Value::Object(object) => format!(
            "{{{}}}",
            object
                .iter()
                .map(|(key, value)| format!("{key}: {}", dart_value_to_string(value)))
                .collect::<Vec<_>>()
                .join(", ")
        ),
    }
}

fn dart_string_list(value: Option<&Value>) -> Option<Vec<String>> {
    let Value::Array(values) = value? else {
        return None;
    };
    let output: Vec<String> = values
        .iter()
        .map(dart_value_to_string)
        .filter(|value| !value.is_empty())
        .collect();
    (!output.is_empty()).then_some(output)
}

fn object<'a>(value: &'a Value, label: &str) -> CodecResult<&'a Map<String, Value>> {
    value.as_object().ok_or_else(|| {
        CodecErrorDto::new(
            CodecErrorKindDto::InvalidJson,
            format!("{label} must be a JSON object."),
        )
    })
}

/// Decode v1 or v2 native Oblix archives. Note timestamps remain raw for Dart
/// to parse with `DateTime.tryParse`; missing attachment blobs increment
/// `skipped_attachments`, while malformed metadata and unsafe ZIPs return typed
/// errors.
#[frb(sync)]
pub fn decode_oblix_archive(
    request: OblixDecodeRequestDto,
) -> Result<ImportBundleDto, CodecErrorDto> {
    utc_datetime_from_micros(request.now_micros_utc)?;
    let archive = read_zip(&request.bytes)?;
    if let Some(manifest_raw) = read_utf8_entry(&archive, OBLIX_MANIFEST_NAME)? {
        let manifest_value: Value = serde_json::from_str(manifest_raw).map_err(|error| {
            CodecErrorDto::new(
                CodecErrorKindDto::InvalidJson,
                format!("Invalid Oblix manifest JSON: {error}"),
            )
        })?;
        let manifest = object(&manifest_value, "Oblix manifest")?;
        if optional_string(manifest, "format")?.as_deref() != Some(OBLIX_FORMAT_ID) {
            return Err(CodecErrorDto::new(
                CodecErrorKindDto::InvalidInput,
                "Not an Oblix export.",
            ));
        }
        let version = match manifest.get("version") {
            None | Some(Value::Null) => 0,
            Some(Value::Number(value)) => value.as_i64().ok_or_else(|| {
                CodecErrorDto::new(
                    CodecErrorKindDto::InvalidJson,
                    "Oblix manifest version must be an integer.",
                )
            })?,
            Some(_) => {
                return Err(CodecErrorDto::new(
                    CodecErrorKindDto::InvalidJson,
                    "Oblix manifest version must be an integer.",
                ))
            }
        };
        if version > OBLIX_FORMAT_VERSION {
            return Err(CodecErrorDto::new(
                CodecErrorKindDto::UnsupportedVersion,
                "This .oblix file was made by a newer version of Oblix.",
            ));
        }
    }

    let data_raw = read_utf8_entry(&archive, OBLIX_DATA_NAME)?.ok_or_else(|| {
        CodecErrorDto::new(
            CodecErrorKindDto::MissingEntry,
            "Corrupt .oblix file (no data).",
        )
    })?;
    let data_value: Value = serde_json::from_str(data_raw).map_err(|error| {
        CodecErrorDto::new(
            CodecErrorKindDto::InvalidJson,
            format!("Invalid Oblix data JSON: {error}"),
        )
    })?;
    let data = object(&data_value, "Oblix data")?;

    let mut notebook_names = Vec::new();
    let mut notebook_paths = Vec::new();
    for raw_notebook in optional_array(data, "notebooks")? {
        let notebook = object(raw_notebook, "Oblix notebook")?;
        if let Some(path) = dart_string_list(notebook.get("path")) {
            notebook_paths.push(path);
        } else if let Some(name) = optional_string(notebook, "name")? {
            if !name.is_empty() {
                notebook_names.push(name);
            }
        }
    }

    let note_values = optional_array(data, "notes")?;
    if note_values.len() > MAX_NOTES {
        return Err(CodecErrorDto::new(
            CodecErrorKindDto::LimitExceeded,
            format!("Archive contains more than {MAX_NOTES} notes."),
        ));
    }
    let mut notes = Vec::with_capacity(note_values.len());
    let mut attachment_count = 0usize;
    for raw_note in note_values {
        let note = object(raw_note, "Oblix note")?;
        // `Some("")` deliberately distinguishes an Oblix missing/null value
        // from ENEX/EPUB's `None`; Dart will apply its exact fallback order.
        let created_at_raw = Some(optional_string(note, "created_at")?.unwrap_or_default());
        let updated_at_raw = Some(optional_string(note, "updated_at")?.unwrap_or_default());

        let mut attachments = Vec::new();
        let mut skipped_attachments = 0i32;
        for raw_attachment in optional_array(note, "attachments")? {
            attachment_count = attachment_count.checked_add(1).ok_or_else(|| {
                CodecErrorDto::new(
                    CodecErrorKindDto::LimitExceeded,
                    "Attachment count overflowed.",
                )
            })?;
            if attachment_count > MAX_ATTACHMENTS {
                return Err(CodecErrorDto::new(
                    CodecErrorKindDto::LimitExceeded,
                    format!("Archive contains more than {MAX_ATTACHMENTS} attachments."),
                ));
            }
            let attachment = object(raw_attachment, "Oblix attachment")?;
            let reference = optional_string(attachment, "ref")?;
            let file = if let Some(reference) = reference.as_deref() {
                validate_archive_path(reference, false)?;
                archive.get(reference)
            } else {
                None
            };
            let Some(file) = file else {
                skipped_attachments = skipped_attachments.checked_add(1).ok_or_else(|| {
                    CodecErrorDto::new(
                        CodecErrorKindDto::LimitExceeded,
                        "Skipped attachment count overflowed.",
                    )
                })?;
                continue;
            };
            attachments.push(ImportedAttachmentDto {
                original_name: string_or(attachment, "original_name", "file")?,
                mime_type: optional_string(attachment, "mime_type")?,
                bytes: file.bytes.clone(),
            });
        }

        let tag_names = optional_array(note, "tags")?
            .iter()
            .map(dart_value_to_string)
            .collect();
        notes.push(ImportedNoteDto {
            title: string_or(note, "title", "Untitled")?,
            content: string_or(note, "content", "")?,
            content_type: string_or(note, "content_type", "plain")?,
            tag_names,
            is_pinned: bool_or(note, "is_pinned", false)?,
            is_archived: bool_or(note, "is_archived", false)?,
            created_at_micros_utc: request.now_micros_utc,
            updated_at_micros_utc: request.now_micros_utc,
            created_at_raw,
            updated_at_raw,
            notebook_name: optional_string(note, "notebook_name")?,
            notebook_path: dart_string_list(note.get("notebook_path")),
            attachments,
            skipped_attachments,
        });
    }
    enforce_text_budget(&notes)?;
    Ok(ImportBundleDto {
        notes,
        notebook_names,
        notebook_paths,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn micros(year: i32, month: u32, day: u32, hour: u32, minute: u32, second: u32) -> i64 {
        let value = Utc
            .with_ymd_and_hms(year, month, day, hour, minute, second)
            .single()
            .expect("test timestamp must be valid");
        datetime_to_micros(value).expect("test timestamp must fit")
    }

    #[test]
    fn utf16_budget_counts_supplementary_characters_like_dart() {
        assert_eq!(utf16_len("A😀B"), 4);
    }

    #[test]
    fn enex_parses_notes_timestamps_tags_pinning_and_malformed_enml() {
        let now = micros(2026, 7, 13, 12, 0, 0);
        let source = r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE en-export SYSTEM "http://xml.evernote.com/pub/evernote-export4.dtd">
<en-export>
  <note>
    <title> Shopping list </title>
    <content><![CDATA[<en-note><div>Milk</div><div>Eggs</div><div>Bread</div></en-note>]]></content>
    <created>20230115T101500Z</created>
    <updated>20230116T110000Z</updated>
    <tag>groceries</tag><tag> home </tag>
    <note-attributes><reminder-order>1</reminder-order></note-attributes>
    <resource><data>AAAA</data></resource>
  </note>
  <note>
    <title>Broken</title>
    <content><![CDATA[<en-note><div>Unclosed <b>bold</div></en-note>]]></content>
  </note>
</en-export>"#;
        let bundle = parse_enex(source.to_owned(), Some("Imported".to_owned()), now)
            .expect("ENEX should parse");
        assert_eq!(bundle.notebook_names, vec!["Imported"]);
        assert_eq!(bundle.notes.len(), 2);
        assert_eq!(bundle.notes[0].title, "Shopping list");
        assert_eq!(bundle.notes[0].content, "Milk\nEggs\nBread");
        assert_eq!(bundle.notes[0].tag_names, vec!["groceries", "home"]);
        assert!(bundle.notes[0].is_pinned);
        assert_eq!(bundle.notes[0].skipped_attachments, 1);
        assert_eq!(
            bundle.notes[0].created_at_micros_utc,
            micros(2023, 1, 15, 10, 15, 0)
        );
        assert_eq!(
            bundle.notes[0].updated_at_micros_utc,
            micros(2023, 1, 16, 11, 0, 0)
        );
        assert!(bundle.notes[1].content.contains("bold"));
        assert_eq!(bundle.notes[1].created_at_micros_utc, now);
        assert_eq!(bundle.notes[1].updated_at_micros_utc, now);
    }

    #[test]
    fn enex_timestamp_normalizes_overflow_like_datetime_utc() {
        assert_eq!(
            parse_enex_timestamp(Some("20231301T000000Z")),
            Some(micros(2024, 1, 1, 0, 0, 0))
        );
        assert_eq!(
            parse_enex_timestamp(Some("20230101T240000Z")),
            Some(micros(2023, 1, 2, 0, 0, 0))
        );
    }

    #[test]
    fn codecs_match_dart_bom_trimming() {
        let now = micros(2026, 7, 13, 12, 0, 0);
        let source = "<en-export><note>\
            <title>\u{feff}</title>\
            <content><![CDATA[<en-note><div>Body\u{feff}</div></en-note>]]></content>\
            <tag>\u{feff}work\u{feff}</tag>\
            <note-attributes><reminder-order>\u{feff}</reminder-order></note-attributes>\
            </note></en-export>";
        let bundle = parse_enex(source.to_owned(), None, now).expect("ENEX should parse");
        assert_eq!(bundle.notes[0].title, "Untitled");
        assert_eq!(bundle.notes[0].content, "Body");
        assert_eq!(bundle.notes[0].tag_names, vec!["work"]);
        assert!(!bundle.notes[0].is_pinned);

        let error = export_epub(EpubExportRequestDto {
            notes: Vec::new(),
            exported_at_micros_utc: now,
            book_uuid: "\u{feff}".to_owned(),
        })
        .expect_err("a BOM-only UUID is empty under Dart trim semantics");
        assert_eq!(error.kind, CodecErrorKindDto::InvalidInput);
    }

    #[test]
    fn epub_export_is_well_shaped_and_round_trips_current_flattening_semantics() {
        let now = micros(2026, 7, 14, 0, 0, 0);
        let bytes = export_epub(EpubExportRequestDto {
            notes: vec![
                EpubNoteInputDto {
                    title: "Chapter One".to_owned(),
                    content: "First paragraph.\n\nSecond paragraph.".to_owned(),
                },
                EpubNoteInputDto {
                    title: "Chapter & Two".to_owned(),
                    content: "More <text>.".to_owned(),
                },
            ],
            exported_at_micros_utc: now,
            book_uuid: "12345678-1234-4234-8234-123456789abc".to_owned(),
        })
        .expect("EPUB should encode");
        let archive = read_zip(&bytes).expect("EPUB ZIP should decode");
        assert_eq!(archive.entries[0].name, "mimetype");
        assert_eq!(archive.entries[0].compression, CompressionMethod::Stored);
        assert_eq!(archive.entries[0].bytes, EPUB_MEDIA_TYPE.as_bytes());
        let opf = read_utf8_entry(&archive, "OEBPS/content.opf")
            .expect("OPF should be UTF-8")
            .expect("OPF should exist");
        assert!(opf.contains("urn:uuid:12345678-1234-4234-8234-123456789abc"));
        assert!(opf.contains("2026-07-14T00:00:00Z"));

        let bundle = import_epub(bytes, now).expect("EPUB should import");
        assert_eq!(bundle.notebook_names, vec!["Oblix export 2026-07-14"]);
        assert_eq!(bundle.notes.len(), 2);
        assert_eq!(bundle.notes[0].title, "Chapter One");
        // The Dart walker includes formatting whitespace plus both
        // <head><title> and <body><h1>, then collapses blank-line runs to one.
        assert_eq!(
            bundle.notes[0].content,
            "Chapter One\n\nChapter One\n\nFirst paragraph.\n\nSecond paragraph."
        );
        assert_eq!(bundle.notes[1].title, "Chapter & Two");
        assert!(bundle.notes[1].content.contains("More <text>."));
    }

    fn sample_oblix_request(now: i64) -> OblixEncodeRequestDto {
        let timestamp = format_dart_iso_utc(now).expect("sample timestamp should format");
        OblixEncodeRequestDto {
            notes: vec![
                OblixNoteInputDto {
                    id: "n1".to_owned(),
                    notebook_id: Some("nb2".to_owned()),
                    title: "Hello".to_owned(),
                    content: "World 😀".to_owned(),
                    content_type: "plain".to_owned(),
                    tag_names: vec!["a".to_owned(), "b".to_owned()],
                    is_pinned: true,
                    is_archived: false,
                    created_at_iso_utc: timestamp.clone(),
                    updated_at_iso_utc: timestamp.clone(),
                },
                OblixNoteInputDto {
                    id: "n2".to_owned(),
                    notebook_id: None,
                    title: "Loose note".to_owned(),
                    content: "no notebook".to_owned(),
                    content_type: "markdown".to_owned(),
                    tag_names: Vec::new(),
                    is_pinned: false,
                    is_archived: true,
                    created_at_iso_utc: timestamp.clone(),
                    updated_at_iso_utc: timestamp,
                },
            ],
            notebooks: vec![
                OblixNotebookInputDto {
                    id: "nb1".to_owned(),
                    name: "Work".to_owned(),
                    parent_id: None,
                    sort_order: 0,
                },
                OblixNotebookInputDto {
                    id: "nb2".to_owned(),
                    name: "Projects".to_owned(),
                    parent_id: Some("nb1".to_owned()),
                    sort_order: 1,
                },
            ],
            tag_names: vec!["a".to_owned()],
            attachment_groups: vec![OblixAttachmentGroupInputDto {
                note_id: "n1".to_owned(),
                attachments: vec![OblixAttachmentInputDto {
                    id: "att1".to_owned(),
                    original_name: "FILE.TXT".to_owned(),
                    mime_type: "text/plain".to_owned(),
                    bytes: b"hello".to_vec(),
                }],
            }],
            exported_at_micros_utc: now,
        }
    }

    #[test]
    fn oblix_v2_round_trip_preserves_paths_metadata_and_attachments() {
        let now = micros(2026, 7, 13, 12, 0, 0);
        let bytes =
            encode_oblix_archive(sample_oblix_request(now)).expect("Oblix archive should encode");
        let archive = read_zip(&bytes).expect("Oblix ZIP should decode");
        assert!(archive.get("files/n1/att1.txt").is_some());
        let manifest: Value = serde_json::from_str(
            read_utf8_entry(&archive, OBLIX_MANIFEST_NAME)
                .expect("manifest should be UTF-8")
                .expect("manifest should exist"),
        )
        .expect("manifest should be JSON");
        assert_eq!(manifest["version"], 2);
        assert_eq!(manifest["exported_at"], "2026-07-13T12:00:00.000Z");

        let bundle = decode_oblix_archive(OblixDecodeRequestDto {
            bytes,
            now_micros_utc: now + 1,
        })
        .expect("Oblix archive should decode");
        assert_eq!(bundle.notes.len(), 2);
        assert_eq!(
            bundle.notebook_paths,
            vec![
                vec!["Work".to_owned()],
                vec!["Work".to_owned(), "Projects".to_owned()]
            ]
        );
        let first = &bundle.notes[0];
        assert_eq!(
            first.notebook_path,
            Some(vec!["Work".to_owned(), "Projects".to_owned()])
        );
        assert_eq!(first.tag_names, vec!["a", "b"]);
        assert!(first.is_pinned);
        assert_eq!(first.attachments.len(), 1);
        assert_eq!(first.attachments[0].original_name, "FILE.TXT");
        assert_eq!(first.attachments[0].bytes, b"hello");
        assert_eq!(
            first.created_at_raw.as_deref(),
            Some("2026-07-13T12:00:00.000Z")
        );
        assert_eq!(
            first.updated_at_raw.as_deref(),
            Some("2026-07-13T12:00:00.000Z")
        );
        assert_eq!(bundle.notes[1].notebook_path, None);
        assert!(bundle.notes[1].is_archived);
    }

    #[test]
    fn oblix_encoder_preserves_full_dart_sort_order_boundaries() {
        const POSITIVE_BOUNDARY: i64 = 2_147_483_648;
        const NEGATIVE_BOUNDARY: i64 = -2_147_483_649;
        let now = micros(2026, 7, 13, 12, 0, 0);
        let mut request = sample_oblix_request(now);
        request.notebooks[0].sort_order = POSITIVE_BOUNDARY;
        request.notebooks[1].sort_order = NEGATIVE_BOUNDARY;
        request.notes[0].created_at_iso_utc = "+270000-01-01T00:00:00.000Z".to_owned();

        let bytes = encode_oblix_archive(request).expect("Oblix archive should encode");
        let archive = read_zip(&bytes).expect("Oblix ZIP should decode");
        let data: Value = serde_json::from_str(
            read_utf8_entry(&archive, OBLIX_DATA_NAME)
                .expect("data should be UTF-8")
                .expect("data should exist"),
        )
        .expect("data should be JSON");
        let notebooks = data["notebooks"]
            .as_array()
            .expect("notebooks should be an array");
        assert_eq!(notebooks[0]["sort_order"].as_i64(), Some(POSITIVE_BOUNDARY));
        assert_eq!(notebooks[1]["sort_order"].as_i64(), Some(NEGATIVE_BOUNDARY));
        assert_eq!(
            data["notes"][0]["created_at"].as_str(),
            Some("+270000-01-01T00:00:00.000Z")
        );
    }

    #[test]
    fn oblix_decoder_accepts_v1_and_counts_missing_blobs() {
        let now = micros(2026, 7, 13, 12, 0, 0);
        let manifest = br#"{"format":"oblix-export","version":1}"#.to_vec();
        let data = br#"{
          "notes":[{
            "title":"Hello","content":"World","content_type":"plain",
            "tags":[],"is_pinned":false,"is_archived":false,
            "notebook_name":"Work","created_at":"2026-07-13T12:00:00.000Z",
            "updated_at":"2026-07-13T12:00:00.000Z",
            "attachments":[{"ref":"files/n1/missing.bin","original_name":"missing.bin"}]
          }],
          "notebooks":[{"name":"Work","sort_order":0}],"tags":[]
        }"#
        .to_vec();
        let bytes = write_zip(vec![
            WriteZipEntry {
                name: OBLIX_MANIFEST_NAME.to_owned(),
                bytes: manifest,
                compression: CompressionMethod::Deflated,
            },
            WriteZipEntry {
                name: OBLIX_DATA_NAME.to_owned(),
                bytes: data,
                compression: CompressionMethod::Deflated,
            },
        ])
        .expect("v1 fixture should encode");
        let bundle = decode_oblix_archive(OblixDecodeRequestDto {
            bytes,
            now_micros_utc: now,
        })
        .expect("v1 fixture should decode");
        assert_eq!(bundle.notebook_names, vec!["Work"]);
        assert_eq!(bundle.notes[0].notebook_name.as_deref(), Some("Work"));
        assert_eq!(bundle.notes[0].notebook_path, None);
        assert_eq!(bundle.notes[0].skipped_attachments, 1);
        assert!(bundle.notes[0].attachments.is_empty());
        assert_eq!(
            bundle.notes[0].created_at_raw.as_deref(),
            Some("2026-07-13T12:00:00.000Z")
        );
    }

    #[test]
    fn archive_reader_rejects_path_traversal() {
        let cursor = Cursor::new(Vec::new());
        let mut writer = ZipWriter::new(cursor);
        writer
            .start_file(
                "../manifest.json",
                SimpleFileOptions::default().compression_method(CompressionMethod::Stored),
            )
            .expect("unsafe test entry should be writable");
        writer
            .write_all(b"{}")
            .expect("unsafe test entry should be writable");
        let bytes = writer
            .finish()
            .expect("unsafe fixture ZIP should finish")
            .into_inner();
        let error = read_zip(&bytes).expect_err("path traversal must be rejected");
        assert_eq!(error.kind, CodecErrorKindDto::UnsafeArchivePath);
    }

    #[test]
    fn malformed_archives_return_typed_errors() {
        let epub_error = import_epub(vec![1, 2, 3, 4], 0).expect_err("invalid EPUB must fail");
        assert_eq!(epub_error.kind, CodecErrorKindDto::InvalidArchive);
        let oblix_error = decode_oblix_archive(OblixDecodeRequestDto {
            bytes: vec![1, 2, 3, 4],
            now_micros_utc: 0,
        })
        .expect_err("invalid Oblix archive must fail");
        assert_eq!(oblix_error.kind, CodecErrorKindDto::InvalidArchive);
    }
}
