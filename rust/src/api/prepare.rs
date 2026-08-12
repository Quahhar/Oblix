//! Giving the recognizer a better photograph to read.
//!
//! Everything else in the scanning surface works on boxes the recognizer has
//! already produced. This module works on the step before that: what the model
//! is shown in the first place.
//!
//! It matters more than the reconstruction does. A recognizer is a fixed model
//! — nothing here can make it cleverer — so the only lever on *character*
//! accuracy is the image. Three things about a phone photograph cost real
//! accuracy, and all three are cheap to undo:
//!
//! - **Tilt.** [`crate::api::ocr`] straightens the *boxes*, which fixes reading
//!   order and row banding. It cannot fix the glyphs: those were already read
//!   off a slanted image, and an on-device model's word accuracy falls away
//!   past a few degrees. The tilt has to come out of the pixels, before the
//!   model looks at them.
//! - **Small print.** A model needs a certain number of pixels per character.
//!   Text photographed from far away, or a page scanned at a low resolution,
//!   is not made more legible by any amount of reconstruction.
//! - **Dim or flat lighting.** A page shot in shadow uses a fraction of the
//!   available tonal range, so the ink-to-paper contrast the model relies on is
//!   compressed into a few levels.
//!
//! ## The retry is a candidate, never a replacement
//!
//! Preprocessing an image can also make it *worse* — an over-stretched
//! histogram eats thin strokes, and a rotation resamples every glyph. So this
//! module never claims to improve a page. It proposes a second reading, and
//! [`choose_page_reading`] scores that reading against the original and keeps
//! whichever actually came out better, with the original holding a tie. The
//! worst case is time spent, not text lost.
//!
//! That is the same shape as [`crate::api::script`], which reads a page with
//! several models and scores the results against each other rather than
//! trusting any one of them. Here the models are identical and the *images*
//! differ.
//!
//! ## Why the platform is handed matrices
//!
//! The plan carries a ready-made affine transform and colour matrix rather
//! than an angle and a contrast setting. Sign conventions for rotation differ
//! between coordinate systems — y grows downward in image pixels and canvas
//! APIs vary — and a flipped sign silently doubles a page's tilt instead of
//! removing it, which no test on the platform side would be likely to catch.
//! Emitting the coefficients keeps that arithmetic here, next to the estimator
//! whose convention it has to match, and beside the inverse in
//! [`map_prepared_lines_to_source`] that has to undo it exactly.
//!
//! Coordinates are source pixels, y growing downward, as everywhere else.

use flutter_rust_bridge::frb;

use crate::api::ocr::{measure_page_geometry, OcrLineInput, OcrPageInput};

/// Tilt below this is not worth re-reading a page for. An on-device model is
/// unbothered by a degree or two, and a retry costs a full recognition pass.
const MIN_WORTH_ROTATION_DEGREES: f32 = 1.5;

/// Steepest tilt we will try to take out of the pixels, matching the ceiling
/// the estimator itself will report. Beyond this the estimate is noise.
const MAX_ROTATION_DEGREES: f32 = 20.0;

/// Printed line height, in pixels, that leaves a model comfortable room. Text
/// at least this tall is not upscaled.
const COMFORTABLE_LINE_HEIGHT: f32 = 30.0;

/// Below this the print is small enough that upscaling is worth a second pass
/// on its own.
const CRAMPED_LINE_HEIGHT: f32 = 22.0;

/// Most we will ever enlarge a page. Beyond this the interpolation is inventing
/// detail rather than recovering it.
const MAX_SCALE: f32 = 3.0;

/// Enlarging by less than this is not worth a second recognition pass.
const MIN_WORTH_SCALE: f32 = 1.15;

/// Output pixel ceiling, so upscaling a big capture cannot ask the platform for
/// a bitmap it has no memory for.
const MAX_OUTPUT_PIXELS: f32 = 24_000_000.0;

/// Share of the darkest pixels taken as ink when choosing the black point.
/// Not zero, because a single dark speck should not define the page's floor.
const INK_PERCENTILE: f32 = 0.02;

/// Luma levels the ink and paper must be apart before a stretch is believed to
/// be separating text from page rather than amplifying noise.
const MIN_INK_PAPER_SEPARATION: f32 = 40.0;

/// Tonal range a page has to be missing before a stretch is worth a second
/// pass: paper dimmer than this, or ink lifted this far off black.
const DIM_PAPER_LEVEL: f32 = 244.0;
const LIFTED_INK_LEVEL: f32 = 12.0;

/// Narrowest black-to-white window a stretch may produce. Squeezing harder than
/// this turns antialiased strokes into holes.
const MIN_LEVEL_WINDOW: f32 = 32.0;

/// Luma weights, matching the coefficients a display pipeline uses.
const LUMA_R: f32 = 0.2126;
const LUMA_G: f32 = 0.7152;
const LUMA_B: f32 = 0.0722;

/// Fewest characters a reading must hold before its score means anything.
const MIN_SCORED_CHARACTERS: usize = 4;

/// Confidence assumed for a recognizer that reports none, matching
/// [`crate::api::script`]. Silence is not certainty.
const NEUTRAL_CONFIDENCE: f32 = 0.75;

/// How much better a retry must read before the original is given up.
///
/// The first reading is the incumbent for the same reason Latin is in
/// [`crate::api::script`]: it is the one the user would have got anyway, and a
/// coin-flip between two readings of the same page would make the same scan
/// produce different text on different days. A retry has to earn the swap.
const RETRY_MARGIN: f32 = 1.06;

/// What a first reading revealed about a page, in source pixels.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PageMeasure {
    /// Tilt in degrees, negative leaning left, matching
    /// `ScannedNoteDraft::corrected_skew_degrees`.
    pub skew_degrees: f32,
    /// Median printed line height, with the tilt's inflation taken back out.
    pub median_line_height: f32,
    /// Lines that survived the noise filters.
    pub usable_lines: i32,
}

/// A page's brightness distribution, measured by the platform.
///
/// The histogram is expected to come from a heavily downscaled decode — the
/// shape of a page's tonal range survives shrinking, and sampling it at full
/// resolution would cost more than the recognition being decided about.
#[derive(Clone, Debug, PartialEq)]
pub struct PageLumaSample {
    /// 256 buckets of pixel counts, index 0 black. A shorter or longer vector
    /// is treated as no sample at all rather than misread.
    pub histogram: Vec<u32>,
}

/// Everything the platform needs to build a better bitmap, and nothing it has
/// to decide.
#[derive(Clone, Debug, PartialEq)]
pub struct PagePrepare {
    /// When false, nothing about this page is worth a second pass. Every other
    /// field is meaningless and the first reading stands.
    pub worthwhile: bool,

    /// Size of the bitmap to produce, in pixels.
    pub out_width: i32,
    pub out_height: i32,

    /// Source-to-prepared affine, as `[a, b, c, d, tx, ty]`, mapping
    /// `x' = a*x + c*y + tx` and `y' = b*x + d*y + ty`. Column-major, which is
    /// the order a 2D graphics matrix is usually loaded in.
    pub transform: Vec<f32>,

    /// 4x5 row-major colour matrix over unpremultiplied RGBA in 0..255, with
    /// the fifth column a constant offset — the layout `ColorFilter.matrix`
    /// takes. Converts to grey and stretches the tonal range in one pass.
    pub color_matrix: Vec<f32>,

    /// Degrees of tilt being taken out, for logging and for the UI.
    pub rotate_degrees: f32,
    /// Enlargement being applied, 1.0 when none.
    pub scale: f32,
    /// Human-readable account of why this page is being read again.
    pub reason: String,
}

impl PagePrepare {
    /// The "leave this page alone" answer.
    fn skip() -> Self {
        Self {
            worthwhile: false,
            out_width: 0,
            out_height: 0,
            transform: Vec::new(),
            color_matrix: Vec::new(),
            rotate_degrees: 0.0,
            scale: 1.0,
            reason: "the page is already square, large and well lit".to_owned(),
        }
    }
}

/// How well a reading of a page came out, comparable only against another
/// reading of the same page.
#[derive(Clone, Debug, PartialEq)]
pub struct PageReadingScore {
    /// Higher is better.
    pub score: f32,
    pub characters: i32,
    pub mean_confidence: f32,
    /// Share of characters that are neither letters nor digits.
    pub junk_share: f32,
    /// Share of whitespace-separated tokens that look like real words or
    /// numbers rather than debris.
    pub word_share: f32,
}

/// Which reading of a page won, and why.
#[derive(Clone, Debug, PartialEq)]
pub struct PageReadingChoice {
    /// Index into the readings offered, or -1 when none held any text.
    pub chosen: i32,
    pub scores: Vec<PageReadingScore>,
    pub reason: String,
}

// --- Measuring ------------------------------------------------------------

/// Read a page's tilt and print size off a first pass.
///
/// Delegates to [`crate::api::ocr`] rather than re-deriving anything, so the
/// tilt a retry rotates out is the same number the reconstruction would have
/// sheared the boxes by.
#[frb(sync)]
pub fn measure_page(page: OcrPageInput) -> PageMeasure {
    let geometry = measure_page_geometry(&page);
    PageMeasure {
        skew_degrees: geometry.skew_slope.atan().to_degrees(),
        median_line_height: geometry.median_line_height,
        usable_lines: i32::try_from(geometry.usable_lines).unwrap_or(i32::MAX),
    }
}

// --- Planning -------------------------------------------------------------

/// Decide whether a page is worth showing the recognizer again, and how.
///
/// `width` and `height` are the source bitmap's pixel size; zero for either
/// means the platform could not read it, and no plan is made, because every
/// output dimension would be a guess.
#[frb(sync)]
pub fn plan_page_prepare(
    measure: PageMeasure,
    sample: PageLumaSample,
    width: f32,
    height: f32,
) -> PagePrepare {
    if !(width >= 1.0 && height >= 1.0) {
        return PagePrepare::skip();
    }

    let rotate_degrees = worthwhile_rotation(measure.skew_degrees);
    let scale = worthwhile_scale(measure.median_line_height, width, height);
    let levels = worthwhile_levels(&sample.histogram);

    if rotate_degrees == 0.0 && scale == 1.0 && levels.is_none() {
        return PagePrepare::skip();
    }

    let radians = -rotate_degrees.to_radians();
    let (sin, cos) = (radians.sin(), radians.cos());

    // A rotated page no longer fits its own frame, so the output grows to the
    // rotated bounding box. Cropping to the original size instead would shave
    // the corners off a tilted page, which is exactly where a margin note or
    // the last word of a line tends to sit.
    let out_width = (width * cos.abs() + height * sin.abs()) * scale;
    let out_height = (width * sin.abs() + height * cos.abs()) * scale;

    // Rotate about the source's centre, land on the output's centre.
    let (source_centre_x, source_centre_y) = (width / 2.0, height / 2.0);
    let (out_centre_x, out_centre_y) = (out_width / 2.0, out_height / 2.0);
    let (a, b, c, d) = (scale * cos, scale * sin, -scale * sin, scale * cos);
    let transform = vec![
        a,
        b,
        c,
        d,
        out_centre_x - (a * source_centre_x + c * source_centre_y),
        out_centre_y - (b * source_centre_x + d * source_centre_y),
    ];

    let (black, white) = levels.unwrap_or((0.0, 255.0));
    PagePrepare {
        worthwhile: true,
        out_width: out_width.ceil() as i32,
        out_height: out_height.ceil() as i32,
        transform,
        color_matrix: level_colour_matrix(black, white),
        rotate_degrees,
        scale,
        reason: describe_plan(rotate_degrees, scale, levels.is_some()),
    }
}

/// Tilt worth rotating out, or zero.
fn worthwhile_rotation(skew_degrees: f32) -> f32 {
    if !skew_degrees.is_finite() {
        return 0.0;
    }
    let magnitude = skew_degrees.abs();
    if !(MIN_WORTH_ROTATION_DEGREES..=MAX_ROTATION_DEGREES).contains(&magnitude) {
        return 0.0;
    }
    skew_degrees
}

/// Enlargement worth applying, or 1.0.
fn worthwhile_scale(median_line_height: f32, width: f32, height: f32) -> f32 {
    if !median_line_height.is_finite()
        || median_line_height <= 0.0
        || median_line_height >= CRAMPED_LINE_HEIGHT
    {
        return 1.0;
    }
    let wanted = COMFORTABLE_LINE_HEIGHT / median_line_height;
    // Never ask for a bitmap the platform cannot hold.
    let budget = (MAX_OUTPUT_PIXELS / (width * height)).max(1.0).sqrt();
    let scale = wanted.min(MAX_SCALE).min(budget);
    if scale < MIN_WORTH_SCALE {
        1.0
    } else {
        scale
    }
}

/// The black and white points worth stretching a page to, or [`None`] when its
/// tonal range is already being used.
///
/// Paper is taken as the tallest bucket in the upper half of the range rather
/// than a high percentile, because a photograph often carries a specular
/// highlight — a glare spot or a window — far brighter than the page. A
/// percentile would anchor white to that and conclude, wrongly, that a dim page
/// already reaches white.
fn worthwhile_levels(histogram: &[u32]) -> Option<(f32, f32)> {
    if histogram.len() != 256 {
        return None;
    }
    let total: f64 = histogram.iter().map(|count| f64::from(*count)).sum();
    if total <= 0.0 {
        return None;
    }

    let ink = percentile_level(histogram, total, INK_PERCENTILE)?;
    let paper = paper_level(histogram)?;

    if paper - ink < MIN_INK_PAPER_SEPARATION {
        return None;
    }
    // Already using the range: nothing to gain that would justify a re-read.
    if paper > DIM_PAPER_LEVEL && ink < LIFTED_INK_LEVEL {
        return None;
    }
    if paper - ink < MIN_LEVEL_WINDOW {
        return None;
    }
    Some((ink, paper))
}

/// Luma level at which `share` of the pixels have been counted.
fn percentile_level(histogram: &[u32], total: f64, share: f32) -> Option<f32> {
    let target = total * f64::from(share);
    let mut seen = 0.0f64;
    for (level, count) in histogram.iter().enumerate() {
        seen += f64::from(*count);
        if seen >= target {
            return Some(level as f32);
        }
    }
    None
}

/// The page's own brightness: the most populated level above the midpoint.
fn paper_level(histogram: &[u32]) -> Option<f32> {
    let (level, count) = histogram
        .iter()
        .enumerate()
        .skip(128)
        .max_by_key(|(_, count)| **count)?;
    if *count == 0 {
        return None;
    }
    Some(level as f32)
}

/// Grey-and-stretch as one colour matrix.
///
/// Each output channel becomes `gain * luma + offset`, which maps `black` to 0
/// and `white` to 255 while collapsing colour to luminance. Doing both in one
/// matrix means the platform makes a single pass over the pixels.
fn level_colour_matrix(black: f32, white: f32) -> Vec<f32> {
    let span = (white - black).max(1.0);
    let gain = 255.0 / span;
    let offset = -black * gain;
    vec![
        gain * LUMA_R,
        gain * LUMA_G,
        gain * LUMA_B,
        0.0,
        offset,
        gain * LUMA_R,
        gain * LUMA_G,
        gain * LUMA_B,
        0.0,
        offset,
        gain * LUMA_R,
        gain * LUMA_G,
        gain * LUMA_B,
        0.0,
        offset,
        0.0,
        0.0,
        0.0,
        1.0,
        0.0,
    ]
}

fn describe_plan(rotate_degrees: f32, scale: f32, levels: bool) -> String {
    let mut parts: Vec<String> = Vec::new();
    if rotate_degrees != 0.0 {
        parts.push(format!("straightening {:.1}°", rotate_degrees.abs()));
    }
    if scale > 1.0 {
        parts.push(format!("enlarging {scale:.1}x for small print"));
    }
    if levels {
        parts.push("lifting the contrast".to_owned());
    }
    if parts.is_empty() {
        return "nothing to do".to_owned();
    }
    parts.join(", ")
}

// --- Mapping back ---------------------------------------------------------

/// Put a prepared page's boxes back into source-image pixels.
///
/// The second reading's boxes describe the bitmap the platform built, not the
/// photograph on disk. They have to be brought back, because the stored text
/// layer is indexed against the original attachment: it is what draws a
/// highlight over a searched word and what crops a region out of a form. Boxes
/// left in prepared space would put both in the wrong place.
///
/// A rotated rectangle is not a rectangle, and the recognizer only ever reports
/// axis-aligned ones, so each box comes back as the bounding box of its four
/// mapped corners. That inflates a box on a tilted page by a share of its own
/// width — which is precisely the inflation
/// [`crate::api::ocr`]'s `undo_tilt_inflation` exists to take out, and it is
/// measured from the boxes themselves, so a mapped-back page is corrected on
/// exactly the same footing as one the recognizer read tilted in the first
/// place.
#[frb(sync)]
pub fn map_prepared_lines_to_source(
    lines: Vec<OcrLineInput>,
    prepare: PagePrepare,
) -> Vec<OcrLineInput> {
    let Some(inverse) = invert(&prepare.transform) else {
        return lines;
    };
    lines
        .into_iter()
        .map(|line| {
            let corners = [
                apply(&inverse, line.left, line.top),
                apply(&inverse, line.right, line.top),
                apply(&inverse, line.right, line.bottom),
                apply(&inverse, line.left, line.bottom),
            ];
            let left = corners.iter().map(|point| point.0).fold(f32::MAX, f32::min);
            let right = corners.iter().map(|point| point.0).fold(f32::MIN, f32::max);
            let top = corners.iter().map(|point| point.1).fold(f32::MAX, f32::min);
            let bottom = corners.iter().map(|point| point.1).fold(f32::MIN, f32::max);
            OcrLineInput {
                left,
                top,
                right,
                bottom,
                ..line
            }
        })
        .collect()
}

/// Invert `[a, b, c, d, tx, ty]`. [`None`] when the transform is degenerate,
/// which a plan built by [`plan_page_prepare`] never is.
fn invert(transform: &[f32]) -> Option<[f32; 6]> {
    if transform.len() != 6 {
        return None;
    }
    let (a, b, c, d, tx, ty) = (
        transform[0],
        transform[1],
        transform[2],
        transform[3],
        transform[4],
        transform[5],
    );
    let determinant = a * d - b * c;
    if !determinant.is_finite() || determinant.abs() <= f32::EPSILON {
        return None;
    }
    let (ia, ib, ic, id) = (
        d / determinant,
        -b / determinant,
        -c / determinant,
        a / determinant,
    );
    Some([ia, ib, ic, id, -(ia * tx + ic * ty), -(ib * tx + id * ty)])
}

fn apply(transform: &[f32; 6], x: f32, y: f32) -> (f32, f32) {
    (
        transform[0] * x + transform[2] * y + transform[4],
        transform[1] * x + transform[3] * y + transform[5],
    )
}

// --- Choosing -------------------------------------------------------------

/// Judge one reading of a page.
///
/// Deliberately not [`crate::api::script`]'s score, which weighs how well a
/// reading matches the *alphabet* a model was looking for. Both readings here
/// come from the same model, so what separates them is how much text was found
/// and how much of it looks like language: a poor read of a page does not come
/// back empty, it comes back with the right amount of debris.
#[frb(sync)]
pub fn score_page_reading(page: OcrPageInput) -> PageReadingScore {
    let text = page
        .lines
        .iter()
        .map(|line| line.text.as_str())
        .collect::<Vec<_>>()
        .join(" ");

    let visible: Vec<char> = text.chars().filter(|c| !c.is_whitespace()).collect();
    let characters = visible.len();
    let junk = visible.iter().filter(|c| !c.is_alphanumeric()).count();
    let junk_share = if characters == 0 {
        0.0
    } else {
        junk as f32 / characters as f32
    };

    let tokens: Vec<&str> = text.split_whitespace().collect();
    let wordlike = tokens
        .iter()
        .filter(|token| looks_like_a_word(token))
        .count();
    let word_share = if tokens.is_empty() {
        0.0
    } else {
        wordlike as f32 / tokens.len() as f32
    };

    let scored: Vec<f32> = page
        .lines
        .iter()
        .filter_map(|line| line.confidence)
        .collect();
    let mean_confidence = if scored.is_empty() {
        NEUTRAL_CONFIDENCE
    } else {
        scored.iter().sum::<f32>() / scored.len() as f32
    };

    // Volume dominates, square-rooted so twice the text is not twice the
    // evidence — the same shape script scoring uses. The two shares then
    // discount a reading that found plenty of characters but little language,
    // which is what a bad exposure produces.
    let volume = if characters < MIN_SCORED_CHARACTERS {
        0.0
    } else {
        (characters as f32).sqrt()
    };
    let cleanliness = (1.0 - junk_share).max(0.05);
    let language = (0.25 + 0.75 * word_share).min(1.0);
    PageReadingScore {
        score: volume * cleanliness * language * mean_confidence,
        characters: i32::try_from(characters).unwrap_or(i32::MAX),
        mean_confidence,
        junk_share,
        word_share,
    }
}

/// Whether a token reads as a word or a number rather than as debris.
///
/// A misread produces a scatter of one-character tokens and letter/digit
/// salads; real text is mostly runs of letters, runs of digits, and words
/// carrying an apostrophe or a hyphen. Single characters are not counted
/// either way — "a" and "I" are words, and so is every speck.
fn looks_like_a_word(token: &str) -> bool {
    let core: Vec<char> = token
        .chars()
        .filter(|c| {
            !matches!(
                c,
                '.' | ',' | ';' | ':' | '!' | '?' | '"' | '\'' | '(' | ')'
            )
        })
        .collect();
    if core.len() < 2 {
        return false;
    }
    let letters = core.iter().filter(|c| c.is_alphabetic()).count();
    let digits = core.iter().filter(|c| c.is_numeric()).count();
    let joiners = core
        .iter()
        .filter(|c| matches!(c, '-' | '\'' | '’'))
        .count();
    letters + joiners == core.len() || digits + joiners == core.len()
}

/// Pick the best of several readings of one page.
///
/// Index 0 is taken as the incumbent — the reading the user would have got
/// without a retry — and keeps the page unless another beats it by
/// [`RETRY_MARGIN`]. See the module comment.
#[frb(sync)]
pub fn choose_page_reading(readings: Vec<OcrPageInput>) -> PageReadingChoice {
    let scores: Vec<PageReadingScore> = readings.into_iter().map(score_page_reading).collect();
    if scores.is_empty() {
        return PageReadingChoice {
            chosen: -1,
            scores,
            reason: "nothing was read".to_owned(),
        };
    }

    let mut best = 0usize;
    for (index, score) in scores.iter().enumerate() {
        if score.score > scores[best].score {
            best = index;
        }
    }

    let mut reason = if best == 0 {
        "the first reading was already the best".to_owned()
    } else {
        format!("reading {best} read the page better")
    };
    if best != 0 && scores[best].score < scores[0].score * RETRY_MARGIN {
        best = 0;
        reason = "no retry read the page clearly better".to_owned();
    }

    if scores[best].characters == 0 {
        return PageReadingChoice {
            chosen: -1,
            scores,
            reason: "no reading found any text".to_owned(),
        };
    }

    PageReadingChoice {
        chosen: i32::try_from(best).unwrap_or(-1),
        scores,
        reason,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn line(text: &str, left: f32, top: f32, right: f32, bottom: f32) -> OcrLineInput {
        OcrLineInput {
            text: text.to_owned(),
            left,
            top,
            right,
            bottom,
            block_index: 0,
            confidence: None,
        }
    }

    fn page(lines: Vec<OcrLineInput>) -> OcrPageInput {
        OcrPageInput {
            lines,
            width: 1000.0,
            height: 1400.0,
        }
    }

    /// A page of level, comfortably sized lines on well-used paper.
    fn easy_measure() -> PageMeasure {
        PageMeasure {
            skew_degrees: 0.0,
            median_line_height: 40.0,
            usable_lines: 20,
        }
    }

    /// A histogram whose ink and paper already reach both ends of the range.
    fn full_range_histogram() -> PageLumaSample {
        let mut histogram = vec![0u32; 256];
        histogram[2] = 500;
        histogram[255] = 5000;
        PageLumaSample { histogram }
    }

    /// A dim page: ink lifted off black, paper well short of white.
    fn dim_histogram() -> PageLumaSample {
        let mut histogram = vec![0u32; 256];
        histogram[60] = 500;
        histogram[180] = 5000;
        PageLumaSample { histogram }
    }

    #[test]
    fn a_square_bright_page_is_left_alone() {
        let plan = plan_page_prepare(easy_measure(), full_range_histogram(), 1000.0, 1400.0);
        assert!(!plan.worthwhile, "plan was {plan:?}");
    }

    #[test]
    fn an_unreadable_source_size_makes_no_plan() {
        let plan = plan_page_prepare(easy_measure(), dim_histogram(), 0.0, 0.0);
        assert!(!plan.worthwhile);
    }

    #[test]
    fn a_gentle_tilt_is_not_worth_a_second_pass() {
        let measure = PageMeasure {
            skew_degrees: 1.0,
            ..easy_measure()
        };
        let plan = plan_page_prepare(measure, full_range_histogram(), 1000.0, 1400.0);
        assert!(!plan.worthwhile);
    }

    #[test]
    fn a_wild_tilt_is_not_believed() {
        let measure = PageMeasure {
            skew_degrees: 35.0,
            ..easy_measure()
        };
        let plan = plan_page_prepare(measure, full_range_histogram(), 1000.0, 1400.0);
        assert!(!plan.worthwhile);
    }

    #[test]
    fn a_real_tilt_grows_the_canvas_to_fit_the_rotation() {
        let measure = PageMeasure {
            skew_degrees: 8.0,
            ..easy_measure()
        };
        let plan = plan_page_prepare(measure, full_range_histogram(), 1000.0, 1400.0);
        assert!(plan.worthwhile);
        assert_eq!(plan.rotate_degrees, 8.0);
        assert_eq!(plan.scale, 1.0);
        // A rotated page needs more room than it started with, in both axes.
        assert!(plan.out_width > 1000);
        assert!(plan.out_height > 1400);
        assert!(plan.reason.contains("straightening"), "{}", plan.reason);
    }

    #[test]
    fn small_print_is_enlarged_towards_a_comfortable_height() {
        let measure = PageMeasure {
            median_line_height: 12.0,
            ..easy_measure()
        };
        let plan = plan_page_prepare(measure, full_range_histogram(), 1000.0, 1400.0);
        assert!(plan.worthwhile);
        assert!((plan.scale - 2.5).abs() < 0.001, "scale was {}", plan.scale);
        assert_eq!(plan.out_width, 2500);
        assert_eq!(plan.out_height, 3500);
    }

    #[test]
    fn enlargement_is_capped_so_it_cannot_invent_detail() {
        let measure = PageMeasure {
            median_line_height: 2.0,
            ..easy_measure()
        };
        let plan = plan_page_prepare(measure, full_range_histogram(), 1000.0, 1400.0);
        assert_eq!(plan.scale, MAX_SCALE);
    }

    #[test]
    fn enlargement_stays_inside_the_platform_pixel_budget() {
        let measure = PageMeasure {
            median_line_height: 8.0,
            ..easy_measure()
        };
        // A 12 megapixel capture cannot be tripled without blowing the budget.
        let plan = plan_page_prepare(measure, full_range_histogram(), 4000.0, 3000.0);
        assert!(plan.worthwhile);
        let pixels = plan.out_width as f32 * plan.out_height as f32;
        assert!(plan.scale < MAX_SCALE, "scale was {}", plan.scale);
        // The budget bounds the scaled source area; rounding each axis up to a
        // whole pixel afterwards can carry the product a hair past it.
        assert!(
            pixels <= MAX_OUTPUT_PIXELS * 1.001,
            "output was {pixels} pixels"
        );
    }

    #[test]
    fn a_dim_page_has_its_contrast_lifted() {
        let plan = plan_page_prepare(easy_measure(), dim_histogram(), 1000.0, 1400.0);
        assert!(plan.worthwhile);
        assert_eq!(plan.rotate_degrees, 0.0);
        assert_eq!(plan.scale, 1.0);
        assert!(plan.reason.contains("contrast"), "{}", plan.reason);
        // The stretch has to map the measured ink to black and paper to white.
        let matrix = plan.color_matrix;
        assert_eq!(matrix.len(), 20);
        let luma_at =
            |level: f32| matrix[0] * level + matrix[1] * level + matrix[2] * level + matrix[4];
        assert!(luma_at(60.0).abs() < 0.5, "ink mapped to {}", luma_at(60.0));
        assert!(
            (luma_at(180.0) - 255.0).abs() < 0.5,
            "paper mapped to {}",
            luma_at(180.0)
        );
    }

    #[test]
    fn a_glare_spot_does_not_pass_for_paper() {
        // Paper sits at 170, with a tiny specular highlight blown out to white.
        let mut histogram = vec![0u32; 256];
        histogram[55] = 400;
        histogram[170] = 6000;
        histogram[255] = 40;
        let plan = plan_page_prepare(easy_measure(), PageLumaSample { histogram }, 1000.0, 1400.0);
        assert!(
            plan.worthwhile,
            "a highlight should not make a dim page look bright"
        );
    }

    #[test]
    fn a_flat_grey_image_is_not_stretched_into_noise() {
        // No ink-to-paper separation at all: nothing here is a page of text.
        let mut histogram = vec![0u32; 256];
        histogram[130] = 9000;
        histogram[132] = 9000;
        let plan = plan_page_prepare(easy_measure(), PageLumaSample { histogram }, 1000.0, 1400.0);
        assert!(!plan.worthwhile);
    }

    #[test]
    fn a_malformed_histogram_is_ignored_rather_than_misread() {
        let plan = plan_page_prepare(
            easy_measure(),
            PageLumaSample {
                histogram: vec![1, 2, 3],
            },
            1000.0,
            1400.0,
        );
        assert!(!plan.worthwhile);
    }

    #[test]
    fn an_empty_page_can_still_be_retried_on_lighting_alone() {
        // The first pass found nothing, which is exactly the case a dim photo
        // produces — there is no tilt or print size to measure, but the
        // histogram still says the exposure was poor.
        let measure = PageMeasure {
            skew_degrees: 0.0,
            median_line_height: 0.0,
            usable_lines: 0,
        };
        let plan = plan_page_prepare(measure, dim_histogram(), 1000.0, 1400.0);
        assert!(plan.worthwhile);
    }

    #[test]
    fn mapping_back_through_a_pure_enlargement_undoes_it() {
        let measure = PageMeasure {
            median_line_height: 12.0,
            ..easy_measure()
        };
        let plan = plan_page_prepare(measure, full_range_histogram(), 1000.0, 1400.0);
        let mapped =
            map_prepared_lines_to_source(vec![line("hello", 250.0, 500.0, 750.0, 550.0)], plan);
        let box_ = &mapped[0];
        assert!((box_.left - 100.0).abs() < 0.01, "left was {}", box_.left);
        assert!((box_.top - 200.0).abs() < 0.01, "top was {}", box_.top);
        assert!(
            (box_.right - 300.0).abs() < 0.01,
            "right was {}",
            box_.right
        );
        assert!(
            (box_.bottom - 220.0).abs() < 0.01,
            "bottom was {}",
            box_.bottom
        );
    }

    #[test]
    fn a_box_round_trips_through_the_rotation_it_was_read_under() {
        let measure = PageMeasure {
            skew_degrees: 7.0,
            ..easy_measure()
        };
        let plan = plan_page_prepare(measure, full_range_histogram(), 1000.0, 1400.0);
        let transform: Vec<f32> = plan.transform.clone();

        // Take a box in source space, push it forward through the plan's own
        // transform, and ask the inverse for it back. A rotated rectangle
        // bounds larger than it started, so the recovered box must *contain*
        // the original rather than equal it.
        let source = line("x", 400.0, 600.0, 600.0, 640.0);
        let forward: [f32; 6] = transform.clone().try_into().unwrap();
        let corners = [
            apply(&forward, source.left, source.top),
            apply(&forward, source.right, source.top),
            apply(&forward, source.right, source.bottom),
            apply(&forward, source.left, source.bottom),
        ];
        let prepared = line(
            "x",
            corners.iter().map(|p| p.0).fold(f32::MAX, f32::min),
            corners.iter().map(|p| p.1).fold(f32::MAX, f32::min),
            corners.iter().map(|p| p.0).fold(f32::MIN, f32::max),
            corners.iter().map(|p| p.1).fold(f32::MIN, f32::max),
        );

        let recovered = map_prepared_lines_to_source(vec![prepared], plan);
        let box_ = &recovered[0];
        assert!(box_.left <= source.left + 0.01, "left was {}", box_.left);
        assert!(box_.top <= source.top + 0.01, "top was {}", box_.top);
        assert!(
            box_.right >= source.right - 0.01,
            "right was {}",
            box_.right
        );
        assert!(
            box_.bottom >= source.bottom - 0.01,
            "bottom was {}",
            box_.bottom
        );
        // And it must not have wandered off: the centre is preserved exactly.
        let centre_x = (box_.left + box_.right) / 2.0;
        let centre_y = (box_.top + box_.bottom) / 2.0;
        assert!((centre_x - 500.0).abs() < 0.1, "centre x was {centre_x}");
        assert!((centre_y - 620.0).abs() < 0.1, "centre y was {centre_y}");
    }

    #[test]
    fn a_skipped_plan_leaves_boxes_untouched() {
        let plan = PagePrepare::skip();
        let mapped =
            map_prepared_lines_to_source(vec![line("hello", 10.0, 20.0, 30.0, 40.0)], plan);
        assert_eq!(mapped[0].left, 10.0);
        assert_eq!(mapped[0].right, 30.0);
    }

    #[test]
    fn a_cleaner_reading_of_the_same_page_wins() {
        let poor = page(vec![line("t|1e qu1(k br0wn", 0.0, 0.0, 400.0, 40.0)]);
        let good = page(vec![line("the quick brown fox", 0.0, 0.0, 400.0, 40.0)]);
        let choice = choose_page_reading(vec![poor, good]);
        assert_eq!(choice.chosen, 1, "{}", choice.reason);
    }

    #[test]
    fn an_identical_retry_leaves_the_page_with_the_original() {
        let text = "the quick brown fox jumps over the lazy dog";
        let choice = choose_page_reading(vec![
            page(vec![line(text, 0.0, 0.0, 400.0, 40.0)]),
            page(vec![line(text, 0.0, 0.0, 400.0, 40.0)]),
        ]);
        assert_eq!(choice.chosen, 0, "{}", choice.reason);
    }

    #[test]
    fn a_retry_that_is_only_marginally_better_does_not_displace_the_original() {
        // One extra word scores the retry a few percent above the original —
        // genuinely ahead, but well short of the margin that buys the swap.
        let choice = choose_page_reading(vec![
            page(vec![line(
                "the quick brown fox jumps over the lazy dog",
                0.0,
                0.0,
                400.0,
                40.0,
            )]),
            page(vec![line(
                "the quick brown fox jumps over the lazy dog too",
                0.0,
                0.0,
                400.0,
                40.0,
            )]),
        ]);
        assert_eq!(choice.chosen, 0, "{}", choice.reason);
        assert!(
            choice.reason.contains("clearly better"),
            "{}",
            choice.reason
        );
    }

    #[test]
    fn a_retry_that_finds_text_on_a_blank_first_pass_wins() {
        let choice = choose_page_reading(vec![
            page(Vec::new()),
            page(vec![line("Minutes of the meeting", 0.0, 0.0, 400.0, 40.0)]),
        ]);
        assert_eq!(choice.chosen, 1, "{}", choice.reason);
    }

    #[test]
    fn readings_that_all_found_nothing_choose_nothing() {
        let choice = choose_page_reading(vec![page(Vec::new()), page(Vec::new())]);
        assert_eq!(choice.chosen, -1);
    }

    #[test]
    fn no_readings_at_all_choose_nothing() {
        let choice = choose_page_reading(Vec::new());
        assert_eq!(choice.chosen, -1);
        assert!(choice.scores.is_empty());
    }

    #[test]
    fn debris_scores_below_language_at_the_same_length() {
        let prose = score_page_reading(page(vec![line(
            "the quick brown fox jumps",
            0.0,
            0.0,
            400.0,
            40.0,
        )]));
        let debris = score_page_reading(page(vec![line(
            "t|1e qu1(k br0wn f0x jump5",
            0.0,
            0.0,
            400.0,
            40.0,
        )]));
        assert!(
            prose.score > debris.score,
            "prose {} vs debris {}",
            prose.score,
            debris.score
        );
        assert!(prose.word_share > debris.word_share);
    }

    #[test]
    fn a_silent_recognizer_is_not_treated_as_a_confident_one() {
        let silent = score_page_reading(page(vec![line("hello there", 0.0, 0.0, 100.0, 20.0)]));
        assert_eq!(silent.mean_confidence, NEUTRAL_CONFIDENCE);

        let mut confident = line("hello there", 0.0, 0.0, 100.0, 20.0);
        confident.confidence = Some(0.98);
        let scored = score_page_reading(page(vec![confident]));
        assert!(scored.score > silent.score);
    }

    #[test]
    fn word_shapes_are_told_from_debris() {
        assert!(looks_like_a_word("hello"));
        assert!(looks_like_a_word("well-worn"));
        assert!(looks_like_a_word("don't"));
        assert!(looks_like_a_word("1984"));
        assert!(looks_like_a_word("hello,"));
        assert!(!looks_like_a_word("a"));
        assert!(!looks_like_a_word("|"));
        assert!(!looks_like_a_word("qu1(k"));
        assert!(!looks_like_a_word("f0x"));
    }
}
