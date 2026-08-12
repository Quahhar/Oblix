/// Dart's `String.trim` whitespace set is Unicode `White_Space` plus U+FEFF.
/// Rust's `char::is_whitespace` covers `White_Space` but intentionally excludes
/// U+FEFF, so all Dart-oracle trim operations must use this predicate.
pub(crate) fn is_dart_trim_whitespace(character: char) -> bool {
    character.is_whitespace() || character == '\u{feff}'
}

pub(crate) fn dart_trim(value: &str) -> &str {
    value.trim_matches(is_dart_trim_whitespace)
}

pub(crate) fn dart_trim_start(value: &str) -> &str {
    value.trim_start_matches(is_dart_trim_whitespace)
}

pub(crate) fn dart_trim_end(value: &str) -> &str {
    value.trim_end_matches(is_dart_trim_whitespace)
}

/// Dart regular expressions follow ECMAScript. Its `\s` set differs from
/// `String.trim`: it includes U+FEFF but excludes U+0085 (NEXT LINE).
pub(crate) const DART_REGEXP_WHITESPACE_CLASS: &str = concat!(
    r"[\x{0009}-\x{000d}",
    r"\x{0020}\x{00a0}\x{1680}\x{2000}-\x{200a}",
    r"\x{2028}\x{2029}\x{202f}\x{205f}\x{3000}\x{feff}]",
);

pub(crate) fn is_dart_regexp_whitespace(character: char) -> bool {
    matches!(
        character,
        '\u{0009}'..='\u{000d}'
            | '\u{0020}'
            | '\u{00a0}'
            | '\u{1680}'
            | '\u{2000}'..='\u{200a}'
            | '\u{2028}'
            | '\u{2029}'
            | '\u{202f}'
            | '\u{205f}'
            | '\u{3000}'
            | '\u{feff}'
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn trim_matches_darts_bom_and_unicode_whitespace_semantics() {
        assert_eq!(dart_trim("\u{feff}\u{0085} value \u{feff}"), "value");
        assert_eq!(dart_trim_start("\u{feff}value\u{feff}"), "value\u{feff}");
        assert_eq!(dart_trim_end("\u{feff}value\u{feff}"), "\u{feff}value");
    }

    #[test]
    fn regexp_whitespace_includes_bom_but_not_next_line() {
        assert!(is_dart_regexp_whitespace('\u{feff}'));
        assert!(is_dart_regexp_whitespace('\u{2003}'));
        assert!(!is_dart_regexp_whitespace('\u{0085}'));
        assert!(!is_dart_regexp_whitespace('x'));
    }
}
