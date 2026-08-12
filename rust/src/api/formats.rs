use std::collections::HashMap;

use flutter_rust_bridge::frb;

use crate::dart_string::{dart_trim, dart_trim_end, dart_trim_start, is_dart_regexp_whitespace};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MarkdownImportOutput {
    pub title: Option<String>,
    pub content: String,
    pub content_type: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ExportNoteInput {
    pub id: String,
    pub title: String,
    pub content: String,
    pub tag_names: Vec<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ExportTextFileOutput {
    pub filename: String,
    pub content: String,
}

/// Parse Markdown/plain text structure after Dart performs strict UTF-8 decode.
#[frb(sync)]
pub fn parse_markdown_text(text: String, filename: String) -> MarkdownImportOutput {
    let is_markdown = filename.to_lowercase().ends_with(".md");
    let normalized = text.replace("\r\n", "\n").replace('\r', "\n");
    let mut clean = Vec::new();
    let mut title = None;
    let mut heading_found = false;
    for line in normalized.split('\n') {
        if !heading_found {
            let trimmed = dart_trim_start(line);
            if trimmed.starts_with('#') && !trimmed.starts_with("##") && !dart_trim(line).is_empty()
            {
                let candidate = dart_trim(&trimmed[1..]);
                if !candidate.is_empty() {
                    title = Some(candidate.to_owned());
                }
                heading_found = true;
                continue;
            }
        }
        clean.push(line);
    }
    let content = clean.join("\n").trim_start_matches('\n').to_owned();
    MarkdownImportOutput {
        title: title.or_else(|| Some(filename_stem(&filename))),
        content,
        content_type: if is_markdown { "markdown" } else { "plain" }.to_owned(),
    }
}

#[frb(sync)]
pub fn note_to_markdown(note: ExportNoteInput) -> String {
    let title = if note.title == "Untitled" || note.title.is_empty() {
        "Untitled"
    } else {
        &note.title
    };
    let mut output = format!("# {title}\n\n{}", note.content);
    if !note.tag_names.is_empty() {
        output.push_str("\n\nTags: ");
        output.push_str(&note.tag_names.join(", "));
    }
    output
}

#[frb(sync)]
pub fn note_to_text(note: ExportNoteInput) -> String {
    let title = dart_trim(&note.title);
    let body = dart_trim_end(&note.content);
    if title.is_empty() || title == "Untitled" {
        body.to_owned()
    } else {
        format!("{title}\n\n{body}")
    }
}

#[frb(sync)]
pub fn render_markdown_files(notes: Vec<ExportNoteInput>) -> Vec<ExportTextFileOutput> {
    render_files(notes, "md", note_to_markdown)
}

#[frb(sync)]
pub fn render_text_files(notes: Vec<ExportNoteInput>) -> Vec<ExportTextFileOutput> {
    render_files(notes, "txt", note_to_text)
}

fn render_files(
    notes: Vec<ExportNoteInput>,
    extension: &str,
    render: fn(ExportNoteInput) -> String,
) -> Vec<ExportTextFileOutput> {
    let mut seen: HashMap<String, i32> = HashMap::new();
    notes
        .into_iter()
        .map(|note| {
            let stem = sanitized_stem(&note.title, &note.id);
            let base_filename = format!("{stem}.{extension}");
            let filename = if let Some(count) = seen.get_mut(&base_filename) {
                *count += 1;
                format!("{stem}-{}.{extension}", *count)
            } else {
                seen.insert(base_filename.clone(), 1);
                base_filename
            };
            ExportTextFileOutput {
                filename,
                content: render(note),
            }
        })
        .collect()
}

fn filename_stem(filename: &str) -> String {
    let base = filename.rsplit(['/', '\\']).next().unwrap_or(filename);
    match base.rfind('.') {
        Some(index) if index > 0 => base[..index].to_owned(),
        _ => base.to_owned(),
    }
}

fn sanitized_stem(title: &str, id: &str) -> String {
    let mut filtered = String::new();
    for character in title.to_lowercase().chars() {
        if character.is_ascii_lowercase()
            || character.is_ascii_digit()
            || character == '-'
            || character == '_'
            || is_dart_regexp_whitespace(character)
        {
            filtered.push(character);
        }
    }

    let mut stem = String::new();
    let mut in_whitespace = false;
    for character in filtered.chars() {
        if is_dart_regexp_whitespace(character) {
            if !in_whitespace {
                stem.push('-');
                in_whitespace = true;
            }
        } else {
            stem.push(character);
            in_whitespace = false;
        }
    }
    if stem.is_empty() {
        stem.push_str("untitled");
    }
    if stem.len() > 60 {
        stem.truncate(60);
        while stem.ends_with('-') {
            stem.pop();
        }
    }
    let suffix = if id.len() >= 6 {
        &id[id.len() - 6..]
    } else {
        id
    };
    format!("{stem}-{suffix}")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn note(id: &str, title: &str, content: &str) -> ExportNoteInput {
        ExportNoteInput {
            id: id.to_owned(),
            title: title.to_owned(),
            content: content.to_owned(),
            tag_names: vec!["one".to_owned(), "two".to_owned()],
        }
    }

    #[test]
    fn parses_first_level_heading_and_normalizes_newlines() {
        let output = parse_markdown_text(
            "intro\r\n# Heading\r\n\r\nbody".to_owned(),
            "fallback.MD".to_owned(),
        );
        assert_eq!(output.title.as_deref(), Some("Heading"));
        assert_eq!(output.content, "intro\n\nbody");
        assert_eq!(output.content_type, "markdown");
    }

    #[test]
    fn renders_markdown_and_text_contracts() {
        let input = note("123456", "Title", "body  \n");
        assert_eq!(
            note_to_markdown(input.clone()),
            "# Title\n\nbody  \n\n\nTags: one, two"
        );
        assert_eq!(note_to_text(input), "Title\n\nbody");
    }

    #[test]
    fn assigns_unique_duplicate_filenames() {
        let files = render_text_files(vec![
            note("123456", "Same", "a"),
            note("123456", "Same", "b"),
            note("123456", "Same", "c"),
        ]);
        assert_eq!(
            files
                .iter()
                .map(|file| file.filename.as_str())
                .collect::<Vec<_>>(),
            vec!["same-123456.txt", "same-123456-2.txt", "same-123456-3.txt"]
        );
    }

    #[test]
    fn markdown_and_text_shaping_match_dart_bom_whitespace() {
        let parsed = parse_markdown_text(
            "\u{feff}# \u{feff}Heading\u{feff}\n\nBody".to_owned(),
            "note.md".to_owned(),
        );
        assert_eq!(parsed.title.as_deref(), Some("Heading"));

        assert_eq!(
            note_to_text(note("123456", "\u{feff}", "body\u{feff}")),
            "body"
        );
        assert_eq!(
            render_text_files(vec![note("123456", "\u{feff}A\u{0085}B\u{feff}", "body",)])[0]
                .filename,
            "-ab--123456.txt"
        );
    }
}
