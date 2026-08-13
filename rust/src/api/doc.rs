//! Writing reconstructed rows out as a document.
//!
//! [`crate::api::ocr`] answers *where everything was*; this module answers
//! *what it was*. A row that is taller than its neighbours and sits alone is a
//! heading. A run of rows that each begin with a bullet is a list. A run of
//! rows whose pieces line up in the same places down the page is a table — and
//! a table is worth drawing as a table, because the alignment carried meaning
//! that a flattened line of text throws away.
//!
//! Output is Markdown, which is one of the note content types, but only when
//! structure was actually found: a page of plain prose comes back as plain
//! prose rather than as Markdown that happens to contain no markup. The caller
//! reads [`Rendered::markdown`] to know which it got.

use crate::api::ocr::{Reconstruction, Row, RowCell};
use crate::dart_string::dart_trim;

/// A row this much taller than the body text is a heading, and this much
/// taller again is a top-level one.
const HEADING_RATIO: f32 = 1.22;
const H1_RATIO: f32 = 1.55;
const H2_RATIO: f32 = 1.32;

/// A heading is a short line. Past this share of the content width it is more
/// likely to be an opening sentence set in a larger face.
const HEADING_MAX_FILL: f32 = 0.75;

/// Fewest rows that can make a table. Two rows of aligned text are far more
/// often a heading over a line of prose than they are a table.
const MIN_TABLE_ROWS: usize = 3;

/// Fewest columns. One column is a list, not a table.
const MIN_TABLE_COLUMNS: usize = 2;

/// Share of a run's rows that must have a cell at an x position before that
/// position counts as a real column of the table.
const TABLE_COLUMN_SHARE: f32 = 0.6;

/// Share of a column's populated cells that must parse as a number before the
/// column is right-aligned in the drawn table.
const NUMERIC_COLUMN_SHARE: f32 = 0.7;

/// Indent, in median line heights, at which a block reads as a block quote.
const QUOTE_INDENT_RATIO: f32 = 1.5;

/// Change in indent, in median line heights, that starts a new block.
///
/// Deliberately larger than [QUOTE_INDENT_RATIO]: books indent the first line
/// of every paragraph by an em or so, and splitting a block there would cut
/// each paragraph's opening line off from the rest of it. A quotation is set
/// in by more than that, which is what makes it visible as a quotation.
const INDENT_BREAK_RATIO: f32 = 2.0;

/// What the writer should do, after the preset has had its say.
pub(crate) struct RenderOptions {
    pub preserve_line_breaks: bool,
    pub detect_structure: bool,
    pub detect_tables: bool,
    pub heal_across_pages: bool,
    /// Wrap the whole document in a code fence and change nothing inside it.
    pub code_block: bool,
    /// Emphasise the label half of `label: value` rows.
    pub label_values: bool,
    pub paragraph_gap: f32,
    pub median_height: f32,
    pub content_left: f32,
    pub content_right: f32,
}

/// The written document and what was found in it.
pub(crate) struct Rendered {
    pub body: String,
    /// Whether [body] uses Markdown. False for plain prose.
    pub markdown: bool,
    pub tables: usize,
    pub headings: usize,
}

/// A block and the page it began on, which is what page healing turns on.
#[derive(Debug)]
struct PlacedBlock {
    block: Block,
    page: usize,
}

/// One run of rows that belong together.
#[derive(Debug)]
enum Block {
    Heading { level: usize, text: String },
    Paragraph { text: String, healable: bool },
    Quote { text: String },
    List { items: Vec<ListItem> },
    Table { span: TableSpan },
    Lines { lines: Vec<String> },
}

#[derive(Debug)]
struct ListItem {
    ordered: bool,
    text: String,
}

/// Which edge of a cell the table lines its columns up on.
///
/// Text columns line up on the left; a column of figures is very often set
/// flush right instead, so its left edges scatter with the width of each
/// number while its right edges are dead straight. Looking at only one edge
/// would miss half the tables on an invoice.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ColumnAnchor {
    Left,
    Right,
}

#[derive(Clone, Debug)]
struct TableSpan {
    start: usize,
    end: usize,
    /// The anchored edge of each detected column, in order.
    columns: Vec<f32>,
    anchor: ColumnAnchor,
}

fn cell_anchor(cell: &RowCell, anchor: ColumnAnchor) -> f32 {
    match anchor {
        ColumnAnchor::Left => cell.left,
        ColumnAnchor::Right => cell.right,
    }
}

pub(crate) fn render(reconstruction: &Reconstruction, options: &RenderOptions) -> Rendered {
    let rows = &reconstruction.rows;
    if rows.is_empty() {
        return Rendered {
            body: String::new(),
            markdown: false,
            tables: 0,
            headings: 0,
        };
    }

    if options.code_block {
        let inner: Vec<&str> = rows.iter().map(|row| row.text.as_str()).collect();
        return Rendered {
            body: format!("```\n{}\n```", inner.join("\n")),
            markdown: true,
            tables: 0,
            headings: 0,
        };
    }

    let body_height = median_height(rows);
    let tables = if options.detect_tables {
        find_tables(rows, options)
    } else {
        Vec::new()
    };
    let blocks = build_blocks(rows, &tables, body_height, options);
    write(rows, blocks, options)
}

fn median_height(rows: &[Row]) -> f32 {
    let mut heights: Vec<f32> = rows.iter().map(|row| row.height).collect();
    heights.sort_by(f32::total_cmp);
    if heights.is_empty() {
        return 0.0;
    }
    heights[heights.len() / 2]
}

// --- Tables ---------------------------------------------------------------

/// Find the runs of rows that are drawn as tables.
///
/// The signal that separates a table from a two-column article is *repetition*:
/// in a table the pieces of every row start at the same handful of x positions,
/// row after row. Two paragraphs side by side share a gutter but their lines
/// start wherever the words happened to fall.
fn find_tables(rows: &[Row], options: &RenderOptions) -> Vec<TableSpan> {
    let mut spans: Vec<TableSpan> = Vec::new();
    let mut start = 0usize;
    while start < rows.len() {
        // A table lives inside one page, band and column, and every row of it
        // has more than one piece.
        let mut end = start;
        while end < rows.len()
            && rows[end].cells.len() >= MIN_TABLE_COLUMNS
            && same_frame(&rows[start], &rows[end])
            && (end == start || !paragraph_break(&rows[end - 1], &rows[end], options))
        {
            end += 1;
        }

        // Try the longest run first, then shorter ones, so a table with a
        // stray note stuck to the bottom is still found — and if nothing here
        // validates, move on by one row rather than skipping the whole run,
        // which would lose a table that starts a little further down.
        let mut found = None;
        let mut candidate = end;
        while candidate >= start + MIN_TABLE_ROWS {
            if let Some((columns, anchor)) = table_columns(&rows[start..candidate], options) {
                found = Some(TableSpan {
                    start,
                    end: candidate,
                    columns,
                    anchor,
                });
                break;
            }
            candidate -= 1;
        }
        match found {
            Some(span) => {
                start = span.end;
                spans.push(span);
            }
            None => start += 1,
        }
    }
    spans
}

fn same_frame(a: &Row, b: &Row) -> bool {
    a.page == b.page && a.band == b.band && a.column == b.column
}

fn paragraph_break(previous: &Row, row: &Row, options: &RenderOptions) -> bool {
    (row.top - previous.bottom) > options.paragraph_gap
}

/// The x positions the run's cells consistently line up on, and which edge
/// they line up on, or None if they do not line up well enough to be a table.
///
/// Both edges are tried and the one that fits more rows wins, with a tie going
/// to the left because left-aligned columns are the commoner layout.
fn table_columns(run: &[Row], options: &RenderOptions) -> Option<(Vec<f32>, ColumnAnchor)> {
    let left = columns_anchored(run, options, ColumnAnchor::Left);
    let right = columns_anchored(run, options, ColumnAnchor::Right);
    match (left, right) {
        (Some((left, left_fit)), Some((right, right_fit))) => Some(if right_fit > left_fit {
            (right, ColumnAnchor::Right)
        } else {
            (left, ColumnAnchor::Left)
        }),
        (Some((left, _)), None) => Some((left, ColumnAnchor::Left)),
        (None, Some((right, _))) => Some((right, ColumnAnchor::Right)),
        (None, None) => None,
    }
}

/// Candidate columns for one anchoring, with how many rows fit the grid.
fn columns_anchored(
    run: &[Row],
    options: &RenderOptions,
    anchor: ColumnAnchor,
) -> Option<(Vec<f32>, usize)> {
    let tolerance = column_tolerance(options);
    let mut edges: Vec<f32> = run
        .iter()
        .flat_map(|row| row.cells.iter().map(|cell| cell_anchor(cell, anchor)))
        .collect();
    edges.sort_by(f32::total_cmp);

    // Cluster the left edges; each cluster is a candidate column.
    let mut clusters: Vec<Vec<f32>> = Vec::new();
    for edge in edges {
        match clusters.last_mut() {
            Some(last) if edge - last[0] <= tolerance => last.push(edge),
            _ => clusters.push(vec![edge]),
        }
    }

    // Keep the clusters that most rows actually have a cell in — a stray
    // wrapped cell should not invent a column of its own.
    let needed = ((run.len() as f32) * TABLE_COLUMN_SHARE).ceil() as usize;
    let mut columns: Vec<f32> = Vec::new();
    for cluster in &clusters {
        let centre = cluster.iter().sum::<f32>() / cluster.len() as f32;
        let rows_here = run
            .iter()
            .filter(|row| {
                row.cells
                    .iter()
                    .any(|cell| (cell_anchor(cell, anchor) - centre).abs() <= tolerance)
            })
            .count();
        if rows_here >= needed.max(2) {
            columns.push(centre);
        }
    }
    if columns.len() < MIN_TABLE_COLUMNS {
        return None;
    }

    // Every row must fit the grid. A run where half the rows spill outside the
    // columns is prose that happened to be split into pieces.
    let fitting = run
        .iter()
        .filter(|row| {
            row.cells.iter().all(|cell| {
                nearest_column(cell_anchor(cell, anchor), &columns, tolerance).is_some()
            })
        })
        .count();
    if fitting < needed.max(2) {
        return None;
    }
    Some((columns, fitting))
}

fn column_tolerance(options: &RenderOptions) -> f32 {
    let width = (options.content_right - options.content_left).max(1.0);
    (width * 0.03).max(options.median_height).max(4.0)
}

fn nearest_column(left: f32, columns: &[f32], tolerance: f32) -> Option<usize> {
    columns
        .iter()
        .enumerate()
        .filter(|(_, centre)| (left - **centre).abs() <= tolerance)
        .min_by(|(_, a), (_, b)| (left - **a).abs().total_cmp(&(left - **b).abs()))
        .map(|(index, _)| index)
}

/// Draw the run as a Markdown pipe table.
fn draw_table(rows: &[Row], span: &TableSpan, options: &RenderOptions) -> String {
    let tolerance = column_tolerance(options);
    let width = span.columns.len();
    let mut grid: Vec<Vec<String>> = Vec::new();
    for row in &rows[span.start..span.end] {
        let mut cells = vec![String::new(); width];
        for cell in &row.cells {
            // A cell that sits outside every column joins the nearest one
            // rather than being lost.
            let edge = cell_anchor(cell, span.anchor);
            let index = nearest_column(edge, &span.columns, tolerance)
                .unwrap_or_else(|| fallback_column(edge, &span.columns));
            if !cells[index].is_empty() {
                cells[index].push(' ');
            }
            cells[index].push_str(&cell.text);
        }
        grid.push(cells);
    }
    if grid.is_empty() {
        return String::new();
    }

    let alignments: Vec<bool> = (0..width)
        .map(|index| numeric_column(&grid, index))
        .collect();
    let mut out = String::new();
    out.push_str(&pipe_row(&grid[0]));
    out.push('\n');
    out.push_str(&separator_row(&alignments));
    for row in &grid[1..] {
        out.push('\n');
        out.push_str(&pipe_row(row));
    }
    out
}

fn fallback_column(edge: f32, columns: &[f32]) -> usize {
    columns
        .iter()
        .enumerate()
        .min_by(|(_, a), (_, b)| (edge - **a).abs().total_cmp(&(edge - **b).abs()))
        .map_or(0, |(index, _)| index)
}

/// Whether a column holds numbers, and so should be drawn right-aligned.
/// The header is excluded — it is a word even in a column of figures.
fn numeric_column(grid: &[Vec<String>], index: usize) -> bool {
    let body: Vec<&String> = grid
        .iter()
        .skip(1)
        .filter_map(|row| row.get(index))
        .filter(|cell| !cell.is_empty())
        .collect();
    if body.is_empty() {
        return false;
    }
    let numeric = body.iter().filter(|cell| looks_numeric(cell)).count();
    numeric as f32 / body.len() as f32 >= NUMERIC_COLUMN_SHARE
}

/// Loose enough for `1,204.50`, `-3`, `£9.99`, `42%`, and strict enough that a
/// word with a digit in it does not count.
fn looks_numeric(text: &str) -> bool {
    let mut digits = 0usize;
    let mut others = 0usize;
    for character in text.chars() {
        if character.is_ascii_digit() {
            digits += 1;
        } else if !matches!(
            character,
            ' ' | ',' | '.' | '-' | '+' | '%' | '$' | '£' | '€' | '¥' | '(' | ')'
        ) {
            others += 1;
        }
    }
    digits > 0 && others == 0
}

fn pipe_row(cells: &[String]) -> String {
    let mut out = String::from("|");
    for cell in cells {
        out.push(' ');
        out.push_str(&escape_cell(cell));
        out.push_str(" |");
    }
    out
}

fn separator_row(alignments: &[bool]) -> String {
    let mut out = String::from("|");
    for right in alignments {
        out.push(' ');
        out.push_str(if *right { "---:" } else { "---" });
        out.push_str(" |");
    }
    out
}

/// A pipe inside a cell would end it early, and a backslash would eat the
/// escape that follows it.
fn escape_cell(text: &str) -> String {
    let trimmed = dart_trim(text);
    let mut out = String::with_capacity(trimmed.len());
    for character in trimmed.chars() {
        if character == '|' || character == '\\' {
            out.push('\\');
        }
        out.push(character);
    }
    out
}

// --- Blocks ---------------------------------------------------------------

fn build_blocks(
    rows: &[Row],
    tables: &[TableSpan],
    body_height: f32,
    options: &RenderOptions,
) -> Vec<PlacedBlock> {
    let mut blocks: Vec<PlacedBlock> = Vec::new();
    let mut index = 0usize;
    while index < rows.len() {
        let page = rows[index].page;
        if let Some(span) = tables.iter().find(|span| span.start == index) {
            blocks.push(PlacedBlock {
                block: Block::Table { span: span.clone() },
                page,
            });
            index = span.end;
            continue;
        }
        let table_start = tables
            .iter()
            .map(|span| span.start)
            .find(|start| *start > index)
            .unwrap_or(rows.len());
        let end = block_end(rows, index, table_start, options);
        blocks.push(PlacedBlock {
            block: classify_block(&rows[index..end], body_height, options),
            page,
        });
        index = end;
    }
    blocks
}

/// Where the run of rows starting at `start` stops being one block.
fn block_end(rows: &[Row], start: usize, limit: usize, options: &RenderOptions) -> usize {
    let mut end = start + 1;
    while end < limit {
        let previous = &rows[end - 1];
        let row = &rows[end];
        // Crossing into another column, band or page is always a break: the
        // vertical gap between them means nothing.
        if !same_frame(previous, row) || paragraph_break(previous, row, options) {
            break;
        }
        // A new list item, or the first one, opens its own block.
        if options.detect_structure
            && list_marker(&row.text).is_some()
            && !is_wrapped_continuation(previous, row, options)
        {
            break;
        }
        // Stepping in or out by more than a paragraph indent starts something
        // else — a quotation, or the return to the body after one.
        if options.detect_structure
            && (row.left - previous.left).abs() > options.median_height * INDENT_BREAK_RATIO
            && !is_wrapped_continuation(previous, row, options)
        {
            break;
        }
        end += 1;
    }
    end
}

/// A wrapped list item's continuation is indented past its own marker, so a
/// row that starts further right than its predecessor is a continuation even
/// if it happens to begin with something marker-shaped.
fn is_wrapped_continuation(previous: &Row, row: &Row, options: &RenderOptions) -> bool {
    list_marker(&previous.text).is_some() && row.left > previous.left + options.median_height * 0.5
}

fn classify_block(run: &[Row], body_height: f32, options: &RenderOptions) -> Block {
    if !options.detect_structure {
        return plain_block(run, options);
    }
    if let Some(block) = as_heading(run, body_height, options) {
        return block;
    }
    if let Some(block) = as_list(run) {
        return block;
    }
    if let Some(block) = as_quote(run, options) {
        return block;
    }
    plain_block(run, options)
}

fn plain_block(run: &[Row], options: &RenderOptions) -> Block {
    if options.preserve_line_breaks {
        return Block::Lines {
            lines: run
                .iter()
                .map(|row| {
                    if options.label_values {
                        emphasise_label(&row.text)
                    } else {
                        row.text.clone()
                    }
                })
                .collect(),
        };
    }
    let text = reflow(run);
    let healable = !ends_a_sentence(&text);
    Block::Paragraph { text, healable }
}

fn as_heading(run: &[Row], body_height: f32, options: &RenderOptions) -> Option<Block> {
    if run.len() != 1 || body_height <= 0.0 {
        return None;
    }
    let row = &run[0];
    let ratio = row.height / body_height;
    if ratio < HEADING_RATIO {
        return None;
    }
    // A heading is a short line. A long one set in a big face is a pull quote
    // or an opening sentence, and turning it into a heading reads badly.
    let width = (options.content_right - options.content_left).max(1.0);
    if (row.right - row.left) / width > HEADING_MAX_FILL {
        return None;
    }
    let level = if ratio >= H1_RATIO {
        1
    } else if ratio >= H2_RATIO {
        2
    } else {
        3
    };
    Some(Block::Heading {
        level,
        text: row.text.clone(),
    })
}

fn as_list(run: &[Row]) -> Option<Block> {
    let (ordered, rest) = list_marker(&run[0].text)?;
    let mut text = rest.to_owned();
    for row in &run[1..] {
        append_wrapped(&mut text, &row.text);
    }
    Some(Block::List {
        items: vec![ListItem { ordered, text }],
    })
}

fn as_quote(run: &[Row], options: &RenderOptions) -> Option<Block> {
    let indent = options.median_height * QUOTE_INDENT_RATIO;
    let left = run.iter().map(|row| row.left).fold(f32::MAX, f32::min);
    if left < options.content_left + indent {
        return None;
    }
    // One indented line is as likely to be a stray as a quotation.
    if run.len() < 2 {
        return None;
    }
    Some(Block::Quote { text: reflow(run) })
}

/// The list marker at the start of a line, and what follows it.
///
/// Bullets are the unambiguous glyphs plus `-` and `*`; en and em dashes are
/// deliberately excluded because they open dialogue far more often than they
/// open a list. Numbering is digits only — `A.` and `i.` are real outline
/// markers but they collide with initials and with the pronoun, and guessing
/// wrong turns a sentence into a list item.
fn list_marker(text: &str) -> Option<(bool, &str)> {
    const BULLETS: [char; 7] = ['•', '●', '▪', '◦', '‣', '·', '*'];
    let mut chars = text.char_indices();
    let (_, first) = chars.next()?;

    if BULLETS.contains(&first) || first == '-' {
        let rest = text[first.len_utf8()..].strip_prefix(' ')?;
        let rest = dart_trim(rest);
        return (!rest.is_empty()).then_some((false, rest));
    }

    // `1.`, `1)`, `(1)` — a short run of digits and one closer.
    let digits: String = text.chars().take_while(char::is_ascii_digit).collect();
    if !digits.is_empty() && digits.len() <= 3 {
        let after = &text[digits.len()..];
        for closer in [". ", ") "] {
            if let Some(rest) = after.strip_prefix(closer) {
                let rest = dart_trim(rest);
                return (!rest.is_empty()).then_some((true, rest));
            }
        }
    }
    if let Some(inner) = text.strip_prefix('(') {
        let digits: String = inner.chars().take_while(char::is_ascii_digit).collect();
        if !digits.is_empty() && digits.len() <= 3 {
            if let Some(rest) = inner[digits.len()..].strip_prefix(") ") {
                let rest = dart_trim(rest);
                return (!rest.is_empty()).then_some((true, rest));
            }
        }
    }
    None
}

fn emphasise_label(text: &str) -> String {
    let Some(colon) = text.find(':') else {
        return text.to_owned();
    };
    let label = dart_trim(&text[..colon]);
    let value = dart_trim(&text[colon + 1..]);
    if label.is_empty() || value.is_empty() || label.chars().count() > 32 {
        return text.to_owned();
    }
    format!("**{label}:** {value}")
}

// --- Writing --------------------------------------------------------------

fn write(rows: &[Row], blocks: Vec<PlacedBlock>, options: &RenderOptions) -> Rendered {
    let mut chunks: Vec<String> = Vec::new();
    let mut markdown = false;
    let mut tables = 0usize;
    let mut headings = 0usize;
    let mut pending_list: Vec<ListItem> = Vec::new();
    // Whether the block just written was a paragraph that stopped mid-sentence,
    // and which page it ended on.
    let mut open_paragraph: Option<usize> = None;

    for PlacedBlock { block, page } in blocks {
        if !matches!(block, Block::List { .. }) && !pending_list.is_empty() {
            chunks.push(write_list(std::mem::take(&mut pending_list)));
        }
        match block {
            Block::Heading { level, text } => {
                markdown = true;
                headings += 1;
                open_paragraph = None;
                chunks.push(format!("{} {}", "#".repeat(level), text));
            }
            Block::Table { span } => {
                markdown = true;
                tables += 1;
                open_paragraph = None;
                chunks.push(draw_table(rows, &span, options));
            }
            Block::Quote { text } => {
                markdown = true;
                open_paragraph = None;
                let quoted: Vec<String> = text.lines().map(|line| format!("> {line}")).collect();
                chunks.push(quoted.join("\n"));
            }
            Block::List { items } => {
                markdown = true;
                open_paragraph = None;
                pending_list.extend(items);
            }
            Block::Lines { lines } => {
                if options.label_values && lines.iter().any(|line| line.contains("**")) {
                    markdown = true;
                }
                open_paragraph = None;
                chunks.push(lines.join("\n"));
            }
            Block::Paragraph { text, healable } => {
                // A paragraph cut in half by a page break is one paragraph.
                // The evidence is that the first half stopped mid-sentence and
                // the second half starts as a continuation would.
                let heal = options.heal_across_pages
                    && open_paragraph.is_some_and(|opened| page > opened)
                    && continues_a_sentence(&text);
                match chunks.last_mut().filter(|_| heal) {
                    Some(last) => append_wrapped(last, &text),
                    None => chunks.push(text.clone()),
                }
                open_paragraph = healable.then_some(page);
            }
        }
    }
    if !pending_list.is_empty() {
        chunks.push(write_list(pending_list));
    }

    chunks.retain(|chunk| !chunk.is_empty());
    Rendered {
        body: chunks.join("\n\n"),
        markdown,
        tables,
        headings,
    }
}

fn write_list(items: Vec<ListItem>) -> String {
    let mut out = String::new();
    let mut number = 1usize;
    for item in items {
        if !out.is_empty() {
            out.push('\n');
        }
        if item.ordered {
            out.push_str(&format!("{number}. {}", item.text));
            number += 1;
        } else {
            out.push_str(&format!("- {}", item.text));
        }
    }
    out
}

fn reflow(run: &[Row]) -> String {
    let mut text = String::new();
    for row in run {
        if text.is_empty() {
            text.push_str(&row.text);
        } else {
            append_wrapped(&mut text, &row.text);
        }
    }
    text
}

/// Append a wrapped continuation line. A trailing hyphen on the previous line
/// followed by a lowercase continuation is a word split by the line break, so
/// the hyphen and the space both go; anything else keeps a single space.
fn append_wrapped(current: &mut String, next: &str) {
    let continues_word = current.ends_with('-')
        && !current.ends_with("--")
        && next.chars().next().is_some_and(char::is_lowercase);
    if continues_word {
        current.pop();
        current.push_str(next);
    } else {
        if !current.is_empty() {
            current.push(' ');
        }
        current.push_str(next);
    }
}

fn ends_a_sentence(text: &str) -> bool {
    let trimmed = text.trim_end();
    trimmed.is_empty() || trimmed.ends_with(['.', '!', '?', ':', '”', '"', ')', '»'])
}

fn continues_a_sentence(text: &str) -> bool {
    text.chars()
        .next()
        .is_some_and(|first| first.is_lowercase() || !first.is_alphabetic())
}

#[cfg(test)]
mod tests {
    use crate::api::ocr::{
        shape_scanned_pages, shape_scanned_text, OcrLineInput, OcrPageInput, OcrShapeOptions,
        ScanPreset,
    };

    fn sized(text: &str, top: f32, left: f32, height: f32, width: f32) -> OcrLineInput {
        OcrLineInput {
            text: text.to_owned(),
            left,
            top,
            right: left + width,
            bottom: top + height,
            block_index: 0,
            confidence: None,
            words: Vec::new(),
        }
    }

    fn line(text: &str, top: f32, left: f32) -> OcrLineInput {
        sized(text, top, left, 20.0, 200.0)
    }

    fn shape(lines: Vec<OcrLineInput>) -> crate::api::ocr::ScannedNoteDraft {
        shape_scanned_text(
            lines,
            OcrShapeOptions {
                preset: ScanPreset::Prose,
                ..OcrShapeOptions::default()
            },
        )
    }

    /// A four-column price table: a header row and three data rows whose cells
    /// start at the same x positions.
    fn price_table() -> Vec<OcrLineInput> {
        let mut lines = Vec::new();
        let rows = [
            ["Item", "Qty", "Price"],
            ["Widget", "2", "4.00"],
            ["Gasket", "13", "11.50"],
            ["Flange", "1", "99.99"],
        ];
        for (index, row) in rows.iter().enumerate() {
            let top = index as f32 * 30.0;
            lines.push(sized(row[0], top, 0.0, 20.0, 90.0));
            lines.push(sized(row[1], top, 200.0, 20.0, 40.0));
            lines.push(sized(row[2], top, 320.0, 20.0, 70.0));
        }
        lines
    }

    #[test]
    fn a_run_of_aligned_rows_is_drawn_as_a_markdown_table() {
        let draft = shape(price_table());
        assert_eq!(draft.tables, 1);
        assert_eq!(draft.content_type, "markdown");
        assert!(
            draft.body.contains("| Item | Qty | Price |"),
            "got: {}",
            draft.body
        );
        assert!(draft.body.contains("| Widget | 2 | 4.00 |"));
        assert!(draft.body.contains("| Flange | 1 | 99.99 |"));
    }

    #[test]
    fn a_column_of_figures_is_drawn_right_aligned() {
        let draft = shape(price_table());
        // Item is text, Qty and Price are numbers.
        assert!(
            draft.body.contains("| --- | ---: | ---: |"),
            "got: {}",
            draft.body
        );
    }

    #[test]
    fn a_pipe_inside_a_cell_cannot_break_the_table() {
        let mut lines = Vec::new();
        for index in 0..3 {
            let top = index as f32 * 30.0;
            lines.push(sized(
                if index == 1 { "a|b" } else { "text" },
                top,
                0.0,
                20.0,
                90.0,
            ));
            lines.push(sized("2", top, 200.0, 20.0, 40.0));
            lines.push(sized("3", top, 320.0, 20.0, 70.0));
        }
        let draft = shape(lines);
        assert_eq!(draft.tables, 1);
        assert!(draft.body.contains(r"a\|b"), "got: {}", draft.body);
    }

    #[test]
    fn a_column_of_figures_set_flush_right_is_still_found() {
        // An invoice column: the amounts end on the same x, but because they
        // are different lengths they all *start* somewhere different. Looking
        // only at left edges would find no column here at all.
        let amounts = ["9.50", "127.00", "1,340.25", "8.75"];
        let mut lines = Vec::new();
        for (index, amount) in amounts.iter().enumerate() {
            let top = index as f32 * 30.0;
            lines.push(sized("Line item", top, 0.0, 20.0, 120.0));
            let width = amount.len() as f32 * 12.0;
            lines.push(sized(amount, top, 400.0 - width, 20.0, width));
        }
        let draft = shape(lines);
        assert_eq!(draft.tables, 1, "got: {}", draft.body);
        assert!(
            draft.body.contains("| Line item | 9.50 |"),
            "got: {}",
            draft.body
        );
        assert!(
            draft.body.contains("| Line item | 1,340.25 |"),
            "got: {}",
            draft.body
        );
    }

    #[test]
    fn two_columns_of_prose_are_not_a_table() {
        // Side-by-side paragraphs: the lines share a gutter but start at
        // wherever the words fell, and each row is a single box.
        let mut lines = Vec::new();
        for index in 0..6 {
            let top = index as f32 * 24.0;
            lines.push(sized(&format!("left {index}"), top, 0.0, 20.0, 200.0));
            lines.push(sized(&format!("right {index}"), top, 300.0, 20.0, 200.0));
        }
        let draft = shape(lines);
        assert_eq!(draft.tables, 0, "got: {}", draft.body);
    }

    #[test]
    fn two_aligned_rows_are_not_enough_to_call_it_a_table() {
        let mut lines = Vec::new();
        for index in 0..2 {
            let top = index as f32 * 30.0;
            lines.push(sized("label", top, 0.0, 20.0, 90.0));
            lines.push(sized("value", top, 200.0, 20.0, 90.0));
        }
        assert_eq!(shape(lines).tables, 0);
    }

    #[test]
    fn tables_can_be_turned_off() {
        let draft = shape_scanned_text(
            price_table(),
            OcrShapeOptions {
                detect_tables: false,
                preset: ScanPreset::Prose,
                ..OcrShapeOptions::default()
            },
        );
        assert_eq!(draft.tables, 0);
        assert!(!draft.body.contains('|'));
    }

    #[test]
    fn a_missing_cell_leaves_an_empty_column_rather_than_shifting_the_row() {
        let mut lines = Vec::new();
        for index in 0..4 {
            let top = index as f32 * 30.0;
            lines.push(sized("name", top, 0.0, 20.0, 90.0));
            if index != 2 {
                lines.push(sized("mid", top, 200.0, 20.0, 60.0));
            }
            lines.push(sized("9", top, 320.0, 20.0, 40.0));
        }
        let draft = shape(lines);
        assert_eq!(draft.tables, 1, "got: {}", draft.body);
        assert!(
            draft.body.contains("| name |  | 9 |"),
            "got: {}",
            draft.body
        );
    }

    // --- Headings ---

    #[test]
    fn a_taller_isolated_line_becomes_a_heading() {
        let draft = shape(vec![
            sized("Chapter One", 0.0, 0.0, 34.0, 220.0),
            sized("It was a bright cold day", 70.0, 0.0, 20.0, 500.0),
            sized("and the clocks were striking", 94.0, 0.0, 20.0, 500.0),
        ]);
        assert_eq!(draft.headings, 1);
        assert!(
            draft.body.starts_with("# Chapter One"),
            "got: {}",
            draft.body
        );
        assert!(draft
            .body
            .contains("It was a bright cold day and the clocks"));
    }

    #[test]
    fn heading_levels_follow_relative_size() {
        let draft = shape(vec![
            sized("Big", 0.0, 0.0, 40.0, 100.0),
            sized("Medium", 80.0, 0.0, 28.0, 100.0),
            sized("body text here", 160.0, 0.0, 20.0, 400.0),
            sized("more body text", 184.0, 0.0, 20.0, 400.0),
            sized("still more body", 208.0, 0.0, 20.0, 400.0),
        ]);
        assert!(draft.body.contains("# Big"), "got: {}", draft.body);
        assert!(draft.body.contains("## Medium"), "got: {}", draft.body);
    }

    #[test]
    fn a_long_line_in_a_large_face_is_not_a_heading() {
        let draft = shape(vec![
            sized(
                "This opening sentence runs the full width of the page in a larger face",
                0.0,
                0.0,
                30.0,
                600.0,
            ),
            sized("ordinary body text", 60.0, 0.0, 20.0, 600.0),
            sized("more ordinary text", 84.0, 0.0, 20.0, 600.0),
        ]);
        assert_eq!(draft.headings, 0, "got: {}", draft.body);
    }

    #[test]
    fn a_page_with_no_structure_stays_plain_text() {
        let draft = shape(vec![
            line("just some prose", 0.0, 0.0),
            line("running on", 24.0, 0.0),
        ]);
        assert_eq!(draft.content_type, "plain");
        assert_eq!(draft.body, "just some prose running on");
    }

    // --- Lists ---

    #[test]
    fn bulleted_lines_become_a_markdown_list() {
        let draft = shape(vec![
            line("• milk", 0.0, 0.0),
            line("• bread", 24.0, 0.0),
            line("• eggs", 48.0, 0.0),
        ]);
        assert_eq!(draft.content_type, "markdown");
        assert_eq!(draft.body, "- milk\n- bread\n- eggs");
    }

    #[test]
    fn numbered_lines_are_renumbered_in_order() {
        let draft = shape(vec![
            line("1. wake up", 0.0, 0.0),
            line("2. drink coffee", 24.0, 0.0),
            line("3) leave", 48.0, 0.0),
        ]);
        assert_eq!(draft.body, "1. wake up\n2. drink coffee\n3. leave");
    }

    #[test]
    fn a_wrapped_list_item_stays_one_item() {
        let draft = shape(vec![
            sized("• a long item that runs", 0.0, 0.0, 20.0, 300.0),
            sized("onto a second line", 24.0, 20.0, 20.0, 260.0),
            sized("• the next item", 48.0, 0.0, 20.0, 200.0),
        ]);
        assert_eq!(
            draft.body,
            "- a long item that runs onto a second line\n- the next item"
        );
    }

    #[test]
    fn a_dash_that_opens_a_sentence_is_not_a_bullet() {
        // No space after the dash, so nothing marker-shaped about it.
        let draft = shape(vec![
            line("-and then it stopped", 0.0, 0.0),
            line("which was that", 24.0, 0.0),
        ]);
        assert_eq!(draft.content_type, "plain");
    }

    // --- Quotes ---

    #[test]
    fn a_sustained_indent_becomes_a_block_quote() {
        let draft = shape(vec![
            sized("He wrote the following", 0.0, 0.0, 20.0, 400.0),
            sized("all that we see or seem", 40.0, 90.0, 20.0, 300.0),
            sized("is but a dream within a dream", 64.0, 90.0, 20.0, 300.0),
        ]);
        assert!(
            draft
                .body
                .contains("> all that we see or seem is but a dream"),
            "got: {}",
            draft.body
        );
    }

    #[test]
    fn a_single_indented_line_is_not_a_quote() {
        let draft = shape(vec![
            sized("ordinary opening", 0.0, 0.0, 20.0, 400.0),
            sized("stray indent", 60.0, 90.0, 20.0, 200.0),
        ]);
        assert!(!draft.body.contains('>'));
    }

    // --- Code ---

    #[test]
    fn the_code_preset_fences_the_page_and_changes_nothing_inside() {
        let draft = shape_scanned_text(
            vec![
                line("fn main() {", 0.0, 0.0),
                line("println!(\"hi\");", 24.0, 40.0),
                line("}", 48.0, 0.0),
            ],
            OcrShapeOptions {
                preset: ScanPreset::Code,
                ..OcrShapeOptions::default()
            },
        );
        assert_eq!(draft.content_type, "markdown");
        assert_eq!(draft.body, "```\nfn main() {\nprintln!(\"hi\");\n}\n```");
    }

    // --- Forms ---

    #[test]
    fn the_form_preset_emphasises_the_label_half() {
        let draft = shape_scanned_text(
            vec![
                line("Name: Ada Lovelace", 0.0, 0.0),
                line("Role: Analyst", 24.0, 0.0),
            ],
            OcrShapeOptions {
                preset: ScanPreset::Form,
                ..OcrShapeOptions::default()
            },
        );
        assert!(
            draft.body.contains("**Name:** Ada Lovelace"),
            "got: {}",
            draft.body
        );
    }

    // --- Page healing ---

    #[test]
    fn a_paragraph_split_by_a_page_break_is_rejoined() {
        let draft = shape_scanned_pages(
            vec![
                OcrPageInput {
                    lines: vec![line("the sentence carries on", 0.0, 0.0)],
                    width: 1000.0,
                    height: 1400.0,
                },
                OcrPageInput {
                    lines: vec![line("onto the following page", 0.0, 0.0)],
                    width: 1000.0,
                    height: 1400.0,
                },
            ],
            OcrShapeOptions {
                preset: ScanPreset::Prose,
                ..OcrShapeOptions::default()
            },
        );
        assert_eq!(
            draft.body,
            "the sentence carries on onto the following page"
        );
    }

    #[test]
    fn a_finished_sentence_is_left_alone_at_a_page_break() {
        let draft = shape_scanned_pages(
            vec![
                OcrPageInput {
                    lines: vec![line("The chapter ends here.", 0.0, 0.0)],
                    width: 1000.0,
                    height: 1400.0,
                },
                OcrPageInput {
                    lines: vec![line("A new thought begins", 0.0, 0.0)],
                    width: 1000.0,
                    height: 1400.0,
                },
            ],
            OcrShapeOptions {
                preset: ScanPreset::Prose,
                ..OcrShapeOptions::default()
            },
        );
        assert_eq!(draft.body, "The chapter ends here.\n\nA new thought begins");
    }

    #[test]
    fn page_healing_can_be_turned_off() {
        let draft = shape_scanned_pages(
            vec![
                OcrPageInput {
                    lines: vec![line("the sentence carries on", 0.0, 0.0)],
                    width: 1000.0,
                    height: 1400.0,
                },
                OcrPageInput {
                    lines: vec![line("onto the following page", 0.0, 0.0)],
                    width: 1000.0,
                    height: 1400.0,
                },
            ],
            OcrShapeOptions {
                preset: ScanPreset::Prose,
                heal_across_pages: false,
                ..OcrShapeOptions::default()
            },
        );
        assert!(draft.body.contains("\n\n"));
    }
}
