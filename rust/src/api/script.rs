//! Working out which alphabet a page is written in.
//!
//! An on-device recognizer is not one model but several, one per script, and a
//! model only reads the script it was trained on. Shown a Japanese menu, the
//! Latin model does not fail — it returns a thin scatter of plausible-looking
//! Latin letters, which is worse, because nothing downstream can tell that
//! from a genuinely sparse page.
//!
//! That leaves a circularity: choosing the right model needs to know the
//! script, and knowing the script needs a model that can read it. The way out
//! is to stop treating recognition as a question with one answer. Read the page
//! with more than one model and *score the readings against each other*: the
//! model that matches the page comes back with far more text, in the script it
//! was looking for, at higher confidence, covering more of the paper. The
//! mismatched ones come back thin and full of junk.
//!
//! Scoring lives here rather than in the platform layer for the usual reason —
//! it is a decision, it is testable without a camera, and it must not differ
//! between Android and iOS. The platform only runs the models it has.
//!
//! Trying every model on every page would be wasteful, so the intended use is
//! cheap-path-first: read with Latin, ask [`reading_looks_wrong`], and only pay
//! for the other models when the first answer looks like a mismatch.

use flutter_rust_bridge::frb;

use crate::api::ocr::OcrPageInput;

/// Share of a mismatched read that is typically punctuation and stray marks.
/// Above this, the reading is suspect whatever else it scored.
const JUNK_SHARE_SUSPECT: f32 = 0.4;

/// A reading holding fewer letters than this has not read a page of text,
/// whatever the recognizer claims.
const MIN_PLAUSIBLE_CHARACTERS: usize = 12;

/// Page area a real reading covers with text boxes. Well below what a dense
/// page reaches; this is a floor for "something was actually read".
const MIN_PLAUSIBLE_COVERAGE: f32 = 0.01;

/// Confidence below which a reading is doubted even if it is long.
const WEAK_CONFIDENCE: f32 = 0.5;

/// How much better a rival must score before Latin is given up.
///
/// Latin is the common case and the only model always present, so a near-tie
/// keeps it. Without this, a page of ordinary English could flip to the
/// Japanese model — which also reads Latin — on noise alone, and the choice
/// would flap between scans of the same page.
const RIVAL_MARGIN: f32 = 1.25;

/// A writing system, as far as picking a recognizer is concerned.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TextScript {
    Unknown,
    Latin,
    Chinese,
    Japanese,
    Korean,
    Devanagari,
    /// Detectable, but no on-device model reads it.
    Cyrillic,
    Greek,
    Arabic,
    Hebrew,
    Thai,
}

impl TextScript {
    /// Whether an on-device recognizer exists for this script.
    ///
    /// Cyrillic, Greek, Arabic, Hebrew and Thai are detectable but not
    /// readable: no on-device model ships for them. Saying so plainly lets the
    /// app tell the user their page cannot be read here, rather than handing
    /// back the Latin model's guesses as if they meant something.
    fn recognizable(self) -> bool {
        matches!(
            self,
            TextScript::Latin
                | TextScript::Chinese
                | TextScript::Japanese
                | TextScript::Korean
                | TextScript::Devanagari
        )
    }
}

/// What script a piece of text is written in.
#[derive(Clone, Debug, PartialEq)]
pub struct ScriptReport {
    pub script: TextScript,
    /// Share of the letters that belong to [script], 0..1.
    pub confidence: f32,
    /// Letters counted, ignoring digits, spaces and punctuation.
    pub letters: i32,
    /// Whether an on-device recognizer exists for [script].
    pub recognizable: bool,
}

/// One recognizer's attempt at a page.
#[derive(Clone, Debug, PartialEq)]
pub struct ScriptReading {
    /// The script the model that produced this was looking for.
    pub script: TextScript,
    pub page: OcrPageInput,
}

/// How well a reading came out.
#[derive(Clone, Debug, PartialEq)]
pub struct ReadingScore {
    pub script: TextScript,
    /// Comparable across readings of the same page. Higher is better.
    pub score: f32,
    pub characters: i32,
    pub mean_confidence: f32,
    /// Share of the page covered by text boxes.
    pub coverage: f32,
    /// Share of characters that are neither letters nor digits — the signature
    /// of a model reading a script it does not know.
    pub junk_share: f32,
    /// The script the recognized text actually turned out to be in, which is
    /// not always the one the model was looking for.
    pub dominant_script: TextScript,
}

/// Which reading won, and why.
#[derive(Clone, Debug, PartialEq)]
pub struct ScriptChoice {
    /// Index into the readings that were offered. -1 when none were usable.
    pub chosen: i32,
    pub script: TextScript,
    pub scores: Vec<ReadingScore>,
    pub reason: String,
}

// --- Detection ------------------------------------------------------------

/// Which script some already-recognized text is written in.
#[frb(sync)]
pub fn detect_script(text: String) -> ScriptReport {
    let counts = count_letters(&text);
    let total = counts.total();
    if total == 0 {
        return ScriptReport {
            script: TextScript::Unknown,
            confidence: 0.0,
            letters: 0,
            recognizable: false,
        };
    }

    // Kana and Hangul settle it outright. Japanese is mostly kanji by volume,
    // so counting characters would call a Japanese page Chinese; but Chinese
    // never uses kana, so any kana at all is decisive. Hangul is the same.
    let script = if counts.kana > 0 {
        TextScript::Japanese
    } else if counts.hangul > 0 {
        TextScript::Korean
    } else {
        let mut ranked = [
            (TextScript::Latin, counts.latin),
            (TextScript::Chinese, counts.han),
            (TextScript::Devanagari, counts.devanagari),
            (TextScript::Cyrillic, counts.cyrillic),
            (TextScript::Greek, counts.greek),
            (TextScript::Arabic, counts.arabic),
            (TextScript::Hebrew, counts.hebrew),
            (TextScript::Thai, counts.thai),
        ];
        ranked.sort_by(|a, b| b.1.cmp(&a.1));
        if ranked[0].1 == 0 {
            TextScript::Unknown
        } else {
            ranked[0].0
        }
    };

    let matched = match script {
        TextScript::Japanese => counts.kana + counts.han,
        TextScript::Korean => counts.hangul,
        TextScript::Latin => counts.latin,
        TextScript::Chinese => counts.han,
        TextScript::Devanagari => counts.devanagari,
        TextScript::Cyrillic => counts.cyrillic,
        TextScript::Greek => counts.greek,
        TextScript::Arabic => counts.arabic,
        TextScript::Hebrew => counts.hebrew,
        TextScript::Thai => counts.thai,
        TextScript::Unknown => 0,
    };

    ScriptReport {
        script,
        confidence: matched as f32 / total as f32,
        letters: i32::try_from(total).unwrap_or(i32::MAX),
        recognizable: script.recognizable(),
    }
}

/// Internal tally. Kept off the bridge: it is a counter, not a result, and
/// exposing it would generate a Dart class whose `other` field collides with
/// the `other` parameter of its own equality operator.
#[frb(ignore)]
#[derive(Default)]
struct LetterCounts {
    latin: usize,
    han: usize,
    kana: usize,
    hangul: usize,
    devanagari: usize,
    cyrillic: usize,
    greek: usize,
    arabic: usize,
    hebrew: usize,
    thai: usize,
    other: usize,
}

impl LetterCounts {
    fn total(&self) -> usize {
        self.latin
            + self.han
            + self.kana
            + self.hangul
            + self.devanagari
            + self.cyrillic
            + self.greek
            + self.arabic
            + self.hebrew
            + self.thai
            + self.other
    }
}

fn count_letters(text: &str) -> LetterCounts {
    let mut counts = LetterCounts::default();
    for character in text.chars() {
        // Digits and punctuation say nothing about the script: a price is the
        // same characters in every language.
        if !character.is_alphabetic() {
            continue;
        }
        let code = character as u32;
        match code {
            0x0041..=0x005A | 0x0061..=0x007A | 0x00C0..=0x024F => counts.latin += 1,
            0x0370..=0x03FF | 0x1F00..=0x1FFF => counts.greek += 1,
            // Cyrillic and Cyrillic Supplement, which sit next to each other.
            0x0400..=0x052F => counts.cyrillic += 1,
            0x0590..=0x05FF => counts.hebrew += 1,
            0x0600..=0x06FF | 0x0750..=0x077F | 0x08A0..=0x08FF => counts.arabic += 1,
            0x0900..=0x097F => counts.devanagari += 1,
            0x0E00..=0x0E7F => counts.thai += 1,
            0x3040..=0x309F | 0x30A0..=0x30FF | 0x31F0..=0x31FF => counts.kana += 1,
            0x1100..=0x11FF | 0x3130..=0x318F | 0xA960..=0xA97F | 0xAC00..=0xD7AF => {
                counts.hangul += 1
            }
            0x3400..=0x4DBF | 0x4E00..=0x9FFF | 0xF900..=0xFAFF => counts.han += 1,
            _ => counts.other += 1,
        }
    }
    counts
}

// --- Scoring --------------------------------------------------------------

/// Judge one recognizer's attempt at a page.
#[frb(sync)]
pub fn score_script_reading(reading: ScriptReading) -> ReadingScore {
    let text: String = reading
        .page
        .lines
        .iter()
        .map(|line| line.text.as_str())
        .collect::<Vec<_>>()
        .join(" ");
    let report = detect_script(text.clone());

    let visible: Vec<char> = text.chars().filter(|c| !c.is_whitespace()).collect();
    let characters = visible.len();
    let junk = visible.iter().filter(|c| !c.is_alphanumeric()).count();
    let junk_share = if characters == 0 {
        0.0
    } else {
        junk as f32 / characters as f32
    };

    let scored: Vec<f32> = reading
        .page
        .lines
        .iter()
        .filter_map(|line| line.effective_confidence())
        .collect();
    // A recognizer that reports nothing is not thereby confident. Treating an
    // absent score as certainty would let a silent model beat a candid one.
    let mean_confidence = if scored.is_empty() {
        0.75
    } else {
        scored.iter().sum::<f32>() / scored.len() as f32
    };

    let area = (reading.page.width * reading.page.height).max(1.0);
    let coverage = reading
        .page
        .lines
        .iter()
        .map(|line| ((line.right - line.left) * (line.bottom - line.top)).max(0.0))
        .sum::<f32>()
        / area;

    // Volume is the dominant term, because the difference between a model that
    // fits the page and one that does not is mostly *how much* it read. It is
    // taken as a square root so a page with twice the text does not count as
    // twice the evidence.
    let volume = (characters as f32).sqrt();
    // Reading the script the model was sent to find is corroboration; reading
    // some other script is not disqualifying, because the CJK models legitimately
    // read Latin too.
    let agreement = if report.script == reading.script {
        1.0
    } else if report.script == TextScript::Latin {
        0.8
    } else {
        0.45
    };
    let cleanliness = (1.0 - junk_share).max(0.05);
    let score = volume * agreement * cleanliness * mean_confidence;

    ReadingScore {
        script: reading.script,
        score,
        characters: i32::try_from(characters).unwrap_or(i32::MAX),
        mean_confidence,
        coverage,
        junk_share,
        dominant_script: report.script,
    }
}

/// Whether a reading looks like the wrong model was used.
///
/// This is the gate on the expensive path: only when the cheap Latin attempt
/// looks wrong is it worth running the other models over the same image.
#[frb(sync)]
pub fn reading_looks_wrong(score: ReadingScore) -> bool {
    let thin = (score.characters as usize) < MIN_PLAUSIBLE_CHARACTERS;
    let sparse = score.coverage < MIN_PLAUSIBLE_COVERAGE;
    let messy = score.junk_share >= JUNK_SHARE_SUSPECT;
    let unsure = score.mean_confidence < WEAK_CONFIDENCE;
    // A page that read cleanly in another script was plainly the wrong model,
    // however well it otherwise scored.
    let mismatched = score.dominant_script != TextScript::Unknown
        && score.dominant_script != score.script
        && score.dominant_script != TextScript::Latin;
    thin || sparse || messy || unsure || mismatched
}

/// Pick the best of several readings of the same page.
#[frb(sync)]
pub fn choose_script_reading(readings: Vec<ScriptReading>) -> ScriptChoice {
    let scores: Vec<ReadingScore> = readings.into_iter().map(score_script_reading).collect();
    if scores.is_empty() {
        return ScriptChoice {
            chosen: -1,
            script: TextScript::Unknown,
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

    // Hold on to Latin unless something beats it clearly, so a page of
    // ordinary English does not flip models between one scan and the next.
    let latin = scores
        .iter()
        .position(|score| score.script == TextScript::Latin);
    let mut reason = format!("{:?} read the page best", scores[best].script);
    if let Some(latin) = latin {
        if latin != best && scores[best].score < scores[latin].score * RIVAL_MARGIN {
            best = latin;
            reason = "no script read the page clearly better than Latin".to_owned();
        }
    }

    if scores[best].characters == 0 {
        return ScriptChoice {
            chosen: -1,
            script: TextScript::Unknown,
            scores,
            reason: "no reading found any text".to_owned(),
        };
    }

    ScriptChoice {
        chosen: i32::try_from(best).unwrap_or(-1),
        script: scores[best].script,
        scores,
        reason,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::ocr::OcrLineInput;

    fn line(text: &str, top: f32, width: f32, confidence: Option<f32>) -> OcrLineInput {
        OcrLineInput {
            text: text.to_owned(),
            left: 0.0,
            top,
            right: width,
            bottom: top + 30.0,
            block_index: 0,
            confidence,
            words: Vec::new(),
        }
    }

    fn page(lines: Vec<OcrLineInput>) -> OcrPageInput {
        OcrPageInput {
            lines,
            width: 1000.0,
            height: 1400.0,
        }
    }

    /// A page read well: plenty of text, wide boxes, confident.
    fn good_page(text: &str, confidence: f32) -> OcrPageInput {
        page(
            (0..8)
                .map(|index| line(text, index as f32 * 40.0, 800.0, Some(confidence)))
                .collect(),
        )
    }

    /// What the wrong model returns: a thin scatter of junk.
    fn junk_page() -> OcrPageInput {
        page(vec![
            line("|| .-", 0.0, 60.0, Some(0.3)),
            line("~ ^", 60.0, 40.0, Some(0.25)),
        ])
    }

    // --- Detection ---

    #[test]
    fn plain_english_is_latin() {
        let report = detect_script("The quick brown fox".to_owned());
        assert_eq!(report.script, TextScript::Latin);
        assert!(report.confidence > 0.9);
        assert!(report.recognizable);
    }

    #[test]
    fn any_kana_makes_a_page_japanese_however_much_kanji_it_has() {
        // Japanese prose is mostly kanji by volume, so counting the commonest
        // letter would call this Chinese. Kana is the giveaway: Chinese has none.
        let report = detect_script("日本語の文章です".to_owned());
        assert_eq!(report.script, TextScript::Japanese);
        assert!(report.recognizable);
    }

    #[test]
    fn han_with_no_kana_is_chinese() {
        let report = detect_script("中文文章的内容".to_owned());
        assert_eq!(report.script, TextScript::Chinese);
    }

    #[test]
    fn hangul_is_korean() {
        assert_eq!(
            detect_script("한국어 문장".to_owned()).script,
            TextScript::Korean
        );
    }

    #[test]
    fn devanagari_is_recognized_and_readable() {
        let report = detect_script("यह हिन्दी है".to_owned());
        assert_eq!(report.script, TextScript::Devanagari);
        assert!(report.recognizable);
    }

    #[test]
    fn scripts_with_no_on_device_model_are_named_but_flagged() {
        // Detectable so the app can say *why* it cannot read the page, rather
        // than returning the Latin model's guesses as if they were words.
        for (text, script) in [
            ("Привет мир", TextScript::Cyrillic),
            ("Ελληνικά", TextScript::Greek),
            ("مرحبا بالعالم", TextScript::Arabic),
            ("שלום עולם", TextScript::Hebrew),
            ("สวัสดี", TextScript::Thai),
        ] {
            let report = detect_script(text.to_owned());
            assert_eq!(report.script, script, "for {text}");
            assert!(!report.recognizable, "{script:?} has no on-device model");
        }
    }

    #[test]
    fn digits_and_punctuation_decide_nothing() {
        let report = detect_script("12:30 — 45.00 (99%)".to_owned());
        assert_eq!(report.script, TextScript::Unknown);
        assert_eq!(report.letters, 0);
    }

    #[test]
    fn empty_text_is_unknown_rather_than_latin() {
        let report = detect_script(String::new());
        assert_eq!(report.script, TextScript::Unknown);
        assert!(!report.recognizable);
    }

    #[test]
    fn a_stray_foreign_word_does_not_carry_the_page() {
        let report =
            detect_script("The restaurant was called 東京 and served good food".to_owned());
        assert_eq!(report.script, TextScript::Latin);
        assert!(report.confidence < 1.0);
    }

    // --- Scoring ---

    #[test]
    fn the_model_that_fits_the_page_scores_far_higher() {
        let choice = choose_script_reading(vec![
            // Latin shown a Japanese page: a thin scatter of marks.
            ScriptReading {
                script: TextScript::Latin,
                page: junk_page(),
            },
            ScriptReading {
                script: TextScript::Japanese,
                page: good_page("日本語の文章がここにあります", 0.93),
            },
        ]);
        assert_eq!(choice.script, TextScript::Japanese);
        assert_eq!(choice.chosen, 1);
    }

    #[test]
    fn an_english_page_stays_with_latin_even_when_another_model_reads_it() {
        // The CJK models read Latin too, so both come back with the text. A
        // near-tie must not move a page of English off the Latin model.
        let choice = choose_script_reading(vec![
            ScriptReading {
                script: TextScript::Latin,
                page: good_page("the quick brown fox jumps over", 0.9),
            },
            ScriptReading {
                script: TextScript::Japanese,
                page: good_page("the quick brown fox jumps over", 0.91),
            },
        ]);
        assert_eq!(choice.script, TextScript::Latin);
        assert!(choice.reason.contains("Latin"));
    }

    #[test]
    fn a_clearly_better_rival_does_win() {
        let choice = choose_script_reading(vec![
            ScriptReading {
                script: TextScript::Latin,
                page: page(vec![line("a b c", 0.0, 100.0, Some(0.6))]),
            },
            ScriptReading {
                script: TextScript::Korean,
                page: good_page("한국어 문장이 여기에 있습니다", 0.95),
            },
        ]);
        assert_eq!(choice.script, TextScript::Korean);
    }

    #[test]
    fn a_thin_junk_reading_is_recognized_as_the_wrong_model() {
        let score = score_script_reading(ScriptReading {
            script: TextScript::Latin,
            page: junk_page(),
        });
        assert!(reading_looks_wrong(score));
    }

    #[test]
    fn a_good_latin_reading_does_not_trigger_the_expensive_path() {
        let score = score_script_reading(ScriptReading {
            script: TextScript::Latin,
            page: good_page("an ordinary page of english prose", 0.94),
        });
        assert!(!reading_looks_wrong(score.clone()), "score was {score:?}");
    }

    #[test]
    fn latin_that_came_back_as_japanese_is_the_wrong_model() {
        // If the Latin model somehow returned kana, the page is not Latin.
        let score = score_script_reading(ScriptReading {
            script: TextScript::Latin,
            page: good_page("日本語の文章がここにあります", 0.9),
        });
        assert!(reading_looks_wrong(score));
    }

    #[test]
    fn a_silent_recognizer_does_not_beat_a_candid_one_on_confidence_alone() {
        // Absent confidences must not read as certainty.
        let silent = score_script_reading(ScriptReading {
            script: TextScript::Latin,
            page: good_page("some text here", 0.0),
        });
        let confident = score_script_reading(ScriptReading {
            script: TextScript::Latin,
            page: page(
                (0..8)
                    .map(|index| line("some text here", index as f32 * 40.0, 800.0, None))
                    .collect(),
            ),
        });
        assert!(confident.mean_confidence > silent.mean_confidence);
        assert!(confident.mean_confidence < 1.0);
    }

    #[test]
    fn choosing_between_nothing_is_not_a_choice() {
        let choice = choose_script_reading(Vec::new());
        assert_eq!(choice.chosen, -1);
        assert_eq!(choice.script, TextScript::Unknown);

        let empty = choose_script_reading(vec![ScriptReading {
            script: TextScript::Latin,
            page: page(Vec::new()),
        }]);
        assert_eq!(empty.chosen, -1);
    }

    #[test]
    fn every_reading_is_reported_so_a_choice_can_be_explained() {
        let choice = choose_script_reading(vec![
            ScriptReading {
                script: TextScript::Latin,
                page: junk_page(),
            },
            ScriptReading {
                script: TextScript::Chinese,
                page: good_page("中文文章的内容在这里", 0.9),
            },
        ]);
        assert_eq!(choice.scores.len(), 2);
        assert!(!choice.reason.is_empty());
        assert_eq!(choice.scores[1].dominant_script, TextScript::Chinese);
    }
}
