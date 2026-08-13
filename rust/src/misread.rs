//! Putting back characters the recognizer read as the wrong glyph.
//!
//! This is the one correction in the scanning surface that changes what the
//! page *says*. Everything else — deskewing, reading order, row merging,
//! preparing a better image — either moves text around or gets the model to
//! look again. Once the model has spoken, a `0` it read for an `O` stays a `0`
//! through every later pass, because nothing downstream has any reason to
//! doubt it.
//!
//! So the bar here is deliberately high, and it is not "this looks like it
//! might be a word". Guessing wrongly is worse than leaving a misread alone: a
//! visible `rnodem` tells the reader the scan was imperfect, while a confident
//! `modern` that the page never said is a quiet fabrication in their notes.
//!
//! Three rules keep it honest.
//!
//! **Only characters that are out of place.** A substitution is considered only
//! where a token is mostly letters and the character is a digit or a symbol, or
//! the token is mostly digits and the character is a letter. `jump5` has one
//! candidate position and `hello` has none, so ordinary text is not searched at
//! all, let alone changed.
//!
//! **Only into something the page or the language already knows.** A candidate
//! is accepted when it matches a word the recognizer read confidently elsewhere
//! in the same capture, or a word in the short common-word list below. The
//! page's own vocabulary is what carries this: a scanned document repeats its
//! own terms, so the name, the heading, and the jargon that a lexicon could
//! never hold are exactly what is available to repair against.
//!
//! **Only where the recognizer was unsure.** A line the model scored highly is
//! left alone whatever its shape, because at that point the model has better
//! evidence than this does — it saw the pixels.
//!
//! Multi-character confusions are deliberately absent. `rn` for `m` is the
//! classic OCR error, but `corner` and `comer` are both words and both readings
//! are supportable, so a rule that fires on lexicon membership would silently
//! rewrite correct text. Single out-of-place glyphs do not have that problem:
//! `corner` contains no digits to reconsider.

use std::collections::HashMap;

use crate::api::ocr::OcrPageInput;

/// Confidence at or above which the recognizer's reading stands whatever it
/// looks like. It saw the page; this did not.
const TRUSTED_CONFIDENCE: f32 = 0.85;

/// Most out-of-place characters one token may have before it is abandoned.
/// A token needing four corrections is not a word with a misread glyph, it is
/// a token the model did not read.
const MAX_REPAIR_POSITIONS: usize = 3;

/// Digits a mostly-numeric token needs before its stray letters are read as
/// digits without any lexicon to appeal to.
const MIN_DIGITS_FOR_NUMBER: usize = 2;

/// What each character might really have been, where the alternative belongs
/// to the other class. Only ever consulted for a character already found to be
/// out of place in its token.
const CONFUSIONS: &[(char, &[char])] = &[
    // A digit or symbol standing in for a letter.
    ('0', &['o', 'O', 'D']),
    ('1', &['l', 'I', 'i']),
    ('2', &['z', 'Z']),
    ('3', &['e', 'E']),
    ('4', &['A']),
    ('5', &['s', 'S']),
    ('6', &['b', 'G']),
    ('7', &['T']),
    ('8', &['B']),
    ('9', &['g', 'q']),
    ('|', &['l', 'I']),
    ('!', &['l', 'I']),
    ('$', &['s', 'S']),
    ('@', &['a']),
    ('(', &['c', 'C']),
    ('¢', &['c']),
    ('£', &['E']),
    ('°', &['o']),
    // A letter standing in for a digit.
    ('o', &['0']),
    ('O', &['0']),
    ('D', &['0']),
    ('l', &['1']),
    ('I', &['1']),
    ('i', &['1']),
    ('z', &['2']),
    ('Z', &['2']),
    ('e', &['3']),
    ('A', &['4']),
    ('s', &['5']),
    ('S', &['5']),
    ('b', &['6']),
    ('G', &['6']),
    ('T', &['7']),
    ('B', &['8']),
    ('g', &['9']),
    ('q', &['9']),
];

/// Frequent English words, sorted, searched by bisection.
///
/// Short and deliberately so. The page's own vocabulary does the real work —
/// it holds the proper nouns and the subject's jargon, which no list this size
/// could — and this exists for the short function words a sparse page may not
/// repeat: the `the` at the top of a two-line note that appears nowhere else.
const COMMON_WORDS: &[&str] = &[
    "a",
    "able",
    "about",
    "above",
    "accept",
    "account",
    "across",
    "act",
    "action",
    "add",
    "address",
    "after",
    "again",
    "against",
    "age",
    "ago",
    "agree",
    "air",
    "all",
    "allow",
    "almost",
    "alone",
    "along",
    "already",
    "also",
    "although",
    "always",
    "among",
    "amount",
    "and",
    "another",
    "answer",
    "any",
    "anyone",
    "anything",
    "appear",
    "apply",
    "april",
    "area",
    "argue",
    "arm",
    "around",
    "arrive",
    "art",
    "article",
    "as",
    "ask",
    "at",
    "august",
    "author",
    "available",
    "away",
    "back",
    "bad",
    "bank",
    "base",
    "be",
    "beautiful",
    "because",
    "become",
    "bed",
    "been",
    "before",
    "begin",
    "behind",
    "believe",
    "below",
    "best",
    "better",
    "between",
    "big",
    "bill",
    "black",
    "blue",
    "board",
    "body",
    "book",
    "born",
    "both",
    "box",
    "boy",
    "break",
    "bring",
    "brother",
    "build",
    "business",
    "but",
    "buy",
    "by",
    "call",
    "can",
    "car",
    "card",
    "care",
    "carry",
    "case",
    "cash",
    "catch",
    "cause",
    "cell",
    "center",
    "central",
    "century",
    "certain",
    "chance",
    "change",
    "charge",
    "check",
    "child",
    "choose",
    "church",
    "city",
    "claim",
    "class",
    "clear",
    "close",
    "code",
    "cold",
    "college",
    "color",
    "come",
    "common",
    "community",
    "company",
    "compare",
    "computer",
    "concern",
    "condition",
    "consider",
    "contact",
    "continue",
    "control",
    "cost",
    "could",
    "country",
    "county",
    "couple",
    "course",
    "court",
    "cover",
    "create",
    "cup",
    "current",
    "customer",
    "cut",
    "data",
    "date",
    "day",
    "deal",
    "death",
    "decade",
    "december",
    "decide",
    "deep",
    "degree",
    "deliver",
    "department",
    "describe",
    "design",
    "detail",
    "develop",
    "difference",
    "different",
    "difficult",
    "dinner",
    "direct",
    "discuss",
    "do",
    "doctor",
    "document",
    "dog",
    "dollar",
    "door",
    "down",
    "draw",
    "drive",
    "drop",
    "due",
    "during",
    "each",
    "early",
    "east",
    "easy",
    "eat",
    "economy",
    "edge",
    "education",
    "effect",
    "effort",
    "eight",
    "either",
    "else",
    "email",
    "employee",
    "end",
    "energy",
    "enough",
    "enter",
    "entire",
    "equal",
    "especially",
    "even",
    "evening",
    "event",
    "ever",
    "every",
    "everyone",
    "everything",
    "exactly",
    "example",
    "exist",
    "expect",
    "experience",
    "explain",
    "eye",
    "face",
    "fact",
    "fall",
    "family",
    "far",
    "fast",
    "father",
    "february",
    "federal",
    "feel",
    "few",
    "field",
    "figure",
    "file",
    "fill",
    "film",
    "final",
    "finally",
    "find",
    "fine",
    "finish",
    "fire",
    "firm",
    "first",
    "five",
    "floor",
    "focus",
    "follow",
    "food",
    "foot",
    "for",
    "force",
    "foreign",
    "form",
    "former",
    "forward",
    "four",
    "free",
    "friday",
    "friend",
    "from",
    "front",
    "full",
    "fund",
    "future",
    "game",
    "general",
    "get",
    "girl",
    "give",
    "glass",
    "go",
    "good",
    "govern",
    "government",
    "great",
    "green",
    "ground",
    "group",
    "grow",
    "growth",
    "guess",
    "gun",
    "guy",
    "hair",
    "half",
    "hand",
    "happen",
    "happy",
    "hard",
    "have",
    "he",
    "head",
    "health",
    "hear",
    "heart",
    "heavy",
    "help",
    "her",
    "here",
    "high",
    "him",
    "his",
    "history",
    "hit",
    "hold",
    "home",
    "hope",
    "hospital",
    "hot",
    "hotel",
    "hour",
    "house",
    "how",
    "however",
    "human",
    "hundred",
    "husband",
    "idea",
    "identify",
    "if",
    "image",
    "imagine",
    "impact",
    "important",
    "improve",
    "in",
    "include",
    "income",
    "increase",
    "indeed",
    "indicate",
    "individual",
    "industry",
    "information",
    "inside",
    "instead",
    "interest",
    "international",
    "interview",
    "into",
    "invoice",
    "involve",
    "issue",
    "it",
    "item",
    "its",
    "january",
    "job",
    "join",
    "july",
    "june",
    "just",
    "keep",
    "key",
    "kid",
    "kind",
    "kitchen",
    "know",
    "knowledge",
    "land",
    "language",
    "large",
    "last",
    "late",
    "later",
    "laugh",
    "law",
    "lawyer",
    "lay",
    "lead",
    "leader",
    "learn",
    "least",
    "leave",
    "left",
    "legal",
    "less",
    "let",
    "letter",
    "level",
    "lie",
    "life",
    "light",
    "like",
    "likely",
    "limit",
    "line",
    "list",
    "listen",
    "little",
    "live",
    "local",
    "long",
    "look",
    "lose",
    "loss",
    "lot",
    "love",
    "low",
    "machine",
    "magazine",
    "main",
    "maintain",
    "major",
    "make",
    "man",
    "manage",
    "management",
    "manager",
    "many",
    "march",
    "market",
    "marriage",
    "material",
    "matter",
    "may",
    "maybe",
    "me",
    "mean",
    "measure",
    "media",
    "medical",
    "meet",
    "meeting",
    "member",
    "memory",
    "mention",
    "message",
    "method",
    "middle",
    "might",
    "military",
    "million",
    "mind",
    "minute",
    "miss",
    "mission",
    "model",
    "modern",
    "moment",
    "monday",
    "money",
    "month",
    "more",
    "morning",
    "most",
    "mother",
    "move",
    "movement",
    "movie",
    "much",
    "music",
    "must",
    "my",
    "name",
    "nation",
    "national",
    "natural",
    "nature",
    "near",
    "nearly",
    "necessary",
    "need",
    "network",
    "never",
    "new",
    "news",
    "newspaper",
    "next",
    "nice",
    "night",
    "nine",
    "no",
    "none",
    "north",
    "not",
    "note",
    "nothing",
    "notice",
    "november",
    "now",
    "number",
    "occur",
    "october",
    "of",
    "off",
    "offer",
    "office",
    "officer",
    "official",
    "often",
    "oil",
    "ok",
    "old",
    "on",
    "once",
    "one",
    "only",
    "open",
    "operation",
    "opportunity",
    "option",
    "or",
    "order",
    "organization",
    "other",
    "our",
    "out",
    "outside",
    "over",
    "own",
    "page",
    "paper",
    "parent",
    "part",
    "particular",
    "partner",
    "party",
    "pass",
    "past",
    "pay",
    "payment",
    "peace",
    "people",
    "per",
    "perhaps",
    "period",
    "person",
    "personal",
    "phone",
    "pick",
    "picture",
    "piece",
    "place",
    "plan",
    "plant",
    "play",
    "please",
    "point",
    "police",
    "policy",
    "political",
    "poor",
    "popular",
    "population",
    "position",
    "positive",
    "possible",
    "post",
    "power",
    "practice",
    "prepare",
    "present",
    "president",
    "press",
    "pressure",
    "pretty",
    "prevent",
    "price",
    "print",
    "private",
    "probably",
    "problem",
    "process",
    "produce",
    "product",
    "professor",
    "program",
    "project",
    "property",
    "protect",
    "prove",
    "provide",
    "public",
    "pull",
    "purchase",
    "purpose",
    "push",
    "put",
    "quality",
    "question",
    "quickly",
    "quite",
    "race",
    "radio",
    "raise",
    "range",
    "rate",
    "rather",
    "reach",
    "read",
    "ready",
    "real",
    "reality",
    "realize",
    "really",
    "reason",
    "receive",
    "recent",
    "recently",
    "recognize",
    "record",
    "reduce",
    "reference",
    "reflect",
    "region",
    "relate",
    "relationship",
    "religious",
    "remain",
    "remember",
    "remove",
    "report",
    "represent",
    "republican",
    "require",
    "research",
    "resource",
    "respond",
    "response",
    "responsibility",
    "rest",
    "result",
    "return",
    "reveal",
    "rich",
    "right",
    "rise",
    "risk",
    "road",
    "rock",
    "role",
    "room",
    "rule",
    "run",
    "safe",
    "same",
    "saturday",
    "save",
    "say",
    "scene",
    "school",
    "science",
    "score",
    "sea",
    "season",
    "seat",
    "second",
    "section",
    "security",
    "see",
    "seek",
    "seem",
    "sell",
    "send",
    "senior",
    "sense",
    "separate",
    "september",
    "series",
    "serious",
    "serve",
    "service",
    "set",
    "seven",
    "several",
    "sex",
    "shake",
    "share",
    "she",
    "shipping",
    "shoot",
    "short",
    "shot",
    "should",
    "show",
    "side",
    "sign",
    "signature",
    "significant",
    "similar",
    "simple",
    "simply",
    "since",
    "sing",
    "single",
    "sister",
    "sit",
    "site",
    "situation",
    "six",
    "size",
    "skill",
    "small",
    "smile",
    "so",
    "social",
    "society",
    "soldier",
    "some",
    "somebody",
    "someone",
    "something",
    "sometimes",
    "son",
    "song",
    "soon",
    "sort",
    "sound",
    "source",
    "south",
    "space",
    "speak",
    "special",
    "specific",
    "speech",
    "spend",
    "sport",
    "spring",
    "staff",
    "stage",
    "stand",
    "standard",
    "star",
    "start",
    "state",
    "statement",
    "station",
    "stay",
    "step",
    "still",
    "stock",
    "stop",
    "store",
    "story",
    "strategy",
    "street",
    "strong",
    "structure",
    "student",
    "study",
    "stuff",
    "style",
    "subject",
    "success",
    "such",
    "suddenly",
    "suffer",
    "suggest",
    "summer",
    "sunday",
    "support",
    "sure",
    "surface",
    "system",
    "table",
    "take",
    "talk",
    "task",
    "tax",
    "teach",
    "teacher",
    "team",
    "technology",
    "telephone",
    "television",
    "tell",
    "ten",
    "tend",
    "term",
    "terms",
    "test",
    "than",
    "thank",
    "that",
    "the",
    "their",
    "them",
    "themselves",
    "then",
    "theory",
    "there",
    "these",
    "they",
    "thing",
    "think",
    "third",
    "this",
    "those",
    "though",
    "thought",
    "thousand",
    "three",
    "through",
    "throughout",
    "thursday",
    "thus",
    "time",
    "to",
    "today",
    "together",
    "tonight",
    "too",
    "top",
    "total",
    "toward",
    "town",
    "trade",
    "traditional",
    "training",
    "travel",
    "treat",
    "tree",
    "trial",
    "trip",
    "trouble",
    "true",
    "truth",
    "try",
    "tuesday",
    "turn",
    "two",
    "type",
    "under",
    "understand",
    "unit",
    "until",
    "up",
    "upon",
    "us",
    "use",
    "usually",
    "value",
    "various",
    "very",
    "victim",
    "view",
    "visit",
    "voice",
    "vote",
    "wait",
    "walk",
    "wall",
    "want",
    "war",
    "watch",
    "water",
    "way",
    "we",
    "wear",
    "wednesday",
    "week",
    "weight",
    "welcome",
    "well",
    "west",
    "what",
    "whatever",
    "when",
    "where",
    "whether",
    "which",
    "while",
    "white",
    "who",
    "whole",
    "whom",
    "whose",
    "why",
    "wide",
    "wife",
    "will",
    "win",
    "wind",
    "window",
    "wish",
    "with",
    "within",
    "without",
    "woman",
    "wonder",
    "word",
    "work",
    "worker",
    "world",
    "worry",
    "would",
    "write",
    "writer",
    "wrong",
    "yard",
    "yeah",
    "year",
    "yes",
    "yet",
    "you",
    "young",
    "your",
    "yourself",
];

/// Repair what can be repaired across a whole capture, and say how much was.
///
/// Takes every page at once because the vocabulary is the capture's, not the
/// page's: a term introduced on page one is exactly the evidence that repairs
/// its misreading on page seven.
pub(crate) fn repair_pages(pages: &mut [OcrPageInput]) -> usize {
    let vocabulary = vocabulary_of(pages);
    let mut repaired = 0usize;
    for page in pages.iter_mut() {
        for line in page.lines.iter_mut() {
            if line
                .effective_confidence()
                .is_some_and(|score| score >= TRUSTED_CONFIDENCE)
            {
                continue;
            }
            let (text, count) = repair_text(&line.text, &vocabulary);
            if count > 0 {
                line.text = text;
                repaired += count;
            }
        }
    }
    repaired
}

/// Words the capture read confidently, and how often each appeared.
///
/// Lines the recognizer doubted are left out on purpose. A vocabulary built
/// from the whole page would learn its own misreadings — `t0tal` seen twice
/// becomes evidence that `t0tal` is a word — and then decline to repair them.
fn vocabulary_of(pages: &[OcrPageInput]) -> HashMap<String, u32> {
    let mut vocabulary: HashMap<String, u32> = HashMap::new();
    for page in pages {
        for line in &page.lines {
            if line
                .effective_confidence()
                .is_some_and(|score| score < TRUSTED_CONFIDENCE)
            {
                continue;
            }
            for token in line.text.split_whitespace() {
                let core = strip_punctuation(token);
                if core.chars().count() < 2 || !reads_as_language(core) {
                    continue;
                }
                *vocabulary.entry(core.to_lowercase()).or_insert(0) += 1;
            }
        }
    }
    vocabulary
}

/// Repair each token of a line, keeping the spacing exactly as it was.
fn repair_text(text: &str, vocabulary: &HashMap<String, u32>) -> (String, usize) {
    let mut out = String::with_capacity(text.len());
    let mut token = String::new();
    let mut repaired = 0usize;
    for character in text.chars() {
        if character.is_whitespace() {
            if !token.is_empty() {
                repaired += usize::from(push_repaired(&mut out, &token, vocabulary));
                token.clear();
            }
            out.push(character);
        } else {
            token.push(character);
        }
    }
    if !token.is_empty() {
        repaired += usize::from(push_repaired(&mut out, &token, vocabulary));
    }
    (out, repaired)
}

fn push_repaired(out: &mut String, token: &str, vocabulary: &HashMap<String, u32>) -> bool {
    match repair_token(token, vocabulary) {
        Some(fixed) => {
            out.push_str(&fixed);
            true
        }
        None => {
            out.push_str(token);
            false
        }
    }
}

/// The repaired form of one token, or [`None`] to leave it exactly as read.
fn repair_token(token: &str, vocabulary: &HashMap<String, u32>) -> Option<String> {
    let core = strip_punctuation(token);
    let characters: Vec<char> = core.chars().collect();
    if characters.len() < 2 || reads_as_language(core) {
        return None;
    }

    let letters = characters.iter().filter(|c| c.is_alphabetic()).count();
    let digits = characters.iter().filter(|c| c.is_numeric()).count();
    let separators = characters
        .iter()
        .filter(|c| matches!(c, '.' | ',' | ':' | '/'))
        .count();
    let wants_letters = match letters.cmp(&digits) {
        std::cmp::Ordering::Greater => true,
        std::cmp::Ordering::Less => false,
        // An even split is usually a reference or a part number, which has no
        // intended reading to recover — except when the token is punctuated
        // the way quantities are. `1O.5O` is a price with two glyphs misread;
        // `AB12` is a code, and reading its letters as digits would invent one.
        std::cmp::Ordering::Equal if separators > 0 => false,
        std::cmp::Ordering::Equal => return None,
    };

    // Where the token disagrees with itself, and what could be there instead.
    let mut positions: Vec<(usize, &[char])> = Vec::new();
    for (index, character) in characters.iter().enumerate() {
        if is_wanted(*character, wants_letters) || is_joiner(*character) {
            continue;
        }
        let alternatives = CONFUSIONS
            .iter()
            .find(|(seen, _)| seen == character)
            .map(|(_, options)| *options)
            .unwrap_or(&[]);
        let usable: Vec<char> = alternatives
            .iter()
            .copied()
            .filter(|option| is_wanted(*option, wants_letters))
            .collect();
        if usable.is_empty() {
            // A character with no plausible reading in the class the token
            // wants. Whatever this token is, it is not one glyph away from a
            // word, so nothing here can help it.
            return None;
        }
        positions.push((index, alternatives));
        if positions.len() > MAX_REPAIR_POSITIONS {
            return None;
        }
    }
    if positions.is_empty() {
        return None;
    }

    let best = best_candidate(&characters, &positions, wants_letters, digits, vocabulary)?;
    // Put the repaired core back between the punctuation the token arrived
    // with, so a quoted or parenthesized word keeps its marks.
    let leading = token.len() - token.trim_start_matches(is_edge_punctuation).len();
    let trailing = token.len() - token.trim_end_matches(is_edge_punctuation).len();
    Some(format!(
        "{}{best}{}",
        &token[..leading],
        &token[token.len() - trailing..]
    ))
}

/// The highest-scoring supported reading of a token, or [`None`] when nothing
/// the page or the language knows fits.
fn best_candidate(
    characters: &[char],
    positions: &[(usize, &[char])],
    wants_letters: bool,
    digits: usize,
    vocabulary: &HashMap<String, u32>,
) -> Option<String> {
    // Every combination of leaving each position alone or replacing it with
    // one of its alternatives. Bounded by MAX_REPAIR_POSITIONS above.
    let mut combinations = 1usize;
    let usable: Vec<Vec<char>> = positions
        .iter()
        .map(|(_, alternatives)| {
            let options: Vec<char> = alternatives
                .iter()
                .copied()
                .filter(|option| is_wanted(*option, wants_letters))
                .collect();
            combinations = combinations.saturating_mul(options.len() + 1);
            options
        })
        .collect();

    let mut best: Option<(u32, usize, String)> = None;
    for combination in 0..combinations {
        let mut counter = combination;
        let mut candidate: Vec<char> = characters.to_vec();
        let mut substitutions = 0usize;
        for (slot, (index, _)) in positions.iter().enumerate() {
            let options = &usable[slot];
            let choice = counter % (options.len() + 1);
            counter /= options.len() + 1;
            if choice > 0 {
                candidate[*index] = options[choice - 1];
                substitutions += 1;
            }
        }
        if substitutions == 0 {
            continue;
        }
        let candidate: String = candidate.into_iter().collect();
        if !reads_as_language(&candidate) {
            continue;
        }
        let Some(support) = support_for(&candidate, wants_letters, digits, vocabulary) else {
            continue;
        };
        // Most supported first, then fewest changes, then alphabetical so the
        // same page always repairs to the same word.
        let ranking = (support, usize::MAX - substitutions, candidate);
        best = match best {
            Some(current) if current >= ranking => Some(current),
            _ => Some(ranking),
        };
    }
    best.map(|(_, _, candidate)| candidate)
}

/// How strongly the page or the language backs a reading, or [`None`] when
/// neither does and the repair must not be made.
fn support_for(
    candidate: &str,
    wants_letters: bool,
    digits: usize,
    vocabulary: &HashMap<String, u32>,
) -> Option<u32> {
    if !wants_letters {
        // A number has no lexicon to appeal to, and asking the page for one
        // would repair only the amounts that happen to repeat. The structure is
        // the evidence instead: several digits and a stray letter among them is
        // a number the model half-read, and the repaired form must be entirely
        // digits before it is believed.
        let all_digits = candidate
            .chars()
            .all(|c| c.is_numeric() || is_joiner(c) || is_edge_punctuation(c));
        return (all_digits && digits >= MIN_DIGITS_FOR_NUMBER).then_some(1);
    }
    let lowered = candidate.to_lowercase();
    // The page's own words count for more than the list: they are this
    // document's actual vocabulary, and they are why a surname or a product
    // code can be repaired at all.
    let seen = vocabulary.get(&lowered).copied().unwrap_or(0);
    let known = u32::from(COMMON_WORDS.binary_search(&lowered.as_str()).is_ok());
    let support = seen.saturating_mul(2) + known;
    (support > 0).then_some(support)
}

/// Whether a character belongs to the class the token is being read as.
fn is_wanted(character: char, wants_letters: bool) -> bool {
    if wants_letters {
        character.is_alphabetic()
    } else {
        character.is_numeric()
    }
}

/// Characters that sit inside a word without belonging to either class.
fn is_joiner(character: char) -> bool {
    matches!(character, '-' | '\'' | '’' | '.' | ',' | '/' | ':')
}

fn is_edge_punctuation(character: char) -> bool {
    matches!(
        character,
        '.' | ','
            | ';'
            | ':'
            | '!'
            | '?'
            | '"'
            | '\''
            | '('
            | ')'
            | '['
            | ']'
            | '“'
            | '”'
            | '‘'
            | '’'
    )
}

fn strip_punctuation(token: &str) -> &str {
    token.trim_matches(is_edge_punctuation)
}

/// Whether a token reads as a word or as a number, which is the test for
/// "nothing here needs repairing".
fn reads_as_language(token: &str) -> bool {
    let core: Vec<char> = token.chars().filter(|c| !is_edge_punctuation(*c)).collect();
    if core.is_empty() {
        return false;
    }
    let letters = core.iter().filter(|c| c.is_alphabetic()).count();
    let digits = core.iter().filter(|c| c.is_numeric()).count();
    let joiners = core.iter().filter(|c| is_joiner(**c)).count();
    letters + joiners == core.len() || digits + joiners == core.len()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::ocr::{OcrLineInput, OcrPageInput};

    fn line(text: &str, confidence: Option<f32>) -> OcrLineInput {
        OcrLineInput {
            text: text.to_owned(),
            left: 0.0,
            top: 0.0,
            right: 400.0,
            bottom: 20.0,
            block_index: 0,
            confidence,
            words: Vec::new(),
        }
    }

    fn repaired(lines: Vec<OcrLineInput>) -> (String, usize) {
        let mut pages = vec![OcrPageInput {
            lines,
            width: 1000.0,
            height: 1400.0,
        }];
        let count = repair_pages(&mut pages);
        let text = pages[0]
            .lines
            .iter()
            .map(|line| line.text.as_str())
            .collect::<Vec<_>>()
            .join("\n");
        (text, count)
    }

    #[test]
    fn the_word_list_is_sorted_so_it_can_be_searched() {
        // A binary search over an unsorted list fails silently — it would just
        // stop repairing, which no other test would notice.
        assert!(
            COMMON_WORDS.windows(2).all(|pair| pair[0] < pair[1]),
            "first out of order: {:?}",
            COMMON_WORDS
                .windows(2)
                .find(|pair| pair[0] >= pair[1])
                .unwrap()
        );
    }

    #[test]
    fn a_digit_read_for_a_letter_is_put_back_from_the_common_words() {
        let (text, count) = repaired(vec![line("please check the t0tal am0unt", None)]);
        assert_eq!(text, "please check the total amount");
        assert_eq!(count, 2);
    }

    #[test]
    fn the_pages_own_vocabulary_repairs_what_no_word_list_could() {
        // "Kowalski" is in no lexicon. It is on the page, confidently, which is
        // the whole argument for reading the misspelling as the same name.
        let (text, count) = repaired(vec![
            line("Invoice for Kowalski Holdings", Some(0.97)),
            line("attention: K0walski", Some(0.4)),
        ]);
        assert!(text.ends_with("attention: Kowalski"), "read as {text}");
        assert_eq!(count, 1);
    }

    #[test]
    fn a_token_nothing_supports_is_left_exactly_as_read() {
        // Better a visible misread than a confident invention.
        let (text, count) = repaired(vec![line("zx9qv m7kzp", None)]);
        assert_eq!(text, "zx9qv m7kzp");
        assert_eq!(count, 0);
    }

    #[test]
    fn a_line_the_recognizer_was_sure_of_is_never_second_guessed() {
        // The model saw the pixels. At high confidence its reading wins even
        // where the shape looks wrong — this may really be a product code.
        let (text, count) = repaired(vec![line("the qu1ck brown f0x", Some(0.96))]);
        assert_eq!(text, "the qu1ck brown f0x");
        assert_eq!(count, 0);
    }

    #[test]
    fn a_misread_number_is_repaired_on_its_structure_alone() {
        let (text, count) = repaired(vec![line("total 1O.5O", None)]);
        assert_eq!(text, "total 10.50");
        assert_eq!(count, 1);
    }

    #[test]
    fn punctuation_around_a_repaired_word_is_kept() {
        let (text, count) = repaired(vec![line("(rep0rt),", None)]);
        assert_eq!(text, "(report),");
        assert_eq!(count, 1);
    }

    #[test]
    fn spacing_is_preserved_exactly() {
        // Receipts and code are read with their line breaks kept, so a repair
        // must not quietly re-space the line it touched.
        let (text, _) = repaired(vec![line("  the   t0tal  ", None)]);
        assert_eq!(text, "  the   total  ");
    }

    #[test]
    fn ordinary_text_is_never_touched() {
        let original = "The quick brown fox jumps over the lazy dog in 2024.";
        let (text, count) = repaired(vec![line(original, None)]);
        assert_eq!(text, original);
        assert_eq!(count, 0);
    }

    #[test]
    fn a_code_with_no_majority_class_is_left_alone() {
        // Half letters, half digits: there is no reading to prefer, and a
        // reference number is exactly what this shape usually is.
        let (text, count) = repaired(vec![line("AB12 X9Y2", None)]);
        assert_eq!(text, "AB12 X9Y2");
        assert_eq!(count, 0);
    }

    #[test]
    fn a_vocabulary_does_not_learn_from_the_lines_it_should_be_repairing() {
        // The same misreading twice is not evidence that it is a word. Both
        // lines are doubtful, so neither teaches the other.
        let (text, count) = repaired(vec![line("t0tal", Some(0.3)), line("t0tal", Some(0.3))]);
        assert_eq!(text, "total\ntotal");
        assert_eq!(count, 2);
    }

    #[test]
    fn a_token_too_far_gone_is_not_rebuilt_word_by_word() {
        let (text, count) = repaired(vec![line("t0t4l5", None)]);
        assert_eq!(text, "t0t4l5");
        assert_eq!(count, 0);
    }
}
