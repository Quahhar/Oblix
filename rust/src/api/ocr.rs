//! Turning recognized text into a note.
//!
//! An OCR engine hands back a bag of positioned line boxes, not a document.
//! The lines arrive in whatever order the recognizer walked the image, a
//! single visual row is often split across several boxes, wrapped sentences
//! are separate lines, and words broken across a line end keep their hyphen.
//! Reassembling that into prose is pure geometry and string work, so it lives
//! here rather than in the UI: the platform stays a thin source of boxes, and
//! the reconstruction is the same on every platform and testable without a
//! camera.
//!
//! The pipeline is: drop noise, straighten the page, work out its column
//! structure, walk it in reading order, merge boxes that share a printed line,
//! strip anything that repeats on every page, then hand the rows to [`crate::api::doc`]
//! to be written out as prose or as structured Markdown.
//!
//! Nothing here is specific to a camera. A PDF's embedded text runs are also
//! "text plus a box", so [`crate::api::pdf`] feeds this same pipeline and a
//! digital PDF reconstructs through exactly the code a photograph does.
//!
//! Coordinates are the source's pixels, y growing downward.

use flutter_rust_bridge::frb;

use crate::api::doc::{self, RenderOptions};
use crate::dart_string::{dart_trim, is_dart_regexp_whitespace};

/// Longest title we will lift out of a scan before falling back to trimming.
const MAX_TITLE_UNITS: usize = 80;

/// A row gap wider than this many median line heights starts a new paragraph.
const PARAGRAPH_GAP_RATIO: f32 = 1.6;

/// Vertical slack, as a share of the median line height, within which two
/// boxes count as the same visual row.
const ROW_BAND_RATIO: f32 = 0.6;

/// A line height below this share of the median is treated as a speck.
const MIN_HEIGHT_RATIO: f32 = 0.35;

/// Lines a page needs before its box heights are fitted against their widths to
/// recover the tilt. Fewer than this and one outsized heading swings the fit.
const MIN_LINES_FOR_TILT_FIT: usize = 4;

/// Spread of line widths, relative to their mean, below which the fit is
/// abandoned: a page of uniform-width lines cannot reveal its own tilt.
const MIN_WIDTH_SPREAD: f32 = 0.1;

/// Pairs of boxes that must agree on which way the page leans before the deskew
/// will act on it, and how far the winning answer must outweigh the other. A
/// page really split into several boxes per row clears both easily; a page of
/// whole-line boxes, where the sign is not in the geometry to begin with, does
/// not — and is left alone rather than sheared the wrong way.
const MIN_ROW_MATES_FOR_DIRECTION: usize = 3;
const DIRECTION_MARGIN: f32 = 2.0;

/// How far a pair may sit from where the candidate lean predicts and still be
/// taken for two boxes on one printed line, as a share of the line height.
///
/// Deliberately a fraction of a line rather than the row band: boxes that truly
/// share a line land exactly on the lean, so this only has to absorb the few
/// pixels by which a capital and a descender disagree about where their line
/// sits. A window half a line wide would admit the pairs a whole row apart that
/// a shear has dragged into place, which are the ones arguing for the wrong
/// answer.
const DIRECTION_TOLERANCE_RATIO: f32 = 0.25;

/// Tilts whose sine falls outside this range are left uncorrected — under it
/// the inflation is not worth touching, over it the fit is more likely to be
/// reading a page whose headings are wider than its body than a real tilt.
const MIN_CORRECTED_TILT_TANGENT: f32 = 0.01;
const MAX_CORRECTED_TILT_TANGENT: f32 = 0.35;

/// Steepest page tilt we will try to correct, as a slope — about 20°. Beyond
/// that the estimate is more likely to be noise than skew.
const MAX_SKEW_SLOPE: f32 = 0.36;

/// Candidate angles tried on each side of level when measuring skew. 72 steps
/// across [MAX_SKEW_SLOPE] lands them 0.005 apart — a third of a degree, finer
/// than the row banding can tell apart.
const SKEW_STEPS: i32 = 72;

/// How strongly the estimator prefers to believe the page is straight.
///
/// Alignment scoring rewards any slope that packs two boxes into one bin, and
/// on a page with only a few lines there is nearly always some steep angle that
/// does so by coincidence — a false tilt then merges rows that were never on
/// the same line. Discounting each candidate by the square of how far it leans
/// makes a large correction pay for itself: a gentle tilt is barely touched,
/// while an extreme one has to explain the page dramatically better than level
/// does before it is believed.
const SKEW_PRIOR: f32 = 0.5;

/// A box at least this wide, relative to the text block, spans the page and so
/// cannot belong to a single column — a banner headline, a rule, a footer.
const FULL_WIDTH_RATIO: f32 = 0.7;

/// A horizontal gap must be at least this share of the page width to count as
/// a gutter between columns.
const GUTTER_WIDTH_RATIO: f32 = 0.04;

/// Guards against reading a couple of short lines as a two-column layout: a
/// real column holds several lines and runs most of the way down the text
/// block, and a columnar page is several lines tall to begin with.
const MIN_COLUMN_LINES: usize = 3;
const MIN_COLUMN_HEIGHT_RATIO: f32 = 0.5;
const MIN_COLUMNAR_HEIGHT_RATIO: f32 = 4.0;

/// Share of the content width the columns must between them cover.
///
/// This is what tells a two-column article from a table, which otherwise look
/// identical here — both are runs of text separated by vertical gaps. Columns
/// of prose *tile* the page: set the gutters aside and they fill it. A table's
/// cells are islands with far more white space than ink between them, so the
/// same gaps that look like gutters cover much less of the width. Reading a
/// table as columns would be the worse mistake, because it destroys the row
/// structure that carried the meaning.
const MIN_COLUMN_COVERAGE: f32 = 0.75;

/// Running heads are only looked for once there are enough pages for
/// "repeats on every page" to mean anything, and a line must appear on at
/// least this share of them.
const MIN_PAGES_FOR_RUNNING_HEADS: usize = 3;
const RUNNING_HEAD_SHARE: f32 = 0.6;

/// How far into a page's rows we look for a running head or foot.
const RUNNING_HEAD_DEPTH: usize = 2;

/// Confidence below which a line counts as doubtful when scoring the capture.
const LOW_CONFIDENCE: f32 = 0.55;

/// Share of doubtful lines above which a capture is called poor, then fair.
const POOR_CONFIDENCE_SHARE: f32 = 0.35;
const FAIR_CONFIDENCE_SHARE: f32 = 0.15;

/// One recognized word and where it sat, when the recognizer breaks a line
/// down that far.
///
/// Not every source supplies these — a PDF's text runs are not words, and some
/// recognizers report lines only — so everything here treats them as extra
/// evidence rather than as the model. A page that has them reconstructs
/// better; a page that does not reconstructs exactly as it did before.
#[derive(Clone, Debug, PartialEq)]
pub struct OcrWordInput {
    pub text: String,
    pub left: f32,
    pub top: f32,
    pub right: f32,
    pub bottom: f32,
    /// 0..1 where the recognizer reports it. Absent means "no opinion".
    pub confidence: Option<f32>,
}

/// One recognized line and where it sat on the page.
#[derive(Clone, Debug, PartialEq)]
pub struct OcrLineInput {
    pub text: String,
    pub left: f32,
    pub top: f32,
    pub right: f32,
    pub bottom: f32,
    /// The recognizer's own grouping, kept so a caller can pass it through;
    /// reconstruction relies on geometry instead, because block grouping is
    /// unreliable on photographs.
    pub block_index: i32,
    /// 0..1 where the recognizer reports it. Absent means "no opinion".
    pub confidence: Option<f32>,
    /// The words this line was made of, empty when the source does not say.
    pub words: Vec<OcrWordInput>,
}

impl OcrLineInput {
    /// What the recognizer thought of this line, falling back to what it
    /// thought of the words in it.
    ///
    /// Line-level confidence is frequently absent where word-level confidence
    /// is not — ML Kit on Android is the case that matters — and a page whose
    /// lines all report `None` is scored as "no opinion" by everything
    /// downstream: the capture quality reads `Unknown`, the retry comparison
    /// falls back to a neutral constant, and the low-confidence filter has
    /// nothing to filter on. Averaging the words recovers all three.
    pub(crate) fn effective_confidence(&self) -> Option<f32> {
        if let Some(score) = self.confidence {
            return Some(score);
        }
        let scored: Vec<f32> = self
            .words
            .iter()
            .filter_map(|word| word.confidence)
            .collect();
        if scored.is_empty() {
            return None;
        }
        Some(scored.iter().sum::<f32>() / scored.len() as f32)
    }
}

/// One page's worth of recognized lines.
#[derive(Clone, Debug, PartialEq)]
pub struct OcrPageInput {
    pub lines: Vec<OcrLineInput>,
    /// Source pixel size. Zero means "unknown" — used only for the heuristics
    /// that classify a page, never for reconstruction, which works off the
    /// text block's own extent.
    pub width: f32,
    pub height: f32,
}

/// How a page should be read.
///
/// [`ScanPreset::Auto`] picks one from the page's own geometry; the rest force
/// a choice when the caller knows better than the classifier does.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ScanPreset {
    Auto,
    /// Ordinary flowing text. Wrapped lines rejoin into paragraphs.
    Prose,
    /// A page from a book: prose, plus running heads and page numbers removed
    /// and paragraphs healed across the page break.
    BookPage,
    /// Receipts and tickets: every line kept, columns off, tables off.
    Receipt,
    /// A form: label and value pairs, read straight down.
    Form,
    /// A whiteboard or sticky notes: keep the clusters, never reflow.
    Whiteboard,
    /// Source code: preserve every break and indent, fence the result.
    Code,
    /// A page that is mostly one big table.
    Table,
}

impl ScanPreset {
    fn label(self) -> &'static str {
        match self {
            ScanPreset::Auto => "auto",
            ScanPreset::Prose => "prose",
            ScanPreset::BookPage => "book",
            ScanPreset::Receipt => "receipt",
            ScanPreset::Form => "form",
            ScanPreset::Whiteboard => "whiteboard",
            ScanPreset::Code => "code",
            ScanPreset::Table => "table",
        }
    }
}

/// How much the recognizer struggled, which is a decent proxy for whether the
/// photograph was any good.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum QualityVerdict {
    /// The recognizer reported no confidences at all, so there is nothing to
    /// judge. Not the same as "good".
    Unknown,
    Good,
    Fair,
    Poor,
}

/// What the capture looked like to the recognizer.
#[derive(Clone, Debug, PartialEq)]
pub struct CaptureQuality {
    pub verdict: QualityVerdict,
    /// Mean reported confidence across scored lines, or 0 when none were.
    pub mean_confidence: f32,
    /// Share of scored lines below [LOW_CONFIDENCE].
    pub low_confidence_share: f32,
    /// Lines the recognizer scored at all.
    pub scored_lines: i32,
    /// Empty when there is nothing worth saying.
    pub advice: String,
}

/// Tunables the caller may want to expose in the UI.
#[derive(Clone, Debug, PartialEq)]
pub struct OcrShapeOptions {
    /// Lines scoring below this are dropped. Lines without a score are kept.
    pub min_confidence: f32,
    /// Keep every recognized line as its own line instead of reflowing
    /// wrapped lines back into paragraphs. Useful for receipts and code.
    pub preserve_line_breaks: bool,
    /// Look for columns and read them one at a time. Off means straight
    /// top-to-bottom, which is what a receipt or a form wants.
    pub detect_columns: bool,
    /// Read the page's structure — headings, lists, quotes — and write it out
    /// as Markdown. When nothing structural is found the body stays plain.
    pub detect_structure: bool,
    /// Recognize aligned rows as a table and draw it as a Markdown table.
    pub detect_tables: bool,
    /// Drop lines that repeat in the same place on most pages.
    pub strip_running_heads: bool,
    /// Rejoin a paragraph that was cut in half by a page break.
    pub heal_across_pages: bool,
    /// Put back characters the recognizer read as the wrong glyph, where the
    /// capture's own vocabulary or a common word says what was meant. Only
    /// ever acts on lines the recognizer was unsure of. See
    /// [`crate::misread`].
    pub repair_misreads: bool,
    /// How to read the page. [`ScanPreset::Auto`] classifies it, and the
    /// chosen preset then overrides the flags above that it has an opinion on.
    pub preset: ScanPreset,
}

impl Default for OcrShapeOptions {
    fn default() -> Self {
        Self {
            min_confidence: 0.0,
            preserve_line_breaks: false,
            detect_columns: true,
            detect_structure: true,
            detect_tables: true,
            strip_running_heads: true,
            heal_across_pages: true,
            repair_misreads: true,
            preset: ScanPreset::Auto,
        }
    }
}

/// A note ready to be created, plus what the reconstruction made of the pages.
#[derive(Clone, Debug, PartialEq)]
pub struct ScannedNoteDraft {
    pub title: String,
    pub body: String,
    /// `plain` or `markdown`, matching the note content types. Markdown only
    /// when structure was actually found, so a plain page stays plain.
    pub content_type: String,
    /// Lines that survived filtering and made it into [body].
    pub kept_lines: i32,
    /// Lines dropped as low-confidence, empty, or too small to be text.
    pub dropped_lines: i32,
    /// Columns of the widest page. 1 for ordinary prose.
    pub columns: i32,
    /// Page tilt that was corrected, in degrees, worst page first. Negative
    /// leans left.
    pub corrected_skew_degrees: f32,
    pub pages: i32,
    /// Tables drawn into [body].
    pub tables: i32,
    /// Headings found and written as Markdown headings.
    pub headings: i32,
    /// Lines removed as running heads, feet, or page numbers.
    pub stripped_running_heads: i32,
    /// Characters put back by [`crate::misread`], counted in tokens changed.
    pub repaired_words: i32,
    /// The preset actually used, never `auto`.
    pub preset: String,
    pub quality: CaptureQuality,
}

/// A line straightened and placed in the page's structure.
#[derive(Clone, Debug)]
struct Placed {
    text: String,
    left: f32,
    right: f32,
    /// Deskewed vertical extent — comparable across the whole page width.
    top: f32,
    bottom: f32,
    /// Full-width lines split the page into bands; everything else belongs to
    /// the band between the full-width lines above and below it.
    band: usize,
    /// Index into the detected columns, left to right. Always 0 when the page
    /// is a single column, and for the full-width lines themselves.
    column: usize,
    full_width: bool,
}

impl Placed {
    fn width(&self) -> f32 {
        self.right - self.left
    }

    fn centre_x(&self) -> f32 {
        (self.left + self.right) / 2.0
    }

    fn centre_y(&self) -> f32 {
        (self.top + self.bottom) / 2.0
    }
}

/// One box that made up a printed row, kept apart from its neighbours.
///
/// [`Row::text`] is what the row reads as; the cells are where the pieces of
/// it sat. Table detection is entirely a question of whether those pieces line
/// up down the page, so merging them away would make tables invisible.
#[derive(Clone, Debug)]
pub(crate) struct RowCell {
    pub text: String,
    pub left: f32,
    pub right: f32,
}

/// A printed row of the document, wherever it came from.
#[derive(Clone, Debug)]
pub(crate) struct Row {
    pub text: String,
    pub cells: Vec<RowCell>,
    pub left: f32,
    pub right: f32,
    pub top: f32,
    pub bottom: f32,
    pub height: f32,
    pub band: usize,
    pub column: usize,
    pub page: usize,
}

/// Everything the geometry pass worked out, ready to be written out.
pub(crate) struct Reconstruction {
    pub rows: Vec<Row>,
    pub median_height: f32,
    pub content_left: f32,
    pub content_right: f32,
    pub columns: usize,
    pub worst_skew: f32,
    pub kept: usize,
    pub dropped: usize,
    /// Rows removed as running heads — the human-meaningful count, since one
    /// piece of furniture is one row however many boxes the recognizer split
    /// it into.
    pub stripped: usize,
    /// The same removal counted in recognizer lines, which is the unit
    /// `kept`/`dropped` are in.
    pub stripped_lines: usize,
    pub pages: usize,
    pub page_width: f32,
    pub page_height: f32,
}

/// Rebuild note text from one page of recognized line boxes.
#[frb(sync)]
pub fn shape_scanned_text(lines: Vec<OcrLineInput>, options: OcrShapeOptions) -> ScannedNoteDraft {
    shape_scanned_pages(
        vec![OcrPageInput {
            lines,
            width: 0.0,
            height: 0.0,
        }],
        options,
    )
}

/// Rebuild note text from a whole capture.
///
/// Pages are reconstructed one at a time — tilt and column structure are
/// properties of a photograph, not of the document — and only then considered
/// together, which is what makes running heads and paragraphs broken over a
/// page break visible at all.
#[frb(sync)]
pub fn shape_scanned_pages(pages: Vec<OcrPageInput>, options: OcrShapeOptions) -> ScannedNoteDraft {
    let scored = confidence_stats(&pages);
    // Repair runs before reconstruction, on the recognizer's own lines, so
    // that everything after it — classification, table detection, the title —
    // reads the repaired text rather than deciding what kind of page this is
    // from characters that were never on it. The stored text layer is built by
    // the caller from these same pages *before* shaping, so it keeps saying
    // what the recognizer actually reported.
    let mut pages = pages;
    let repaired = if options.repair_misreads {
        crate::misread::repair_pages(&mut pages)
    } else {
        0
    };
    let Some(mut reconstruction) = reconstruct(pages, &options) else {
        return empty_draft(0, scored);
    };
    if reconstruction.rows.is_empty() {
        return empty_draft(reconstruction.dropped, scored);
    }

    if options.strip_running_heads {
        let (rows, lines) = strip_running_heads(&mut reconstruction);
        reconstruction.stripped = rows;
        reconstruction.stripped_lines = lines;
    }
    if reconstruction.rows.is_empty() {
        return empty_draft(
            reconstruction.dropped + reconstruction.stripped_lines,
            scored,
        );
    }

    let preset = match options.preset {
        ScanPreset::Auto => classify(&reconstruction),
        chosen => chosen,
    };
    let render = render_options(&options, preset, &reconstruction);
    let rendered = doc::render(&reconstruction, &render);

    ScannedNoteDraft {
        title: extract_title(&reconstruction.rows),
        body: rendered.body,
        content_type: if rendered.markdown {
            "markdown".to_owned()
        } else {
            "plain".to_owned()
        },
        // Lines removed as furniture were counted as kept by the geometry
        // pass, which ran before anyone knew they were furniture. Moving them
        // across keeps kept + dropped equal to what the recognizer handed in.
        kept_lines: count(reconstruction.kept - reconstruction.stripped_lines),
        dropped_lines: count(reconstruction.dropped + reconstruction.stripped_lines),
        columns: i32::try_from(reconstruction.columns).unwrap_or(1),
        corrected_skew_degrees: reconstruction.worst_skew.atan().to_degrees(),
        pages: count(reconstruction.pages),
        tables: count(rendered.tables),
        headings: count(rendered.headings),
        stripped_running_heads: count(reconstruction.stripped),
        repaired_words: count(repaired),
        preset: preset.label().to_owned(),
        quality: scored,
    }
}

fn count(value: usize) -> i32 {
    i32::try_from(value).unwrap_or(i32::MAX)
}

fn empty_draft(dropped: usize, quality: CaptureQuality) -> ScannedNoteDraft {
    ScannedNoteDraft {
        title: String::new(),
        body: String::new(),
        content_type: "plain".to_owned(),
        kept_lines: 0,
        dropped_lines: count(dropped),
        columns: 0,
        corrected_skew_degrees: 0.0,
        pages: 0,
        tables: 0,
        headings: 0,
        stripped_running_heads: 0,
        repaired_words: 0,
        preset: ScanPreset::Prose.label().to_owned(),
        quality,
    }
}

/// Turn the caller's flags and the chosen preset into what the writer should
/// actually do. The preset wins on the questions it has an opinion about,
/// because picking "receipt" and still getting reflowed prose would be absurd.
fn render_options(
    options: &OcrShapeOptions,
    preset: ScanPreset,
    reconstruction: &Reconstruction,
) -> RenderOptions {
    let mut render = RenderOptions {
        preserve_line_breaks: options.preserve_line_breaks,
        detect_structure: options.detect_structure,
        detect_tables: options.detect_tables,
        heal_across_pages: options.heal_across_pages,
        code_block: false,
        label_values: false,
        paragraph_gap: reconstruction.median_height * PARAGRAPH_GAP_RATIO,
        median_height: reconstruction.median_height,
        content_left: reconstruction.content_left,
        content_right: reconstruction.content_right,
    };
    match preset {
        ScanPreset::Auto | ScanPreset::Prose => {}
        ScanPreset::BookPage => {
            render.heal_across_pages = true;
        }
        ScanPreset::Receipt => {
            render.preserve_line_breaks = true;
            render.detect_tables = false;
            render.detect_structure = false;
        }
        ScanPreset::Form => {
            render.preserve_line_breaks = true;
            render.label_values = true;
            render.detect_tables = false;
        }
        ScanPreset::Whiteboard => {
            render.preserve_line_breaks = true;
            render.detect_tables = false;
        }
        ScanPreset::Code => {
            render.preserve_line_breaks = true;
            render.detect_tables = false;
            render.detect_structure = false;
            render.code_block = true;
        }
        ScanPreset::Table => {
            render.detect_tables = true;
            render.detect_structure = true;
        }
    }
    render
}

// --- Reconstruction -------------------------------------------------------

fn reconstruct(pages: Vec<OcrPageInput>, options: &OcrShapeOptions) -> Option<Reconstruction> {
    let mut rows: Vec<Row> = Vec::new();
    let mut kept = 0usize;
    let mut dropped = 0usize;
    let mut worst_skew = 0.0f32;
    let mut columns = 1usize;
    let mut heights: Vec<f32> = Vec::new();
    let mut page_count = 0usize;
    let mut page_width = 0.0f32;
    let mut page_height = 0.0f32;

    for (index, page) in pages.into_iter().enumerate() {
        page_width = page_width.max(page.width);
        page_height = page_height.max(page.height);
        let total = page.lines.len();
        let usable = filter_lines(page.lines, options.min_confidence);
        if usable.is_empty() {
            dropped += total;
            continue;
        }
        // First reading of the line height, still carrying whatever the page's
        // tilt added to it. Good enough to sort specks from text and to find
        // the tilt itself, which is all it is used for.
        let provisional_height = median(usable.iter().map(|line| line.bottom - line.top));
        let usable = drop_specks(usable, provisional_height);
        if usable.is_empty() {
            dropped += total;
            continue;
        }

        kept += usable.len();
        dropped += total.saturating_sub(usable.len());

        // Take the page's tilt back out of the boxes before settling on the
        // line height everything downstream is scaled against — see
        // [`undo_tilt_inflation`]. Measuring first and correcting after would
        // scale every threshold by the error it is meant to absorb.
        // Read the lean off the boxes while they are still stretched — undoing
        // the stretch is what destroys the evidence — and spend it twice: once
        // to un-stretch them, once to tell the deskew below which way the page
        // leans.
        let tilt = estimate_tilt_tangent(&tilt_boxes(&usable));
        let usable = undo_tilt_inflation(usable, tilt);
        let median_height = median(usable.iter().map(|line| line.bottom - line.top));
        heights.extend(usable.iter().map(|line| line.bottom - line.top));

        // Now that the heights are honest the estimator bins by half a real
        // line rather than half an inflated one, which is a finer sieve.
        let slope = estimate_skew(&tilt_boxes(&usable), median_height, tilt);
        if slope.abs() > worst_skew.abs() {
            worst_skew = slope;
        }
        let placed = place(usable, median_height, slope, options.detect_columns);
        columns = columns.max(placed.iter().map(|line| line.column + 1).max().unwrap_or(1));
        rows.extend(build_rows(placed, median_height, index));
        page_count += 1;
    }

    if page_count == 0 {
        return Some(Reconstruction {
            rows: Vec::new(),
            median_height: 0.0,
            content_left: 0.0,
            content_right: 0.0,
            columns: 0,
            worst_skew: 0.0,
            kept: 0,
            dropped,
            stripped: 0,
            stripped_lines: 0,
            pages: 0,
            page_width,
            page_height,
        });
    }

    let content_left = rows.iter().map(|row| row.left).fold(f32::MAX, f32::min);
    let content_right = rows.iter().map(|row| row.right).fold(f32::MIN, f32::max);
    Some(Reconstruction {
        rows,
        median_height: median(heights.into_iter()),
        content_left,
        content_right,
        columns,
        worst_skew,
        kept,
        dropped,
        stripped: 0,
        stripped_lines: 0,
        pages: page_count,
        page_width,
        page_height,
    })
}

/// What a first reading reveals about a page's geometry.
#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct PageGeometry {
    /// Tilt as a slope, per [`estimate_skew`]. Negative leans left.
    pub skew_slope: f32,
    /// Median printed line height, with the tilt's inflation taken back out.
    pub median_line_height: f32,
    /// Lines that survived the noise filters.
    pub usable_lines: usize,
    /// Share of those lines whose box is wider than it is tall.
    ///
    /// A line of text is many times wider than it is tall, so on a page the
    /// right way up this is essentially 1. It collapses towards 0 when the
    /// *page* is sideways, because the recognizer then reports each column of
    /// glyphs as a tall, narrow box — which is the one page orientation the
    /// geometry can identify without reading the page again. See
    /// [`crate::api::prepare`].
    pub upright_share: f32,
}

/// Measure one page the way [`reconstruct`] does, without reconstructing it.
///
/// This is that function's per-page prologue and nothing more, exposed so
/// [`crate::api::prepare`] can decide whether the *image* is worth handing to
/// the recognizer a second time. Sharing the code rather than restating it is
/// the point: a retry rotates the pixels by the tilt this module would
/// otherwise have quietly sheared the boxes by, so the two can never disagree
/// about how crooked a page is.
///
/// `min_confidence` is deliberately not a parameter — the caller is deciding
/// how to re-photograph a page, not how to filter it, and a page whose lines
/// were all about to be dropped as uncertain is precisely one worth re-reading.
pub(crate) fn measure_page_geometry(page: &OcrPageInput) -> PageGeometry {
    let empty = PageGeometry {
        skew_slope: 0.0,
        median_line_height: 0.0,
        usable_lines: 0,
        upright_share: 0.0,
    };

    let usable = filter_lines(page.lines.clone(), 0.0);
    if usable.is_empty() {
        return empty;
    }
    let provisional_height = median(usable.iter().map(|line| line.bottom - line.top));
    let usable = drop_specks(usable, provisional_height);
    if usable.is_empty() {
        return empty;
    }
    let tilt = estimate_tilt_tangent(&tilt_boxes(&usable));
    let usable = undo_tilt_inflation(usable, tilt);
    let median_height = median(usable.iter().map(|line| line.bottom - line.top));
    let upright = usable
        .iter()
        .filter(|line| (line.right - line.left) > (line.bottom - line.top))
        .count();
    PageGeometry {
        skew_slope: estimate_skew(&tilt_boxes(&usable), median_height, tilt),
        median_line_height: median_height,
        usable_lines: usable.len(),
        upright_share: upright as f32 / usable.len() as f32,
    }
}

/// Collapse whitespace inside a recognized line. OCR routinely emits runs of
/// spaces where the image had wide letter spacing.
fn tidy(text: &str) -> String {
    let mut output = String::with_capacity(text.len());
    let mut in_space = false;
    for character in text.chars() {
        if is_dart_regexp_whitespace(character) {
            if !in_space {
                output.push(' ');
                in_space = true;
            }
        } else {
            output.push(character);
            in_space = false;
        }
    }
    dart_trim(&output).to_owned()
}

fn filter_lines(lines: Vec<OcrLineInput>, min_confidence: f32) -> Vec<OcrLineInput> {
    lines
        .into_iter()
        .filter(|line| {
            // A line with no reported confidence is kept: several recognizers
            // never populate it, and dropping those would empty the page.
            line.effective_confidence()
                .is_none_or(|score| score >= min_confidence)
        })
        .filter(|line| !tidy(&line.text).is_empty())
        .filter(|line| line.bottom > line.top && line.right > line.left)
        .collect()
}

fn median(values: impl Iterator<Item = f32>) -> f32 {
    let mut values: Vec<f32> = values.collect();
    if values.is_empty() {
        return 0.0;
    }
    values.sort_by(f32::total_cmp);
    let middle = values.len() / 2;
    if values.len().is_multiple_of(2) {
        (values[middle - 1] + values[middle]) / 2.0
    } else {
        values[middle]
    }
}

fn drop_specks(lines: Vec<OcrLineInput>, median_height: f32) -> Vec<OcrLineInput> {
    let floor = median_height * MIN_HEIGHT_RATIO;
    lines
        .into_iter()
        .filter(|line| (line.bottom - line.top) >= floor)
        .collect()
}

/// Take back the height a tilted page adds to every box.
///
/// A recognizer reports an axis-aligned rectangle, so a line rotated by `theta`
/// arrives as the bounding box of the rotated quad — taller than the text
/// itself by a share of the line's own *width*:
///
/// ```text
/// box height = height * cos(theta) + width  * sin(theta)
/// box width  = width  * cos(theta) + height * sin(theta)
/// ```
///
/// The two errors are nothing alike, because a line of prose is many times
/// wider than it is tall. At four degrees a full-width line already measures
/// twice its true height, while its width is out by a fraction of a percent.
///
/// That asymmetry is what makes it worth undoing. Every threshold in this
/// module is a multiple of the median line height — the row band, the paragraph
/// gap, the speck floor — so an inflated median widens the row band past the
/// printed line pitch, and [`build_rows`] starts welding consecutive lines of
/// body text into a single row.
///
/// The angle cannot be taken from [`estimate_skew`], tempting as that is. Skew
/// is measured from how boxes sit *relative to each other*, and a page whose
/// lines all start at the same margin shifts every box by the same amount when
/// it rotates — level and tilted look identical to the estimator, while the
/// boxes are inflated either way. It has to come from the boxes themselves.
///
/// It does, and cheaply. Across one page `height` and `theta` are near enough
/// constant, so eliminating the unmeasurable true `width` between the two
/// equations above leaves a straight line in the two numbers we do have:
///
/// ```text
/// box height = tan(theta) * box width + height * (cos(theta) - sin(theta) * tan(theta))
/// ```
///
/// Plot each box's height against its *measured* width and the gradient is
/// `tan(theta)` — not `sin(theta)`, which is the gradient against the true
/// width nobody reports. A least-squares fit recovers the tilt from nothing but
/// the boxes, which is why this needs no per-line angle from the platform —
/// several recognizers report none, and iOS is one of them.
///
/// Recovering the height then means solving the pair for it, rather than
/// rearranging one equation and hoping the other's error is small:
///
/// ```text
/// height = (box height - box width * tan) * sqrt(1 + tan^2) / (1 - tan^2)
/// ```
///
/// What the fit needs is a spread of line widths, which ordinary ragged-right
/// prose has in abundance. A page whose lines are all one width tells us
/// nothing, and is left alone rather than guessed at. So are pages that fit a
/// backwards or implausible tilt: the estimate is only ever allowed to shrink a
/// box, never to grow one.
///
/// Only heights are restored. Widths are left as measured: their error is
/// `height * sin(theta)`, negligible for a line of text, and column detection
/// reads more steadily off the edges the recognizer actually reported.
fn undo_tilt_inflation(lines: Vec<OcrLineInput>, tan: Option<f32>) -> Vec<OcrLineInput> {
    let Some(tan) = tan else {
        return lines;
    };
    let scale = (1.0 + tan * tan).sqrt() / (1.0 - tan * tan);
    /// One box, un-stretched in place. Returns the original extent when the
    /// correction does not apply, so the caller can use it on any box.
    fn unstretch(top: f32, bottom: f32, left: f32, right: f32, tan: f32, scale: f32) -> (f32, f32) {
        let box_height = bottom - top;
        let height = (box_height - (right - left) * tan) * scale;
        // Tilt only ever adds height, so a correction that would grow a box is
        // not one. That also covers the box lying at its own angle to the rest
        // of the page, which a whole-page fit cannot speak for.
        if !height.is_finite() || height <= 0.0 || height >= box_height {
            return (top, bottom);
        }
        // Rotation leaves a box's centre where it was, so the true line sits
        // centred inside the inflated one.
        let centre = (top + bottom) / 2.0;
        (centre - height / 2.0, centre + height / 2.0)
    }
    lines
        .into_iter()
        .map(|line| {
            let (top, bottom) = unstretch(line.top, line.bottom, line.left, line.right, tan, scale);
            // Word boxes are inflated by exactly the same rotation and are read
            // back out as highlight geometry, so they are corrected too rather
            // than left describing a taller box than the line containing them.
            let words = line
                .words
                .into_iter()
                .map(|word| {
                    let (top, bottom) =
                        unstretch(word.top, word.bottom, word.left, word.right, tan, scale);
                    OcrWordInput {
                        top,
                        bottom,
                        ..word
                    }
                })
                .collect();
            OcrLineInput {
                top,
                bottom,
                words,
                ..line
            }
        })
        .collect()
}

/// A rectangle the geometry passes reason about, wherever it came from.
///
/// The tilt and skew estimators care only about where boxes sit and how big
/// they are, never about what they say, so they work off these rather than off
/// [`OcrLineInput`] — which is what lets the same code read a page's lean off
/// word boxes when the recognizer supplied them and off line boxes when it did
/// not.
#[derive(Clone, Copy, Debug)]
pub(crate) struct Box2 {
    left: f32,
    top: f32,
    right: f32,
    bottom: f32,
}

impl Box2 {
    fn width(&self) -> f32 {
        self.right - self.left
    }

    fn height(&self) -> f32 {
        self.bottom - self.top
    }

    fn centre_x(&self) -> f32 {
        (self.left + self.right) / 2.0
    }

    fn centre_y(&self) -> f32 {
        (self.top + self.bottom) / 2.0
    }
}

/// Most boxes the direction vote will look at. It compares every pair, so an
/// unbounded input makes a dense page quadratic in its word count; past this
/// the boxes are sampled evenly across the page instead, which keeps the
/// evidence spread over the whole sheet rather than over its first rows.
const MAX_DIRECTION_BOXES: usize = 320;

/// The boxes to read a page's geometry from: its words when the recognizer
/// broke the lines down, otherwise the lines themselves.
///
/// Words are strictly better evidence and it is worth saying why. The tilt fit
/// needs a spread of box widths, and words vary far more than lines do. More
/// importantly, [`tilt_direction`] can only vote on boxes that share a printed
/// line — so on a page reported as one box per row it has nothing to say, and
/// [`estimate_skew`] gives up and leaves the page uncorrected. Every line of
/// words is a row of row-mates, which turns the page that could not be
/// straightened at all into the ordinary case.
fn tilt_boxes(lines: &[OcrLineInput]) -> Vec<Box2> {
    let words: Vec<Box2> = lines
        .iter()
        .flat_map(|line| line.words.iter())
        .filter(|word| word.bottom > word.top && word.right > word.left)
        .map(|word| Box2 {
            left: word.left,
            top: word.top,
            right: word.right,
            bottom: word.bottom,
        })
        .collect();
    if words.len() > lines.len() && words.len() >= MIN_LINES_FOR_TILT_FIT {
        return words;
    }
    lines
        .iter()
        .map(|line| Box2 {
            left: line.left,
            top: line.top,
            right: line.right,
            bottom: line.bottom,
        })
        .collect()
}

/// Thin `boxes` to at most [MAX_DIRECTION_BOXES], keeping them spread evenly.
fn sampled(boxes: &[Box2]) -> Vec<Box2> {
    if boxes.len() <= MAX_DIRECTION_BOXES {
        return boxes.to_vec();
    }
    let stride = boxes.len() as f32 / MAX_DIRECTION_BOXES as f32;
    (0..MAX_DIRECTION_BOXES)
        .map(|index| boxes[((index as f32 * stride) as usize).min(boxes.len() - 1)])
        .collect()
}

/// Least-squares gradient of box height against box width, which is the tangent
/// of the page's tilt. Always positive: the stretch is the same whichever way
/// the page leans, so this is a magnitude and [`tilt_direction`] supplies the
/// sign. [`None`] when the page cannot answer the question — see
/// [`undo_tilt_inflation`].
fn estimate_tilt_tangent(boxes: &[Box2]) -> Option<f32> {
    if boxes.len() < MIN_LINES_FOR_TILT_FIT {
        return None;
    }
    let count = boxes.len() as f32;
    let widths = || boxes.iter().map(Box2::width);
    let mean_width = widths().sum::<f32>() / count;
    let mean_height = boxes.iter().map(Box2::height).sum::<f32>() / count;

    // Boxes all cut to one width carry no evidence either way: every one is
    // inflated by the same amount, so nothing in the spread reveals it.
    let narrowest = widths().fold(f32::MAX, f32::min);
    let widest = widths().fold(f32::MIN, f32::max);
    if mean_width <= 0.0 || widest - narrowest < mean_width * MIN_WIDTH_SPREAD {
        return None;
    }

    let mut covariance = 0.0f32;
    let mut variance = 0.0f32;
    for item in boxes {
        let width_offset = item.width() - mean_width;
        covariance += width_offset * (item.height() - mean_height);
        variance += width_offset * width_offset;
    }
    if variance <= f32::EPSILON {
        return None;
    }

    let sine = covariance / variance;
    // Below the floor the inflation is not worth correcting and the fit is
    // mostly noise; above the ceiling the page is tilted further than this
    // module corrects for at all, so the fit is more likely measuring a page
    // whose headings are simply wider than its body text.
    (MIN_CORRECTED_TILT_TANGENT..=MAX_CORRECTED_TILT_TANGENT)
        .contains(&sine)
        .then_some(sine)
}

/// Which way the page leans, voted on by the boxes that share a printed line.
/// Positive leans right, negative leans left, and zero means the page declined
/// to say.
///
/// This answers the one question [`estimate_tilt_tangent`] cannot. A box grows
/// by the same amount whichever way its line leans, so the stretch says how far
/// the page is tilted but never which side.
///
/// Only row-mates can answer it, and only they are asked. Two boxes on the same
/// printed line sit apart horizontally by construction, and whatever height
/// difference there is between them is the tilt and nothing else — so the sign
/// of `dy * dx`, weighted by how far apart they are, is a direct reading. Real
/// recognizers hand back several boxes per visual row, which is where this gets
/// its evidence.
///
/// The `magnitude` bound is what makes it safe rather than merely plausible. A
/// pair is only counted when its height difference is no more than the known
/// tilt could account for across the gap between them. That admits genuine
/// row-mates, whose separation *is* the tilt, and rejects boxes a line or more
/// apart — the pairs that a whole-page angle search mistakes for row-mates when
/// a shear of about one line pitch aliases each row onto its neighbour.
///
/// A page of single-box rows has no row-mates and so no vote, which is the
/// honest answer: with every line starting at the same margin and only its
/// width to vary its centre, nothing in the geometry distinguishes a page
/// leaning left from the same page leaning right. Word boxes, where the
/// recognizer reports them, turn every row into row-mates and remove that case
/// — see [`tilt_boxes`].
fn tilt_direction(boxes: &[Box2], magnitude: f32, median_height: f32) -> f32 {
    let boxes = &sampled(boxes);
    let tolerance = median_height * DIRECTION_TOLERANCE_RATIO;
    // Leaning left, leaning right. A pair supports a lean when its height
    // difference is what that lean would produce across the gap between the
    // two — that is what being on the same printed line means once the page is
    // tilted. Testing the residual, rather than merely whether the pair is
    // close enough vertically, is what separates the two answers: a real
    // row-mate matches one sign and misses the other by twice the tilt.
    let mut support = [0.0f32; 2];
    let mut counted = [0usize; 2];
    for (index, first) in boxes.iter().enumerate() {
        for second in &boxes[index + 1..] {
            let across = second.centre_x() - first.centre_x();
            let down = second.centre_y() - first.centre_y();
            // Boxes stacked nearly on top of each other give no leverage: a
            // sliver of horizontal separation turns any noise into a landslide.
            if across.abs() < median_height {
                continue;
            }
            for (slot, sign) in [(0usize, -1.0f32), (1, 1.0)] {
                let residual = (down - sign * magnitude * across).abs();
                if residual > tolerance {
                    continue;
                }
                // Weight by how squarely the pair lands on the lean, not merely
                // by whether it fits. Boxes that really do share a line sit
                // exactly where the tilt predicts and count for their full
                // separation; a pair that only scrapes inside the tolerance —
                // which is how rows two or five apart sneak in when a shear
                // aliases them onto each other — counts for almost nothing.
                support[slot] += (1.0 - residual / tolerance) * across.abs();
                counted[slot] += 1;
            }
        }
    }

    // Both answers explain the page about equally well, so neither is evidence.
    // That is the usual state of a single-column page of ragged-right prose,
    // where the only thing moving a line's centre sideways is its own length: a
    // handful of pairs will fit a backwards lean by coincidence, and without a
    // clear margin over the alternative they would decide the whole page.
    let (weaker, stronger) = if support[0] > support[1] {
        (support[1], support[0])
    } else {
        (support[0], support[1])
    };
    if counted[0].max(counted[1]) < MIN_ROW_MATES_FOR_DIRECTION
        || stronger < weaker * DIRECTION_MARGIN
    {
        return 0.0;
    }
    support[1] - support[0]
}

fn input_centre_x(line: &OcrLineInput) -> f32 {
    (line.left + line.right) / 2.0
}

/// Estimate how far the page is tilted, as a slope.
///
/// Measured by projection profile, the standard approach: shear the page by a
/// candidate angle, drop every line's centre into a horizontal bin, and score
/// how concentrated the result is. At the true angle the printed lines fall
/// into the same bins and the profile spikes; at any other angle they smear
/// across neighbours. The best-scoring candidate is the skew.
///
/// The obvious alternative — measuring the slope between boxes that look like
/// they share a line — has a chicken-and-egg problem: deciding which boxes
/// share a line is exactly what the skew is needed for, and on a steeply
/// tilted page the true row-mates are further apart vertically than lines from
/// neighbouring rows. Scoring whole-page alignment sidesteps that.
fn estimate_skew(boxes: &[Box2], median_height: f32, tilt_tangent: Option<f32>) -> f32 {
    if boxes.len() < 3 || median_height <= 0.0 {
        return 0.0;
    }
    let bin = (median_height * 0.5).max(1.0);

    // When the boxes could be measured, believe them instead of searching.
    // [`estimate_tilt_tangent`] reads the lean off how much each box was
    // stretched and [`tilt_direction`] reads which way off where the centres
    // sit; between them the answer is already known, and neither can be
    // flattered by a choice of angle. The tangent arrives as an argument rather
    // than being read here because by this point the boxes have been
    // un-stretched, and the stretch was the evidence.
    //
    // The search below cannot be trusted with this. Its score squares each
    // bin's weight, so two lines sharing a bin always beat the same two apart,
    // and on evenly spaced prose a shear of about one line pitch aliases every
    // row onto its neighbour and scores wonderfully. Measured against a page
    // tilted 10 degrees right it returned a slope tilted 10 degrees *left*,
    // welding pairs of lines together; SKEW_PRIOR made that wholly wrong answer
    // give up only 8% of its score. And on a page with one box per row the
    // score is flat — every line sits in its own bin at any angle — so there is
    // nothing there to find even when it is not actively misleading.
    if let Some(tangent) = tilt_tangent {
        let magnitude = tangent.abs().min(MAX_SKEW_SLOPE);
        let direction = tilt_direction(boxes, magnitude, median_height);
        // No row-mates, no sign — and a page whose rows hold one box each has
        // nothing to gain from being sheared anyway, since there is nothing to
        // join up. Leaving it as measured beats guessing and getting it
        // backwards, which drags each row onto the one below.
        if direction == 0.0 {
            return 0.0;
        }
        return if direction < 0.0 {
            -magnitude
        } else {
            magnitude
        };
    }

    let mut best_slope = 0.0f32;
    let mut best_score = f32::MIN;
    // Walk outwards from level so that, on a page where several angles fit
    // equally well, the one claiming the least correction wins.
    for step in (0..=SKEW_STEPS).flat_map(|step| {
        if step == 0 {
            vec![0i32]
        } else {
            vec![step, -step]
        }
    }) {
        let lean = step as f32 / SKEW_STEPS as f32;
        let slope = MAX_SKEW_SLOPE * lean;
        let score = alignment_score(boxes, slope, bin) * (1.0 - SKEW_PRIOR * lean * lean);
        if score > best_score {
            best_score = score;
            best_slope = slope;
        }
    }
    best_slope
}

/// How tightly the lines stack up once sheared by `slope`.
///
/// Bins are weighted by box width rather than counted, so a full text line
/// carries more evidence than a stray page number, and squared so that one
/// crowded bin beats two half-full ones.
fn alignment_score(boxes: &[Box2], slope: f32, bin: f32) -> f32 {
    let mut bins: std::collections::HashMap<i64, f32> = std::collections::HashMap::new();
    for item in boxes {
        let deskewed = item.centre_y() - slope * item.centre_x();
        let key = (deskewed / bin).round() as i64;
        *bins.entry(key).or_insert(0.0) += item.width();
    }
    bins.values().map(|weight| weight * weight).sum()
}

/// Straighten the lines, work out the column structure, and sort into reading
/// order: band by band down the page, column by column inside each band.
fn place(
    lines: Vec<OcrLineInput>,
    median_height: f32,
    slope: f32,
    detect_columns: bool,
) -> Vec<Placed> {
    // Deskew by shearing each box vertically by the tilt across its own centre,
    // which makes vertical positions comparable right across the page.
    let mut placed: Vec<Placed> = lines
        .into_iter()
        .map(|line| {
            let shift = slope * input_centre_x(&line);
            Placed {
                text: tidy(&line.text),
                left: line.left,
                right: line.right,
                top: line.top - shift,
                bottom: line.bottom - shift,
                band: 0,
                column: 0,
                full_width: false,
            }
        })
        .collect();

    let left = placed.iter().map(|line| line.left).fold(f32::MAX, f32::min);
    let right = placed
        .iter()
        .map(|line| line.right)
        .fold(f32::MIN, f32::max);
    let content_width = right - left;
    for line in &mut placed {
        line.full_width = content_width > 0.0 && line.width() >= content_width * FULL_WIDTH_RATIO;
    }

    let columns = if detect_columns {
        detect_columns_in(&placed, median_height, content_width)
    } else {
        Vec::new()
    };

    if !columns.is_empty() {
        for line in &mut placed {
            line.column = if line.full_width {
                0
            } else {
                column_of(line, &columns)
            };
        }
        assign_bands(&mut placed);
    }

    // Order by row rather than by exact height. Deskewing lands row-mates on
    // *almost* the same y, and comparing those raw would let a rounding
    // difference of a millionth of a pixel decide which half of a line comes
    // first. Quantizing to half a row band makes the comparison a real total
    // order and leaves the left edge to break ties, which is the reading order
    // within a line.
    let bucket = (median_height * ROW_BAND_RATIO / 2.0).max(0.5);
    placed.sort_by(|a, b| {
        a.band
            .cmp(&b.band)
            .then_with(|| a.column.cmp(&b.column))
            .then_with(|| row_bucket(a.top, bucket).cmp(&row_bucket(b.top, bucket)))
            .then_with(|| a.left.total_cmp(&b.left))
    });
    placed
}

fn row_bucket(top: f32, bucket: f32) -> i64 {
    (top / bucket).round() as i64
}

/// Left-to-right column x-ranges, or empty when the page is not columnar.
fn detect_columns_in(lines: &[Placed], median_height: f32, content_width: f32) -> Vec<(f32, f32)> {
    let body: Vec<&Placed> = lines.iter().filter(|line| !line.full_width).collect();
    if body.len() < MIN_COLUMN_LINES * 2 || content_width <= 0.0 {
        return Vec::new();
    }
    let top = body.iter().map(|line| line.top).fold(f32::MAX, f32::min);
    let bottom = body.iter().map(|line| line.bottom).fold(f32::MIN, f32::max);
    let content_height = bottom - top;
    // A page only a few lines tall cannot be told apart from one wide row.
    if content_height < median_height * MIN_COLUMNAR_HEIGHT_RATIO {
        return Vec::new();
    }

    // Merge the horizontal spans; whatever is left between them is a gutter.
    let mut spans: Vec<(f32, f32)> = body.iter().map(|line| (line.left, line.right)).collect();
    spans.sort_by(|a, b| a.0.total_cmp(&b.0));
    let minimum_gutter = content_width * GUTTER_WIDTH_RATIO;
    let mut merged: Vec<(f32, f32)> = Vec::new();
    for (start, end) in spans {
        match merged.last_mut() {
            Some(last) if start - last.1 < minimum_gutter => last.1 = last.1.max(end),
            _ => merged.push((start, end)),
        }
    }
    if merged.len() < 2 {
        return Vec::new();
    }

    // Together, columns of prose nearly fill the page. Anything sparser is a
    // table, and reading it down each cell column would scramble its rows.
    let covered: f32 = merged.iter().map(|(start, end)| end - start).sum();
    if covered / content_width < MIN_COLUMN_COVERAGE {
        return Vec::new();
    }

    // Real columns hold several lines each and run most of the way down. One
    // that does not means the gap was a coincidence, so the page is left alone.
    for (start, end) in &merged {
        let inside: Vec<&&Placed> = body
            .iter()
            .filter(|line| line.centre_x() >= *start && line.centre_x() <= *end)
            .collect();
        if inside.len() < MIN_COLUMN_LINES {
            return Vec::new();
        }
        let column_top = inside.iter().map(|line| line.top).fold(f32::MAX, f32::min);
        let column_bottom = inside
            .iter()
            .map(|line| line.bottom)
            .fold(f32::MIN, f32::max);
        if (column_bottom - column_top) < content_height * MIN_COLUMN_HEIGHT_RATIO {
            return Vec::new();
        }
    }
    merged
}

fn column_of(line: &Placed, columns: &[(f32, f32)]) -> usize {
    let centre = line.centre_x();
    columns
        .iter()
        .position(|(start, end)| centre >= *start && centre <= *end)
        .unwrap_or_else(|| {
            // Straddles a gutter: give it to the nearest column so it is read
            // somewhere sensible rather than dropped.
            columns
                .iter()
                .enumerate()
                .min_by(|(_, a), (_, b)| {
                    let to_a = (centre - (a.0 + a.1) / 2.0).abs();
                    let to_b = (centre - (b.0 + b.1) / 2.0).abs();
                    to_a.total_cmp(&to_b)
                })
                .map_or(0, |(index, _)| index)
        })
}

/// Full-width lines cut the page into bands, so a banner headline is read
/// before the columns beneath it rather than folded into the first one.
fn assign_bands(lines: &mut [Placed]) {
    let mut dividers: Vec<f32> = lines
        .iter()
        .filter(|line| line.full_width)
        .map(|line| line.bottom)
        .collect();
    if dividers.is_empty() {
        return;
    }
    dividers.sort_by(f32::total_cmp);
    for line in lines.iter_mut() {
        // Comparing on the top edge means a divider opens the band it sits in:
        // its own bottom is below its top, so it does not count itself.
        line.band = dividers
            .iter()
            .filter(|divider| **divider <= line.top)
            .count();
    }
}

/// Merge boxes that share a printed line. Only within one band and column —
/// two boxes level with each other in different columns are different lines.
///
/// The merged pieces are kept as [`RowCell`]s: a table is exactly a run of
/// rows whose pieces line up, so throwing them away would make tables
/// impossible to see.
fn build_rows(lines: Vec<Placed>, median_height: f32, page: usize) -> Vec<Row> {
    let band = (median_height * ROW_BAND_RATIO).max(1.0);
    let mut rows: Vec<Row> = Vec::new();
    for line in lines {
        let centre = line.centre_y();
        let same_row = rows.last().is_some_and(|row| {
            row.band == line.band
                && row.column == line.column
                && ((row.top + row.bottom) / 2.0 - centre).abs() <= band
        });
        if same_row {
            let row = rows.last_mut().expect("checked by same_row");
            row.text.push(' ');
            row.text.push_str(&line.text);
            row.top = row.top.min(line.top);
            row.bottom = row.bottom.max(line.bottom);
            row.height = row.bottom - row.top;
            row.right = row.right.max(line.right);
            row.cells.push(RowCell {
                text: line.text,
                left: line.left,
                right: line.right,
            });
        } else {
            rows.push(Row {
                cells: vec![RowCell {
                    text: line.text.clone(),
                    left: line.left,
                    right: line.right,
                }],
                text: line.text,
                left: line.left,
                right: line.right,
                top: line.top,
                bottom: line.bottom,
                height: line.bottom - line.top,
                band: line.band,
                column: line.column,
                page,
            });
        }
    }
    rows
}

// --- Running heads --------------------------------------------------------

/// Drop the lines a book repeats on every page: the running head, the running
/// foot, and the page number.
///
/// Matching is on the text with its digits removed, so `Chapter 3 · 47` and
/// `Chapter 3 · 48` are recognized as the same furniture, and a bare page
/// number reduces to nothing at all — which is why an emptied line counts as a
/// match only when it sits at the very top or bottom of the page.
fn strip_running_heads(reconstruction: &mut Reconstruction) -> (usize, usize) {
    if reconstruction.pages < MIN_PAGES_FOR_RUNNING_HEADS {
        return (0, 0);
    }
    let edges: Vec<Option<bool>> = edge_positions(&reconstruction.rows);
    let mut seen: std::collections::HashMap<(bool, String), std::collections::HashSet<usize>> =
        std::collections::HashMap::new();
    for (index, row) in reconstruction.rows.iter().enumerate() {
        let Some(top) = edges[index] else {
            continue;
        };
        let key = (top, running_key(&row.text));
        seen.entry(key).or_default().insert(row.page);
    }

    let needed = (reconstruction.pages as f32 * RUNNING_HEAD_SHARE).ceil() as usize;
    let repeated: std::collections::HashSet<(bool, String)> = seen
        .into_iter()
        .filter(|(_, pages)| pages.len() >= needed.max(2))
        .map(|(key, _)| key)
        .collect();
    if repeated.is_empty() {
        return (0, 0);
    }

    let keep: Vec<bool> = reconstruction
        .rows
        .iter()
        .zip(edges)
        .map(|(row, edge)| {
            !edge.is_some_and(|top| repeated.contains(&(top, running_key(&row.text))))
        })
        .collect();
    // A row was assembled from one cell per recognized line, so its cell count
    // is exactly how many of the recognizer's lines leave with it.
    let lines: usize = reconstruction
        .rows
        .iter()
        .zip(&keep)
        .filter(|(_, keeping)| !**keeping)
        .map(|(row, _)| row.cells.len())
        .sum();
    let before = reconstruction.rows.len();
    let mut keep = keep.into_iter();
    reconstruction.rows.retain(|_| keep.next().unwrap_or(true));
    (before - reconstruction.rows.len(), lines)
}

/// For each row: `Some(true)` near the top of its page, `Some(false)` near the
/// bottom, `None` for body text — only the edges can be furniture.
///
/// The depth shrinks on a short page. Two rows deep into a three-row page
/// reaches the body, and a body line that differs from its neighbours only by
/// a number would then be mistaken for a page number and deleted.
fn edge_positions(rows: &[Row]) -> Vec<Option<bool>> {
    let mut edges = vec![None; rows.len()];
    let mut start = 0usize;
    while start < rows.len() {
        let page = rows[start].page;
        let mut end = start;
        while end < rows.len() && rows[end].page == page {
            end += 1;
        }
        let depth = if end - start >= RUNNING_HEAD_DEPTH * 2 + 1 {
            RUNNING_HEAD_DEPTH
        } else {
            1
        };
        for (offset, edge) in edges[start..end].iter_mut().enumerate() {
            let from_end = (end - start) - offset;
            *edge = if offset < depth {
                Some(true)
            } else if from_end <= depth {
                Some(false)
            } else {
                None
            };
        }
        start = end;
    }
    edges
}

/// The part of a line that stays the same from page to page.
fn running_key(text: &str) -> String {
    let mut key = String::with_capacity(text.len());
    for character in text.chars() {
        if character.is_ascii_digit() {
            continue;
        }
        if is_dart_regexp_whitespace(character) {
            if !key.ends_with(' ') {
                key.push(' ');
            }
        } else {
            key.extend(character.to_lowercase());
        }
    }
    dart_trim(&key).to_owned()
}

// --- Classification -------------------------------------------------------

/// Work out what kind of page this is from its geometry alone.
///
/// Ordered most specific first: a page can look like several of these at once,
/// and the narrower reading is the one worth acting on.
fn classify(reconstruction: &Reconstruction) -> ScanPreset {
    let rows = &reconstruction.rows;
    if rows.len() < 3 {
        return ScanPreset::Prose;
    }
    let digits = digit_share(rows);
    let symbols = symbol_share(rows);
    let content_width = (reconstruction.content_right - reconstruction.content_left).max(1.0);
    let narrow = reconstruction.page_width > 0.0
        && reconstruction.page_height / reconstruction.page_width.max(1.0) > 1.8;

    // A page that is mostly aligned multi-cell rows is a table, whatever else
    // it looks like.
    let aligned = rows.iter().filter(|row| row.cells.len() >= 3).count();
    if aligned * 2 >= rows.len() && aligned >= 3 {
        return ScanPreset::Table;
    }

    // Receipts: narrow, digit-heavy, short lines, one column.
    if reconstruction.columns == 1 && digits > 0.2 && narrow {
        return ScanPreset::Receipt;
    }

    // Code: punctuation-heavy and stepped indentation.
    if symbols > 0.12 && indent_levels(rows, reconstruction.median_height) >= 2 {
        return ScanPreset::Code;
    }

    // Forms: most rows read `label: value`.
    let labelled = rows.iter().filter(|row| looks_labelled(&row.text)).count();
    if labelled * 2 >= rows.len() && labelled >= 3 {
        return ScanPreset::Form;
    }

    // Whiteboards: sparse, short, scattered lines that never fill the width.
    let mean_fill = rows
        .iter()
        .map(|row| (row.right - row.left) / content_width)
        .sum::<f32>()
        / rows.len() as f32;
    if mean_fill < 0.3 && rows.len() >= 4 && reconstruction.pages == 1 {
        return ScanPreset::Whiteboard;
    }

    if reconstruction.pages >= MIN_PAGES_FOR_RUNNING_HEADS {
        return ScanPreset::BookPage;
    }
    ScanPreset::Prose
}

fn digit_share(rows: &[Row]) -> f32 {
    let mut digits = 0usize;
    let mut total = 0usize;
    for row in rows {
        for character in row.text.chars().filter(|c| !c.is_whitespace()) {
            total += 1;
            if character.is_ascii_digit() {
                digits += 1;
            }
        }
    }
    if total == 0 {
        0.0
    } else {
        digits as f32 / total as f32
    }
}

fn symbol_share(rows: &[Row]) -> f32 {
    const CODE_SYMBOLS: &str = "{}[]()<>;=+*/&|!%_#@\\\"'`~^";
    let mut symbols = 0usize;
    let mut total = 0usize;
    for row in rows {
        for character in row.text.chars().filter(|c| !c.is_whitespace()) {
            total += 1;
            if CODE_SYMBOLS.contains(character) {
                symbols += 1;
            }
        }
    }
    if total == 0 {
        0.0
    } else {
        symbols as f32 / total as f32
    }
}

/// How many distinct left edges the rows sit at, a step apart or more.
fn indent_levels(rows: &[Row], median_height: f32) -> usize {
    let step = (median_height * 0.8).max(1.0);
    let mut edges: Vec<f32> = rows.iter().map(|row| row.left).collect();
    edges.sort_by(f32::total_cmp);
    let mut levels = 0usize;
    let mut last = f32::MIN;
    for edge in edges {
        if edge - last >= step {
            levels += 1;
            last = edge;
        }
    }
    levels
}

fn looks_labelled(text: &str) -> bool {
    let Some(colon) = text.find(':') else {
        return false;
    };
    // A label is short and something follows it. `12:30` is a time, not a label.
    let label = &text[..colon];
    let value = text[colon + 1..].trim();
    !label.is_empty()
        && !value.is_empty()
        && label.chars().count() <= 32
        && label.chars().any(char::is_alphabetic)
        && !label.chars().all(|c| c.is_ascii_digit())
}

// --- Capture quality ------------------------------------------------------

fn confidence_stats(pages: &[OcrPageInput]) -> CaptureQuality {
    let scores: Vec<f32> = pages
        .iter()
        .flat_map(|page| page.lines.iter())
        .filter_map(|line| line.effective_confidence())
        .collect();
    if scores.is_empty() {
        return CaptureQuality {
            verdict: QualityVerdict::Unknown,
            mean_confidence: 0.0,
            low_confidence_share: 0.0,
            scored_lines: 0,
            advice: String::new(),
        };
    }
    let mean = scores.iter().sum::<f32>() / scores.len() as f32;
    let low = scores
        .iter()
        .filter(|score| **score < LOW_CONFIDENCE)
        .count() as f32
        / scores.len() as f32;
    let verdict = if low >= POOR_CONFIDENCE_SHARE {
        QualityVerdict::Poor
    } else if low >= FAIR_CONFIDENCE_SHARE {
        QualityVerdict::Fair
    } else {
        QualityVerdict::Good
    };
    let advice = match verdict {
        QualityVerdict::Poor => {
            "Much of this page came out uncertain. Try again with more light and the camera square to the page."
        }
        QualityVerdict::Fair => "Some lines were hard to read. A steadier shot would help.",
        _ => "",
    };
    CaptureQuality {
        verdict,
        mean_confidence: mean,
        low_confidence_share: low,
        scored_lines: count(scores.len()),
        advice: advice.to_owned(),
    }
}

// --- Title ----------------------------------------------------------------

/// Take the headline if the page has one, else the opening row.
///
/// A title is only "found" when a row near the top is meaningfully taller than
/// the body text; otherwise a scan of plain prose would get an arbitrary
/// fragment of its first sentence promoted to a heading.
fn extract_title(rows: &[Row]) -> String {
    let Some(first) = rows.first() else {
        return String::new();
    };
    let body_height = median(rows.iter().map(|row| row.height));
    let headline = rows
        .iter()
        .take(3)
        .filter(|row| row.height >= body_height * 1.25)
        .max_by(|a, b| a.height.total_cmp(&b.height));
    truncate_title(&headline.unwrap_or(first).text)
}

/// Cap the title at [MAX_TITLE_UNITS] UTF-16 units, breaking at a word edge so
/// the result reads as a phrase rather than a severed word.
fn truncate_title(text: &str) -> String {
    let trimmed = dart_trim(text);
    if trimmed.encode_utf16().count() <= MAX_TITLE_UNITS {
        return trimmed.to_owned();
    }
    let mut units = 0usize;
    let mut cut = trimmed.len();
    for (index, character) in trimmed.char_indices() {
        let width = character.len_utf16();
        if units + width > MAX_TITLE_UNITS {
            cut = index;
            break;
        }
        units += width;
    }
    let head = &trimmed[..cut];
    let broken = head
        .rfind(' ')
        .filter(|space| *space >= MAX_TITLE_UNITS / 2)
        .map_or(head, |space| &head[..space]);
    format!("{}…", dart_trim(broken))
}

#[cfg(test)]
mod tests {
    use super::*;

    pub(super) fn line(text: &str, top: f32, left: f32) -> OcrLineInput {
        sized(text, top, left, 20.0, 200.0)
    }

    pub(super) fn sized(text: &str, top: f32, left: f32, height: f32, width: f32) -> OcrLineInput {
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

    /// The same line, broken into evenly spaced word boxes — what a recognizer
    /// that reports word detail hands back.
    pub(super) fn with_words(line: OcrLineInput) -> OcrLineInput {
        let words: Vec<&str> = line.text.split(' ').filter(|w| !w.is_empty()).collect();
        if words.is_empty() {
            return line;
        }
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
                OcrWordInput {
                    text: (*word).to_owned(),
                    left,
                    top: line.top,
                    right: left + width,
                    bottom: line.bottom,
                    confidence: None,
                }
            })
            .collect();
        OcrLineInput {
            words: boxes,
            ..line
        }
    }

    /// The tilt the geometry pass would fit, off whichever boxes it would use.
    fn fitted(lines: &[OcrLineInput]) -> Option<f32> {
        estimate_tilt_tangent(&tilt_boxes(lines))
    }

    /// Un-stretch a page exactly as `reconstruct` does: fit first, correct
    /// with what was fitted.
    fn straighten(lines: Vec<OcrLineInput>) -> Vec<OcrLineInput> {
        let tilt = fitted(&lines);
        undo_tilt_inflation(lines, tilt)
    }

    /// Plain reading, with structure detection off — the behaviour every
    /// geometry test wants to pin without Markdown getting in the way.
    fn plain(lines: Vec<OcrLineInput>) -> ScannedNoteDraft {
        shape_scanned_text(
            lines,
            OcrShapeOptions {
                detect_structure: false,
                detect_tables: false,
                preset: ScanPreset::Prose,
                ..OcrShapeOptions::default()
            },
        )
    }

    fn shape(lines: Vec<OcrLineInput>) -> ScannedNoteDraft {
        shape_scanned_text(lines, OcrShapeOptions::default())
    }

    fn page(lines: Vec<OcrLineInput>) -> OcrPageInput {
        OcrPageInput {
            lines,
            width: 1000.0,
            height: 1400.0,
        }
    }

    /// Tilt a page the way a *recognizer* reports one.
    ///
    /// [`tilt`] slides boxes down the page and leaves their size alone, which
    /// is a page tilted in the abstract — no camera produces that. A real
    /// recognizer hands back the axis-aligned bounds of each rotated line, so
    /// every box also grows by its own width times the sine of the angle. That
    /// growth is the whole difficulty of a photographed page, so the tests that
    /// care about it need a page that has it.
    fn photographed(lines: Vec<OcrLineInput>, degrees: f32) -> Vec<OcrLineInput> {
        let theta = degrees.to_radians();
        let (sin, cos) = (theta.sin().abs(), theta.cos());
        /// One box as the recognizer would report it once the page is turned.
        fn turned(
            left: f32,
            top: f32,
            right: f32,
            bottom: f32,
            theta: f32,
            sin: f32,
            cos: f32,
        ) -> (f32, f32, f32, f32) {
            let (cx, cy) = ((left + right) / 2.0, (top + bottom) / 2.0);
            let (width, height) = (right - left, bottom - top);
            let box_width = width * cos + height * sin;
            let box_height = height * cos + width * sin;
            // Rotating the page about the origin moves the centre too.
            let shift = theta.tan() * cx;
            (
                cx - box_width / 2.0,
                cy - box_height / 2.0 + shift,
                cx + box_width / 2.0,
                cy + box_height / 2.0 + shift,
            )
        }
        lines
            .into_iter()
            .map(|line| {
                let (left, top, right, bottom) = turned(
                    line.left,
                    line.top,
                    line.right,
                    line.bottom,
                    theta,
                    sin,
                    cos,
                );
                // A page turns as one sheet: every word box on it is rotated
                // and re-bounded by the same angle its line was.
                let words = line
                    .words
                    .into_iter()
                    .map(|word| {
                        let (left, top, right, bottom) = turned(
                            word.left,
                            word.top,
                            word.right,
                            word.bottom,
                            theta,
                            sin,
                            cos,
                        );
                        OcrWordInput {
                            left,
                            top,
                            right,
                            bottom,
                            ..word
                        }
                    })
                    .collect();
                OcrLineInput {
                    left,
                    top,
                    right,
                    bottom,
                    words,
                    ..line
                }
            })
            .collect()
    }

    /// Eight single-spaced lines of body text as they would sit on a level
    /// page: 20 tall, one line every 24, and a ragged right edge — real prose
    /// does not set every line to the same width, and the tilt fit reads that
    /// raggedness.
    fn body_page() -> Vec<OcrLineInput> {
        const WIDTHS: [f32; 14] = [
            300.0, 288.0, 296.0, 271.0, 300.0, 164.0, 293.0, 282.0, 299.0, 276.0, 291.0, 210.0,
            297.0, 285.0,
        ];
        WIDTHS
            .iter()
            .enumerate()
            .map(|(index, &width)| {
                sized(
                    &format!("line number {index} of the body text"),
                    100.0 + 24.0 * index as f32,
                    100.0,
                    20.0,
                    width,
                )
            })
            .collect()
    }

    /// Ten printed lines, each reported as three boxes side by side — which is
    /// what a real recognizer hands back, and what [`body_page`] deliberately
    /// is not. Row-mates are the only thing on a page that can say which way it
    /// leans, so this is the fixture the deskew has something to work with.
    ///
    /// Where the boxes break varies from row to row, because a page that broke
    /// at the same two places on every row would be perfectly periodic — and a
    /// periodic page is genuinely ambiguous about its tilt, since shearing it by
    /// one line pitch maps it exactly onto itself. Real text does not do that,
    /// and a fixture that did would be testing an illusion.
    fn split_page() -> Vec<OcrLineInput> {
        const BREAKS: [[f32; 4]; 10] = [
            [100.0, 250.0, 390.0, 580.0],
            [100.0, 210.0, 420.0, 560.0],
            [100.0, 290.0, 400.0, 590.0],
            [100.0, 190.0, 350.0, 545.0],
            [100.0, 265.0, 445.0, 575.0],
            [100.0, 230.0, 330.0, 520.0],
            [100.0, 300.0, 430.0, 585.0],
            [100.0, 205.0, 375.0, 555.0],
            [100.0, 275.0, 410.0, 530.0],
            [100.0, 240.0, 360.0, 570.0],
        ];
        let mut lines = Vec::new();
        for (row, breaks) in BREAKS.iter().enumerate() {
            let top = 100.0 + 24.0 * row as f32;
            for part in 0..3 {
                // Leave a word-sized gap so the boxes sit apart, as reported.
                let (left, right) = (breaks[part], breaks[part + 1] - 12.0);
                lines.push(sized(
                    &format!("row {row} part {part}"),
                    top,
                    left,
                    20.0,
                    right - left,
                ));
            }
        }
        lines
    }

    fn body_rows(lines: Vec<OcrLineInput>) -> usize {
        let draft = shape_scanned_text(
            lines,
            OcrShapeOptions {
                preserve_line_breaks: true,
                detect_structure: false,
                detect_tables: false,
                preset: ScanPreset::Receipt,
                ..OcrShapeOptions::default()
            },
        );
        draft
            .body
            .lines()
            .filter(|row| !row.trim().is_empty())
            .count()
    }

    #[test]
    fn a_page_split_into_boxes_per_row_is_straightened_both_ways() {
        for degrees in [-10.0f32, -7.0, -4.0, 4.0, 7.0, 10.0] {
            let raw = photographed(split_page(), degrees);
            let tangent = fitted(&raw).expect("a ragged page fits a tilt");
            let straightened = straighten(raw);
            let height = median(straightened.iter().map(|l| l.bottom - l.top));
            let slope = estimate_skew(&tilt_boxes(&straightened), height, Some(tangent));

            // The lean is read off the boxes, so it has to come back with the
            // sign the page was actually tilted — the failure this guards is a
            // page straightened the wrong way, which drags every row onto the
            // one below it.
            let expected = degrees.to_radians().tan();
            assert!(
                (slope - expected).abs() < 0.01,
                "{degrees} degrees read as slope {slope}, expected {expected}"
            );

            // Three boxes per printed line, back to ten lines: the row-mates
            // rejoin and the rows stay apart.
            assert_eq!(
                body_rows(photographed(split_page(), degrees)),
                10,
                "rows wrong at {degrees} degrees"
            );
        }
    }

    #[test]
    fn word_boxes_straighten_the_page_whole_line_boxes_could_not() {
        // The same page as the test below, which has to give up because whole
        // line boxes cannot say which way a page leans. Every line here is
        // reported as its words, so each printed row has row-mates and the
        // direction vote has something to count — the page that was left
        // uncorrected now comes back with the sign it was photographed at.
        for degrees in [-10.0f32, -7.0, -4.0, 4.0, 7.0, 10.0] {
            let worded: Vec<OcrLineInput> = body_page().into_iter().map(with_words).collect();
            let raw = photographed(worded, degrees);
            let tangent = fitted(&raw).expect("word boxes fit a tilt");
            let straightened = straighten(raw);
            let height = median(straightened.iter().map(|l| l.bottom - l.top));
            let slope = estimate_skew(&tilt_boxes(&straightened), height, Some(tangent));

            let expected = degrees.to_radians().tan();
            assert!(
                (slope - expected).abs() < 0.02,
                "{degrees} degrees read as slope {slope}, expected {expected}"
            );
        }
    }

    #[test]
    fn word_boxes_do_not_disturb_a_page_that_was_already_read_correctly() {
        // Adding word detail must not change what a page says. The level page
        // reads the same either way, which is what makes the extra evidence
        // safe to take whenever a recognizer offers it.
        let plain_read = shape_scanned_text(body_page(), OcrShapeOptions::default());
        let worded: Vec<OcrLineInput> = body_page().into_iter().map(with_words).collect();
        let worded_read = shape_scanned_text(worded, OcrShapeOptions::default());
        assert_eq!(plain_read.body, worded_read.body);
    }

    #[test]
    fn a_line_without_a_score_borrows_the_confidence_of_its_words() {
        // ML Kit on Android routinely reports no line confidence while
        // reporting one per word. Read literally that is a page nobody has an
        // opinion about, and the capture quality says so; averaged, it is an
        // ordinary poor page that can be advised about.
        let mut line = with_words(sized("the quick brown fox", 0.0, 0.0, 20.0, 200.0));
        for word in &mut line.words {
            word.confidence = Some(0.3);
        }
        let draft = shape_scanned_text(vec![line], OcrShapeOptions::default());
        assert_eq!(draft.quality.verdict, QualityVerdict::Poor);
        assert!((draft.quality.mean_confidence - 0.3).abs() < 0.001);
        assert!(!draft.quality.advice.is_empty());
    }

    #[test]
    fn a_line_that_scores_itself_is_not_overridden_by_its_words() {
        let mut line = with_words(sized("the quick brown fox", 0.0, 0.0, 20.0, 200.0));
        line.confidence = Some(0.95);
        for word in &mut line.words {
            word.confidence = Some(0.1);
        }
        let draft = shape_scanned_text(vec![line], OcrShapeOptions::default());
        assert_eq!(draft.quality.verdict, QualityVerdict::Good);
    }

    #[test]
    fn a_page_of_whole_line_boxes_is_left_alone_rather_than_guessed_at() {
        // Nothing on a single-column page of whole-line boxes distinguishes a
        // left lean from a right one: every line starts at the same margin, so
        // the only thing moving a centre sideways is the line's own length.
        // Reporting no skew is the honest answer, and the safe one — the boxes
        // are still un-inflated, which is what kept the rows apart.
        for degrees in [-10.0f32, -4.0, 4.0, 10.0] {
            let raw = photographed(body_page(), degrees);
            let tangent = fitted(&raw);
            let straightened = straighten(raw);
            let height = median(straightened.iter().map(|l| l.bottom - l.top));
            assert_eq!(
                estimate_skew(&tilt_boxes(&straightened), height, tangent),
                0.0
            );
        }
    }

    #[test]
    fn a_photographed_page_keeps_its_lines_apart() {
        // Measured on this page with the correction disabled: level and two
        // degrees read all fourteen lines, four degrees welded them into seven,
        // and ten degrees left five. Two degrees passing is what makes the
        // failure so easy to miss — a page has to be tilted only slightly more
        // than a steady pair of hands manages before every second line is lost.
        for degrees in [0.0, 2.0, 4.0, 5.0, 7.0, 10.0] {
            assert_eq!(
                body_rows(photographed(body_page(), degrees)),
                body_page().len(),
                "lines merged at {degrees} degrees"
            );
        }
    }

    #[test]
    fn a_photographed_page_measures_its_true_line_height() {
        let straight = shape_scanned_text(body_page(), OcrShapeOptions::default());
        for degrees in [4.0, 7.0, 10.0] {
            let tilted = shape_scanned_text(
                photographed(body_page(), degrees),
                OcrShapeOptions::default(),
            );
            assert_eq!(
                tilted.body, straight.body,
                "a page photographed at {degrees} degrees read differently from the same page held level"
            );
        }
    }

    #[test]
    fn a_level_page_is_left_exactly_as_measured() {
        // Boxes that were never inflated must come back untouched rather than
        // merely close: the fit has to find no tilt, not a small one.
        let lines = body_page();
        assert_eq!(straighten(lines.clone()), lines);
    }

    #[test]
    fn a_page_of_one_width_is_left_alone_rather_than_guessed_at() {
        // Every line the same width, so the heights carry no evidence of a
        // tilt. Correcting anyway would be inventing an angle.
        let lines: Vec<OcrLineInput> = (0..8)
            .map(|index| sized("uniform", 24.0 * index as f32, 0.0, 20.0, 300.0))
            .collect();
        assert_eq!(straighten(photographed(lines.clone(), 6.0)).len(), 8);
        assert_eq!(straighten(lines.clone()), lines);
    }

    #[test]
    fn the_fitted_tilt_matches_the_angle_the_page_was_photographed_at() {
        for degrees in [2.0f32, 4.0, 7.0, 12.0] {
            let tangent = fitted(&photographed(body_page(), degrees))
                .expect("a ragged-right page can be fitted");
            assert!(
                (tangent - degrees.to_radians().sin()).abs() < 0.01,
                "fitted {tangent} for a page photographed at {degrees} degrees"
            );
        }
    }

    /// Tilt a whole page about the origin, the way a hand-held photo does.
    fn tilt(lines: Vec<OcrLineInput>, slope: f32) -> Vec<OcrLineInput> {
        lines
            .into_iter()
            .map(|line| {
                let shift = slope * input_centre_x(&line);
                OcrLineInput {
                    top: line.top + shift,
                    bottom: line.bottom + shift,
                    ..line
                }
            })
            .collect()
    }

    /// Two columns of body text under a full-width headline.
    fn two_column_page() -> Vec<OcrLineInput> {
        let mut lines = vec![sized("Banner headline", 0.0, 0.0, 30.0, 500.0)];
        for index in 0..6 {
            let top = 60.0 + index as f32 * 24.0;
            lines.push(sized(&format!("left {index}"), top, 0.0, 20.0, 200.0));
            lines.push(sized(&format!("right {index}"), top, 300.0, 20.0, 200.0));
        }
        lines
    }

    #[test]
    fn reads_top_to_bottom_regardless_of_recognizer_order() {
        let draft = plain(vec![
            line("third", 100.0, 0.0),
            line("first", 0.0, 0.0),
            line("second", 50.0, 0.0),
        ]);
        assert_eq!(draft.body, "first second third");
        assert_eq!(draft.kept_lines, 3);
        assert_eq!(draft.columns, 1);
        assert_eq!(draft.pages, 1);
    }

    #[test]
    fn merges_boxes_that_share_a_visual_row() {
        let draft = plain(vec![
            line("right half", 2.0, 300.0),
            line("left half", 0.0, 0.0),
        ]);
        assert_eq!(draft.body, "left half right half");
        // Two boxes are nowhere near enough to call a page columnar.
        assert_eq!(draft.columns, 1);
    }

    #[test]
    fn a_wide_vertical_gap_starts_a_new_paragraph() {
        let draft = plain(vec![
            line("opening line", 0.0, 0.0),
            line("still the same idea", 24.0, 0.0),
            line("a separate thought", 120.0, 0.0),
        ]);
        assert_eq!(
            draft.body,
            "opening line still the same idea\n\na separate thought"
        );
    }

    #[test]
    fn heals_words_split_across_a_line_break() {
        let draft = plain(vec![
            line("the recogni-", 0.0, 0.0),
            line("tion engine", 24.0, 0.0),
        ]);
        assert_eq!(draft.body, "the recognition engine");
    }

    #[test]
    fn keeps_a_hyphen_that_is_not_a_word_break() {
        let compound = plain(vec![
            line("state-of-the-art", 0.0, 0.0),
            line("Systems", 24.0, 0.0),
        ]);
        assert_eq!(compound.body, "state-of-the-art Systems");

        let dash = plain(vec![
            line("interrupted-", 0.0, 0.0),
            line("Then", 24.0, 0.0),
        ]);
        assert_eq!(dash.body, "interrupted- Then");
    }

    #[test]
    fn preserve_line_breaks_keeps_receipt_style_layout() {
        let draft = shape_scanned_text(
            vec![
                line("Coffee    3.50", 0.0, 0.0),
                line("Pastry    2.25", 24.0, 0.0),
            ],
            OcrShapeOptions {
                preserve_line_breaks: true,
                detect_structure: false,
                detect_tables: false,
                preset: ScanPreset::Prose,
                ..OcrShapeOptions::default()
            },
        );
        assert_eq!(draft.body, "Coffee 3.50\nPastry 2.25");
    }

    #[test]
    fn drops_low_confidence_lines_but_keeps_unscored_ones() {
        let mut noisy = line("garbled", 24.0, 0.0);
        noisy.confidence = Some(0.1);
        let mut good = line("certain", 0.0, 0.0);
        good.confidence = Some(0.9);

        let draft = shape_scanned_text(
            vec![good, noisy, line("unscored", 48.0, 0.0)],
            OcrShapeOptions {
                min_confidence: 0.5,
                detect_structure: false,
                detect_tables: false,
                preset: ScanPreset::Prose,
                ..OcrShapeOptions::default()
            },
        );
        assert_eq!(draft.body, "certain unscored");
        assert_eq!(draft.kept_lines, 2);
        assert_eq!(draft.dropped_lines, 1);
    }

    #[test]
    fn discards_specks_far_smaller_than_the_body_text() {
        let mut speck = line(".", 60.0, 0.0);
        speck.bottom = speck.top + 2.0;
        let draft = plain(vec![
            line("real text here", 0.0, 0.0),
            line("more real text", 24.0, 0.0),
            speck,
        ]);
        assert!(!draft.body.contains('.'));
        assert_eq!(draft.dropped_lines, 1);
    }

    #[test]
    fn promotes_a_taller_headline_to_the_title() {
        let draft = plain(vec![
            sized("Quarterly Report", 0.0, 0.0, 44.0, 200.0),
            line("revenue grew steadily", 60.0, 0.0),
            line("across every region", 84.0, 0.0),
        ]);
        assert_eq!(draft.title, "Quarterly Report");
    }

    #[test]
    fn plain_prose_falls_back_to_its_opening_row() {
        let draft = plain(vec![
            line("no heading on this page", 0.0, 0.0),
            line("just body copy", 24.0, 0.0),
        ]);
        assert_eq!(draft.title, "no heading on this page");
    }

    #[test]
    fn a_long_title_is_cut_at_a_word_edge() {
        let long = "Minutes of the extraordinary general meeting held on the \
                    fourteenth of March in the upstairs room";
        let draft = plain(vec![line(long, 0.0, 0.0)]);
        assert!(draft.title.ends_with('…'));
        assert!(draft.title.encode_utf16().count() <= MAX_TITLE_UNITS + 1);
        assert!(long.starts_with(draft.title.trim_end_matches('…')));
    }

    #[test]
    fn an_empty_page_yields_an_empty_draft_rather_than_an_error() {
        let draft = shape(vec![]);
        assert_eq!(draft.title, "");
        assert_eq!(draft.body, "");
        assert_eq!(draft.kept_lines, 0);
        assert_eq!(draft.content_type, "plain");

        let blank = shape(vec![line("   ", 0.0, 0.0)]);
        assert_eq!(blank.body, "");
        assert_eq!(blank.dropped_lines, 1);
    }

    #[test]
    fn collapses_the_wide_letter_spacing_ocr_likes_to_emit() {
        let draft = plain(vec![line("  S P  A   C E D  ", 0.0, 0.0)]);
        assert_eq!(draft.body, "S P A C E D");
    }

    // --- Columns ---

    #[test]
    fn reads_two_columns_down_each_side_not_across() {
        let draft = plain(two_column_page());
        assert_eq!(draft.columns, 2);
        assert_eq!(
            draft.body,
            "Banner headline\n\n\
             left 0 left 1 left 2 left 3 left 4 left 5\n\n\
             right 0 right 1 right 2 right 3 right 4 right 5"
        );
    }

    #[test]
    fn a_banner_headline_is_read_before_the_columns_beneath_it() {
        let draft = plain(two_column_page());
        assert_eq!(draft.title, "Banner headline");
        assert!(draft.body.starts_with("Banner headline"));
    }

    #[test]
    fn column_detection_can_be_turned_off_for_forms_and_receipts() {
        let draft = shape_scanned_text(
            two_column_page(),
            OcrShapeOptions {
                detect_columns: false,
                detect_structure: false,
                detect_tables: false,
                preset: ScanPreset::Prose,
                ..OcrShapeOptions::default()
            },
        );
        assert_eq!(draft.columns, 1);
        // Straight across the page, pairing each left line with its right.
        assert!(draft.body.contains("left 0 right 0"));
    }

    #[test]
    fn ordinary_prose_is_never_mistaken_for_columns() {
        let mut lines = Vec::new();
        for index in 0..8 {
            lines.push(line(
                &format!("body line {index}"),
                index as f32 * 24.0,
                0.0,
            ));
        }
        assert_eq!(plain(lines).columns, 1);
    }

    #[test]
    fn a_short_indented_block_does_not_become_a_column() {
        // Two stacked blocks side by side but only two lines each: a gap, not
        // a column layout.
        let draft = plain(vec![
            sized("alpha", 0.0, 0.0, 20.0, 150.0),
            sized("beta", 24.0, 0.0, 20.0, 150.0),
            sized("gamma", 0.0, 400.0, 20.0, 150.0),
            sized("delta", 24.0, 400.0, 20.0, 150.0),
        ]);
        assert_eq!(draft.columns, 1);
    }

    // --- Skew ---

    #[test]
    fn a_tilted_page_still_groups_its_rows_correctly() {
        // Same page as the row-merge case, photographed at a slant. Without
        // deskewing, the right-hand box drifts a whole line height down and
        // would be read as a separate row.
        let straight = vec![
            sized("left half", 0.0, 0.0, 20.0, 200.0),
            sized("right half", 0.0, 300.0, 20.0, 200.0),
            sized("second line left", 30.0, 0.0, 20.0, 200.0),
            sized("second line right", 30.0, 300.0, 20.0, 200.0),
        ];
        let draft = plain(tilt(straight, 0.08));
        assert_eq!(
            draft.body,
            "left half right half second line left second line right"
        );
        assert!(draft.corrected_skew_degrees > 3.0);
    }

    #[test]
    fn a_steeply_tilted_page_is_still_read_in_order() {
        // Single-column prose whose lines the recognizer split in two. The gap
        // is narrower than a gutter, so this stays one column however far the
        // page tips — unlike two_column_page, which really is two columns.
        let straight: Vec<OcrLineInput> = (0..5)
            .flat_map(|index| {
                let top = index as f32 * 30.0;
                vec![
                    sized(&format!("row {index} left"), top, 0.0, 20.0, 240.0),
                    sized(&format!("row {index} right"), top, 250.0, 20.0, 250.0),
                ]
            })
            .collect();
        let draft = plain(tilt(straight, 0.15));
        assert_eq!(draft.columns, 1);
        for index in 0..5 {
            assert!(
                draft
                    .body
                    .contains(&format!("row {index} left row {index} right")),
                "row {index} should stay intact, got: {}",
                draft.body
            );
        }
    }

    #[test]
    fn a_straight_page_reports_no_skew_and_is_left_alone() {
        let draft = plain(vec![
            sized("left half", 0.0, 0.0, 20.0, 200.0),
            sized("right half", 0.0, 300.0, 20.0, 200.0),
        ]);
        assert_eq!(draft.corrected_skew_degrees, 0.0);
        assert_eq!(draft.body, "left half right half");
    }

    #[test]
    fn a_short_page_is_not_tilted_to_fit_a_coincidence() {
        // Three lines, the last one shorter than the two above it. There is a
        // steep angle that stacks two of them into the same bin by accident,
        // and believing it would merge two printed lines into one row.
        let draft = plain(vec![
            sized("first line of the note", 0.0, 0.0, 20.0, 300.0),
            sized("second line of the note", 24.0, 20.0, 20.0, 260.0),
            sized("third line", 48.0, 0.0, 20.0, 200.0),
        ]);
        assert_eq!(draft.corrected_skew_degrees, 0.0);
        assert_eq!(
            draft.body,
            "first line of the note second line of the note third line"
        );
    }

    #[test]
    fn an_implausible_tilt_is_clamped_rather_than_trusted() {
        let straight = vec![
            sized("a", 0.0, 0.0, 20.0, 100.0),
            sized("b", 0.0, 300.0, 20.0, 100.0),
        ];
        let draft = plain(tilt(straight, 5.0));
        assert!(draft.corrected_skew_degrees.abs() <= 20.1);
    }

    // --- Multi-page ---

    #[test]
    fn pages_are_reconstructed_separately_then_read_as_one_document() {
        let draft = shape_scanned_pages(
            vec![
                page(vec![line("page one text", 0.0, 0.0)]),
                page(vec![line("page two text", 0.0, 0.0)]),
            ],
            OcrShapeOptions {
                detect_structure: false,
                preset: ScanPreset::Prose,
                ..OcrShapeOptions::default()
            },
        );
        assert_eq!(draft.pages, 2);
        assert!(draft.body.contains("page one text"));
        assert!(draft.body.contains("page two text"));
    }

    #[test]
    fn each_page_gets_its_own_skew_correction() {
        // One page level, the next badly tilted. A single global estimate
        // would either under-correct the second or wreck the first.
        //
        // Each row is split into two boxes: skew is only visible as a
        // *difference* in drop across the page, so a stack of boxes that all
        // share a centre would tilt into a plain translation and show nothing.
        let split = |label: &str| -> Vec<OcrLineInput> {
            (0..5)
                .flat_map(|index| {
                    let top = index as f32 * 30.0;
                    vec![
                        sized(&format!("{label} {index}"), top, 0.0, 20.0, 240.0),
                        sized(&format!("end {index}"), top, 250.0, 20.0, 200.0),
                    ]
                })
                .collect()
        };
        let level = split("level");
        let tipped: Vec<OcrLineInput> = tilt(split("tipped"), 0.12);
        let draft = shape_scanned_pages(
            vec![page(level), page(tipped)],
            OcrShapeOptions {
                detect_structure: false,
                preset: ScanPreset::Prose,
                ..OcrShapeOptions::default()
            },
        );
        for index in 0..5 {
            assert!(draft.body.contains(&format!("level {index}")));
            assert!(draft.body.contains(&format!("tipped {index}")));
        }
        // The worst page's tilt is what gets reported.
        assert!(draft.corrected_skew_degrees > 3.0);
    }

    #[test]
    fn a_running_head_repeated_on_every_page_is_dropped() {
        let pages: Vec<OcrPageInput> = (1..=4)
            .map(|number| {
                page(vec![
                    line("The Wind in the Willows", 0.0, 0.0),
                    line(&format!("body of page {number}"), 60.0, 0.0),
                    line(&format!("{number}"), 400.0, 0.0),
                ])
            })
            .collect();
        let draft = shape_scanned_pages(
            pages,
            OcrShapeOptions {
                detect_structure: false,
                preset: ScanPreset::BookPage,
                ..OcrShapeOptions::default()
            },
        );
        assert!(!draft.body.contains("Willows"), "got: {}", draft.body);
        assert!(draft.body.contains("body of page 1"));
        assert!(draft.body.contains("body of page 4"));
        assert!(draft.stripped_running_heads >= 4);
    }

    #[test]
    fn every_recognized_line_is_accounted_for_as_kept_or_dropped() {
        // Running heads are found only after the geometry pass has already
        // counted them as kept, so they have to be moved across rather than
        // added on — otherwise the two counters sum to more than was scanned.
        let pages: Vec<OcrPageInput> = (1..=4)
            .map(|number| {
                page(vec![
                    line("The Wind in the Willows", 0.0, 0.0),
                    line(&format!("body of page {number}"), 60.0, 0.0),
                    line(&format!("{number}"), 400.0, 0.0),
                ])
            })
            .collect();
        let total: usize = pages.iter().map(|page| page.lines.len()).sum();
        let draft = shape_scanned_pages(
            pages,
            OcrShapeOptions {
                detect_structure: false,
                preset: ScanPreset::BookPage,
                ..OcrShapeOptions::default()
            },
        );
        assert_eq!(draft.kept_lines + draft.dropped_lines, total as i32);
        assert!(draft.kept_lines > 0);
        assert!(draft.stripped_running_heads > 0);
    }

    #[test]
    fn a_heading_that_happens_to_repeat_twice_is_not_furniture() {
        // Same text on two of four pages: a coincidence, not a running head.
        let mut pages = Vec::new();
        for number in 1..=4 {
            let head = if number <= 2 { "Shared start" } else { "Other" };
            pages.push(page(vec![
                line(head, 0.0, 0.0),
                line(&format!("body {number}"), 60.0, 0.0),
            ]));
        }
        let draft = shape_scanned_pages(
            pages,
            OcrShapeOptions {
                detect_structure: false,
                preset: ScanPreset::BookPage,
                ..OcrShapeOptions::default()
            },
        );
        assert!(draft.body.contains("Shared start"));
    }

    #[test]
    fn running_head_stripping_needs_several_pages_to_mean_anything() {
        let pages: Vec<OcrPageInput> = (1..=2)
            .map(|number| {
                page(vec![
                    line("Repeated", 0.0, 0.0),
                    line(&format!("body {number}"), 60.0, 0.0),
                ])
            })
            .collect();
        let draft = shape_scanned_pages(
            pages,
            OcrShapeOptions {
                detect_structure: false,
                preset: ScanPreset::Prose,
                ..OcrShapeOptions::default()
            },
        );
        assert!(draft.body.contains("Repeated"));
        assert_eq!(draft.stripped_running_heads, 0);
    }

    // --- Capture quality ---

    #[test]
    fn a_page_the_recognizer_struggled_with_is_reported_as_poor() {
        let mut lines = Vec::new();
        for index in 0..10 {
            let mut row = line(&format!("row {index}"), index as f32 * 24.0, 0.0);
            row.confidence = Some(if index < 5 { 0.2 } else { 0.95 });
            lines.push(row);
        }
        let draft = shape(lines);
        assert_eq!(draft.quality.verdict, QualityVerdict::Poor);
        assert!(!draft.quality.advice.is_empty());
        assert_eq!(draft.quality.scored_lines, 10);
    }

    #[test]
    fn a_clean_page_is_reported_as_good_with_nothing_to_say() {
        let lines: Vec<OcrLineInput> = (0..6)
            .map(|index| {
                let mut row = line(&format!("row {index}"), index as f32 * 24.0, 0.0);
                row.confidence = Some(0.97);
                row
            })
            .collect();
        let draft = shape(lines);
        assert_eq!(draft.quality.verdict, QualityVerdict::Good);
        assert!(draft.quality.advice.is_empty());
    }

    #[test]
    fn a_recognizer_that_reports_no_confidence_is_unknown_not_good() {
        let draft = plain(vec![line("no scores here", 0.0, 0.0)]);
        assert_eq!(draft.quality.verdict, QualityVerdict::Unknown);
        assert_eq!(draft.quality.scored_lines, 0);
    }

    // --- Presets ---

    #[test]
    fn a_narrow_digit_heavy_page_is_read_as_a_receipt() {
        let lines = vec![
            line("GROCER 24", 0.0, 0.0),
            line("Milk 2.40", 30.0, 0.0),
            line("Bread 1.85", 60.0, 0.0),
            line("Eggs 3.20", 90.0, 0.0),
            line("TOTAL 7.45", 120.0, 0.0),
        ];
        let draft = shape_scanned_pages(
            vec![OcrPageInput {
                lines,
                width: 400.0,
                height: 1200.0,
            }],
            OcrShapeOptions::default(),
        );
        assert_eq!(draft.preset, "receipt");
        // Receipts keep their line structure rather than reflowing.
        assert!(draft.body.contains("Milk 2.40\n"));
    }

    #[test]
    fn an_explicit_preset_overrides_the_classifier() {
        let lines = vec![
            line("GROCER 24", 0.0, 0.0),
            line("Milk 2.40", 30.0, 0.0),
            line("Bread 1.85", 60.0, 0.0),
        ];
        let draft = shape_scanned_pages(
            vec![OcrPageInput {
                lines,
                width: 400.0,
                height: 1200.0,
            }],
            OcrShapeOptions {
                preset: ScanPreset::Prose,
                detect_structure: false,
                ..OcrShapeOptions::default()
            },
        );
        assert_eq!(draft.preset, "prose");
        assert!(!draft.body.contains('\n'));
    }

    #[test]
    fn a_label_value_page_is_read_as_a_form() {
        let lines = vec![
            line("Name: Ada Lovelace", 0.0, 0.0),
            line("Role: Analyst", 30.0, 0.0),
            line("Team: Engines", 60.0, 0.0),
            line("Site: London", 90.0, 0.0),
        ];
        let draft = shape_scanned_pages(vec![page(lines)], OcrShapeOptions::default());
        assert_eq!(draft.preset, "form");
    }

    #[test]
    fn ordinary_prose_classifies_as_prose() {
        let lines: Vec<OcrLineInput> = (0..6)
            .map(|index| {
                sized(
                    "the quick brown fox jumped over the lazy dog again",
                    index as f32 * 24.0,
                    0.0,
                    20.0,
                    900.0,
                )
            })
            .collect();
        let draft = shape_scanned_pages(vec![page(lines)], OcrShapeOptions::default());
        assert_eq!(draft.preset, "prose");
    }
}
