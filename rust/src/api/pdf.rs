//! Reading a PDF through the same pipeline as a photograph.
//!
//! A PDF page arrives one of two ways. A born-digital one already carries its
//! text, positioned exactly, and recognizing it from pixels would only
//! introduce mistakes into something already perfect. A scanned one is a
//! photograph in a wrapper and has no text at all. Most real documents are a
//! mixture — a report with a scanned appendix, a contract with a photographed
//! signature page — so the decision belongs per page, not per file.
//!
//! Either way what comes out is *text plus a box*, which is exactly what
//! [`crate::api::ocr`] consumes. So a PDF does not get its own reconstruction:
//! it is converted into the same page input a camera produces and then
//! deskewed, column-split, tabulated and reflowed by the identical code. A
//! table in a digital PDF is found by the same routine that finds one in a
//! photograph.
//!
//! Two things have to be fixed up on the way in.
//!
//! PDF user space puts the origin at the bottom-left with y growing *up*,
//! while every image coordinate in this crate grows *down*. Handing raw PDF
//! coordinates to the reconstruction would read every page from the bottom up.
//!
//! And extractors disagree about what a "run" is: some emit a line, some a
//! word, some a single glyph whenever the font changes mid-word. Left alone,
//! per-glyph runs would make every character its own table cell. Runs that sit
//! on the same baseline with no more than a space between them are therefore
//! joined first, which leaves the genuinely wide gaps — the ones that mean a
//! column — standing.

use flutter_rust_bridge::frb;

use crate::api::ocr::{OcrLineInput, OcrPageInput};

/// Gap between two runs on the same baseline, as a share of their height,
/// below which they are the same word or separated by a single space rather
/// than by a layout gap.
const SPACE_GAP_RATIO: f32 = 0.6;

/// Gap below which no space is inserted when joining, because the runs were
/// only split by a font change part-way through a word.
const TOUCHING_GAP_RATIO: f32 = 0.08;

/// Vertical slack, as a share of run height, within which two runs count as
/// sharing a baseline.
const BASELINE_RATIO: f32 = 0.5;

/// A page carrying less embedded text than this has to be recognized, however
/// much the extractor managed to scrape off it.
const MIN_TEXT_CHARS: usize = 24;

/// Share of the page area covered by text boxes below which a page holding an
/// image is treated as a scan with a caption rather than as a text page.
const MIN_TEXT_COVERAGE: f32 = 0.02;

/// One positioned piece of text lifted out of a PDF's content stream.
#[derive(Clone, Debug, PartialEq)]
pub struct PdfTextRun {
    pub text: String,
    /// Left edge in PDF user space, points from the bottom-left of the page.
    pub x: f32,
    /// **Bottom** edge in PDF user space — y grows upward in a PDF, which is
    /// the opposite of every other coordinate in this crate.
    pub y: f32,
    pub width: f32,
    pub height: f32,
}

/// One page of a PDF, as the platform managed to read it.
#[derive(Clone, Debug, PartialEq)]
pub struct PdfPageInput {
    pub runs: Vec<PdfTextRun>,
    /// Page size in points.
    pub width: f32,
    pub height: f32,
    /// Whether the page draws an image over most of itself, which is what a
    /// scanned page looks like from the outside.
    pub has_image: bool,
}

/// What to do with a page.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PdfPagePlan {
    /// The embedded text is good; recognizing it from pixels would only add
    /// mistakes.
    UseText,
    /// There is no usable text. Render the page and recognize it.
    NeedsOcr,
}

/// The decision and why it was taken, so a caller can explain itself.
#[derive(Clone, Debug, PartialEq)]
pub struct PdfPageAssessment {
    pub plan: PdfPagePlan,
    pub reason: String,
    /// Share of the page area covered by text boxes.
    pub coverage: f32,
    pub characters: i32,
    pub runs: i32,
}

/// Decide whether a page can be read as it stands or has to be recognized.
#[frb(sync)]
pub fn assess_pdf_page(page: PdfPageInput) -> PdfPageAssessment {
    let characters: usize = page
        .runs
        .iter()
        .map(|run| run.text.chars().filter(|c| !c.is_whitespace()).count())
        .sum();
    let area = (page.width * page.height).max(1.0);
    let coverage = page
        .runs
        .iter()
        .map(|run| (run.width * run.height).max(0.0))
        .sum::<f32>()
        / area;

    let (plan, reason) = if page.runs.is_empty() {
        (PdfPagePlan::NeedsOcr, "the page carries no text")
    } else if characters < MIN_TEXT_CHARS {
        (
            PdfPagePlan::NeedsOcr,
            "the page carries too little text to be a text page",
        )
    } else if page.has_image && coverage < MIN_TEXT_COVERAGE {
        (
            PdfPagePlan::NeedsOcr,
            "the page is mostly an image with a caption",
        )
    } else {
        (PdfPagePlan::UseText, "the page carries its own text")
    };

    PdfPageAssessment {
        plan,
        reason: reason.to_owned(),
        coverage,
        characters: i32::try_from(characters).unwrap_or(i32::MAX),
        runs: i32::try_from(page.runs.len()).unwrap_or(i32::MAX),
    }
}

/// Turn a PDF page's text runs into reconstruction input.
///
/// `scale` converts points to the pixels of a rendered image of the same page,
/// so the boxes line up with what the user sees; pass 1.0 to stay in points.
#[frb(sync)]
pub fn pdf_page_to_ocr_page(page: PdfPageInput, scale: f32) -> OcrPageInput {
    let scale = if scale > 0.0 { scale } else { 1.0 };
    let page_height = page.height;
    let mut lines: Vec<OcrLineInput> = merge_runs(page.runs)
        .into_iter()
        .map(|run| {
            // Flip: a run's PDF bottom edge is its distance up from the foot
            // of the page, so its top edge measured down from the head is the
            // page height less the run's top.
            let top = page_height - (run.y + run.height);
            OcrLineInput {
                text: run.text,
                left: run.x * scale,
                top: top * scale,
                right: (run.x + run.width) * scale,
                bottom: (top + run.height) * scale,
                block_index: 0,
                // A PDF's own text is exact; there is nothing to doubt.
                confidence: None,
            }
        })
        .collect();
    lines.sort_by(|a, b| {
        a.top
            .total_cmp(&b.top)
            .then_with(|| a.left.total_cmp(&b.left))
    });

    OcrPageInput {
        lines,
        width: page.width * scale,
        height: page.height * scale,
    }
}

/// Convert a whole document at once.
#[frb(sync)]
pub fn pdf_pages_to_ocr_pages(pages: Vec<PdfPageInput>, scale: f32) -> Vec<OcrPageInput> {
    pages
        .into_iter()
        .map(|page| pdf_page_to_ocr_page(page, scale))
        .collect()
}

/// Join runs that sit on one baseline with no more than a space between them.
///
/// This is what keeps a per-glyph extractor from turning every character into
/// its own table cell, while leaving the wide gaps — which are the only
/// evidence of a column or a table — untouched.
fn merge_runs(runs: Vec<PdfTextRun>) -> Vec<PdfTextRun> {
    let mut runs: Vec<PdfTextRun> = runs
        .into_iter()
        .filter(|run| !run.text.trim().is_empty() && run.width > 0.0 && run.height > 0.0)
        .collect();
    if runs.is_empty() {
        return runs;
    }
    // Down the page, then across it. PDF y grows upward, so the larger y comes
    // first.
    runs.sort_by(|a, b| b.y.total_cmp(&a.y).then_with(|| a.x.total_cmp(&b.x)));

    let mut merged: Vec<PdfTextRun> = Vec::with_capacity(runs.len());
    for run in runs {
        let joined = merged.last_mut().and_then(|last| {
            let slack = last.height.max(run.height) * BASELINE_RATIO;
            let same_line = (last.y - run.y).abs() <= slack;
            let gap = run.x - (last.x + last.width);
            (same_line && gap <= last.height.max(run.height) * SPACE_GAP_RATIO && gap >= -slack)
                .then_some((last, gap))
        });
        match joined {
            Some((last, gap)) => {
                if gap > last.height.max(run.height) * TOUCHING_GAP_RATIO {
                    last.text.push(' ');
                }
                last.text.push_str(&run.text);
                // The joined run spans both boxes.
                let bottom = last.y.min(run.y);
                let top = (last.y + last.height).max(run.y + run.height);
                last.width = (run.x + run.width - last.x).max(last.width);
                last.y = bottom;
                last.height = top - bottom;
            }
            None => merged.push(run),
        }
    }
    merged
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::ocr::{shape_scanned_pages, OcrShapeOptions, ScanPreset};

    fn run(text: &str, x: f32, y: f32, width: f32, height: f32) -> PdfTextRun {
        PdfTextRun {
            text: text.to_owned(),
            x,
            y,
            width,
            height,
        }
    }

    /// A US Letter page in points.
    fn page(runs: Vec<PdfTextRun>, has_image: bool) -> PdfPageInput {
        PdfPageInput {
            runs,
            width: 612.0,
            height: 792.0,
            has_image,
        }
    }

    // --- Assessment ---

    #[test]
    fn a_page_with_no_text_has_to_be_recognized() {
        let assessment = assess_pdf_page(page(Vec::new(), true));
        assert_eq!(assessment.plan, PdfPagePlan::NeedsOcr);
        assert_eq!(assessment.characters, 0);
        assert!(!assessment.reason.is_empty());
    }

    #[test]
    fn a_born_digital_page_is_read_as_it_stands() {
        let runs: Vec<PdfTextRun> = (0..30)
            .map(|index| {
                run(
                    "the quick brown fox jumps over the lazy dog",
                    72.0,
                    700.0 - index as f32 * 14.0,
                    460.0,
                    12.0,
                )
            })
            .collect();
        let assessment = assess_pdf_page(page(runs, false));
        assert_eq!(assessment.plan, PdfPagePlan::UseText);
        assert!(assessment.coverage > 0.02);
    }

    #[test]
    fn a_scan_with_a_caption_is_still_recognized() {
        // A big image and one line of text underneath it.
        let assessment = assess_pdf_page(page(
            vec![run(
                "Figure 1: the north elevation",
                72.0,
                90.0,
                200.0,
                10.0,
            )],
            true,
        ));
        assert_eq!(assessment.plan, PdfPagePlan::NeedsOcr);
        assert!(assessment.reason.contains("image"));
    }

    #[test]
    fn a_scrap_of_text_is_not_enough_to_call_a_page_digital() {
        let assessment = assess_pdf_page(page(vec![run("iv", 300.0, 60.0, 8.0, 10.0)], false));
        assert_eq!(assessment.plan, PdfPagePlan::NeedsOcr);
    }

    // --- Coordinates ---

    #[test]
    fn the_page_is_flipped_so_the_top_of_the_page_is_read_first() {
        let converted = pdf_page_to_ocr_page(
            page(
                vec![
                    // Near the foot of the page in PDF space.
                    run("footer", 72.0, 60.0, 100.0, 10.0),
                    // Near the head.
                    run("header", 72.0, 720.0, 100.0, 10.0),
                ],
                false,
            ),
            1.0,
        );
        assert_eq!(converted.lines[0].text, "header");
        assert_eq!(converted.lines[1].text, "footer");
        // The header sits 792 - (720 + 10) = 62 points down from the top.
        assert!((converted.lines[0].top - 62.0).abs() < 0.01);
        assert!((converted.lines[1].top - 722.0).abs() < 0.01);
    }

    #[test]
    fn scaling_maps_points_onto_the_pixels_of_a_rendered_page() {
        let converted = pdf_page_to_ocr_page(
            page(vec![run("text", 72.0, 720.0, 100.0, 10.0)], false),
            2.0,
        );
        assert!((converted.lines[0].left - 144.0).abs() < 0.01);
        assert!((converted.lines[0].top - 124.0).abs() < 0.01);
        assert!((converted.width - 1224.0).abs() < 0.01);
    }

    #[test]
    fn a_nonsense_scale_falls_back_to_points_rather_than_collapsing_the_page() {
        let converted = pdf_page_to_ocr_page(
            page(vec![run("text", 72.0, 720.0, 100.0, 10.0)], false),
            0.0,
        );
        assert!((converted.lines[0].left - 72.0).abs() < 0.01);
    }

    // --- Run merging ---

    #[test]
    fn glyph_runs_split_by_a_font_change_rejoin_into_one_word() {
        // "Hello" where the extractor broke after "Hel" for a style change.
        let converted = pdf_page_to_ocr_page(
            page(
                vec![
                    run("Hel", 72.0, 700.0, 18.0, 10.0),
                    run("lo", 90.0, 700.0, 12.0, 10.0),
                ],
                false,
            ),
            1.0,
        );
        assert_eq!(converted.lines.len(), 1);
        assert_eq!(converted.lines[0].text, "Hello");
    }

    #[test]
    fn word_runs_on_one_baseline_rejoin_with_their_spaces() {
        let converted = pdf_page_to_ocr_page(
            page(
                vec![
                    run("the", 72.0, 700.0, 18.0, 10.0),
                    run("quick", 94.0, 700.0, 30.0, 10.0),
                    run("fox", 128.0, 700.0, 20.0, 10.0),
                ],
                false,
            ),
            1.0,
        );
        assert_eq!(converted.lines.len(), 1);
        assert_eq!(converted.lines[0].text, "the quick fox");
    }

    #[test]
    fn a_wide_gap_is_left_alone_because_it_is_the_only_sign_of_a_column() {
        let converted = pdf_page_to_ocr_page(
            page(
                vec![
                    run("Widget", 72.0, 700.0, 40.0, 10.0),
                    run("4.00", 400.0, 700.0, 24.0, 10.0),
                ],
                false,
            ),
            1.0,
        );
        assert_eq!(converted.lines.len(), 2);
    }

    #[test]
    fn runs_on_different_lines_never_join() {
        let converted = pdf_page_to_ocr_page(
            page(
                vec![
                    run("first", 72.0, 700.0, 30.0, 10.0),
                    run("second", 72.0, 686.0, 36.0, 10.0),
                ],
                false,
            ),
            1.0,
        );
        assert_eq!(converted.lines.len(), 2);
        assert_eq!(converted.lines[0].text, "first");
    }

    #[test]
    fn empty_and_degenerate_runs_are_dropped() {
        let converted = pdf_page_to_ocr_page(
            page(
                vec![
                    run("   ", 72.0, 700.0, 10.0, 10.0),
                    run("real", 72.0, 686.0, 30.0, 10.0),
                    run("zero", 72.0, 660.0, 0.0, 10.0),
                ],
                false,
            ),
            1.0,
        );
        assert_eq!(converted.lines.len(), 1);
        assert_eq!(converted.lines[0].text, "real");
    }

    // --- Through the whole pipeline ---

    #[test]
    fn a_digital_pdf_reconstructs_through_the_camera_pipeline() {
        let runs = vec![
            run("The Annual Report", 72.0, 720.0, 160.0, 18.0),
            run("Revenue grew steadily across", 72.0, 690.0, 300.0, 11.0),
            run("every region this year.", 72.0, 676.0, 300.0, 11.0),
        ];
        let converted = pdf_page_to_ocr_page(page(runs, false), 1.0);
        let draft = shape_scanned_pages(
            vec![converted],
            OcrShapeOptions {
                preset: ScanPreset::Prose,
                ..OcrShapeOptions::default()
            },
        );
        assert_eq!(draft.title, "The Annual Report");
        assert!(
            draft
                .body
                .contains("Revenue grew steadily across every region this year."),
            "got: {}",
            draft.body
        );
    }

    #[test]
    fn a_table_in_a_digital_pdf_is_drawn_as_a_table() {
        // The same routine that finds a table in a photograph finds this one.
        let rows = [
            ("Item", "Qty", "Price"),
            ("Widget", "2", "4.00"),
            ("Gasket", "13", "11.50"),
            ("Flange", "1", "99.99"),
        ];
        let mut runs = Vec::new();
        for (index, (name, quantity, price)) in rows.iter().enumerate() {
            let y = 700.0 - index as f32 * 16.0;
            runs.push(run(name, 72.0, y, 44.0, 11.0));
            runs.push(run(quantity, 260.0, y, 16.0, 11.0));
            runs.push(run(price, 380.0, y, 30.0, 11.0));
        }
        let converted = pdf_page_to_ocr_page(page(runs, false), 1.0);
        let draft = shape_scanned_pages(
            vec![converted],
            OcrShapeOptions {
                preset: ScanPreset::Prose,
                ..OcrShapeOptions::default()
            },
        );
        assert_eq!(draft.tables, 1, "got: {}", draft.body);
        assert!(
            draft.body.contains("| Item | Qty | Price |"),
            "got: {}",
            draft.body
        );
        assert!(draft.body.contains("| Flange | 1 | 99.99 |"));
    }

    #[test]
    fn a_whole_document_converts_at_once() {
        let pages = pdf_pages_to_ocr_pages(
            vec![
                page(vec![run("one", 72.0, 700.0, 20.0, 10.0)], false),
                page(vec![run("two", 72.0, 700.0, 20.0, 10.0)], false),
            ],
            1.0,
        );
        assert_eq!(pages.len(), 2);
        assert_eq!(pages[1].lines[0].text, "two");
    }
}
