//! Decoding chores shared by both mail parsers: charsets, the two MIME
//! content-transfer encodings, RFC 2047 header words, and dates.

use base64::engine::general_purpose::STANDARD;
use base64::Engine as _;

/// Bytes in `charset` as a Rust string, never failing.
///
/// A mail file is a historical artefact: the charset label is often absent,
/// often wrong, and occasionally a charset nobody has shipped in twenty years.
/// `encoding_rs` maps every label it knows and substitutes U+FFFD for what
/// doesn't decode, which is the right trade for a preview — showing the message
/// with a few broken glyphs beats refusing to show it.
pub fn decode_charset(bytes: &[u8], charset: &str) -> String {
    let label = charset.trim().trim_matches('"');
    let encoding = if label.is_empty() {
        // No label. UTF-8 if it is valid UTF-8, otherwise windows-1252, which
        // is what unlabelled western mail almost always turns out to be and is
        // a superset of the latin-1 the RFC nominally specifies.
        match std::str::from_utf8(bytes) {
            Ok(s) => return s.to_string(),
            Err(_) => encoding_rs::WINDOWS_1252,
        }
    } else {
        encoding_rs::Encoding::for_label(label.as_bytes()).unwrap_or(encoding_rs::UTF_8)
    };
    let (text, _, _) = encoding.decode(bytes);
    text.into_owned()
}

/// Quoted-printable, per RFC 2045 §6.7.
///
/// `underscores_as_spaces` is the one difference between the body encoding and
/// the `=?…?Q?…?=` header variant, so both share this.
pub fn decode_quoted_printable(input: &[u8], underscores_as_spaces: bool) -> Vec<u8> {
    let mut out = Vec::with_capacity(input.len());
    let mut i = 0;
    while i < input.len() {
        let byte = input[i];
        match byte {
            b'=' => {
                // A soft line break: `=` at end of line, swallowing the CRLF.
                if i + 1 < input.len() && (input[i + 1] == b'\n' || input[i + 1] == b'\r') {
                    i += 1;
                    if input[i] == b'\r' && i + 1 < input.len() && input[i + 1] == b'\n' {
                        i += 1;
                    }
                    i += 1;
                    continue;
                }
                if i + 2 < input.len() {
                    if let (Some(hi), Some(lo)) =
                        (hex_val(input[i + 1]), hex_val(input[i + 2]))
                    {
                        out.push(hi << 4 | lo);
                        i += 3;
                        continue;
                    }
                }
                // Malformed: keep the `=` rather than dropping content.
                out.push(byte);
                i += 1;
            }
            b'_' if underscores_as_spaces => {
                out.push(b' ');
                i += 1;
            }
            _ => {
                out.push(byte);
                i += 1;
            }
        }
    }
    out
}

fn hex_val(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

/// Base64, ignoring the line breaks and stray whitespace real mail contains.
pub fn decode_base64(input: &[u8]) -> Vec<u8> {
    let cleaned: Vec<u8> = input
        .iter()
        .copied()
        .filter(|b| !b.is_ascii_whitespace())
        .collect();
    // Some senders omit padding; decoding the longest valid prefix beats
    // returning nothing, so retry without the trailing partial quantum.
    STANDARD
        .decode(&cleaned)
        .or_else(|_| {
            let usable = cleaned.len() - cleaned.len() % 4;
            STANDARD.decode(&cleaned[..usable])
        })
        .unwrap_or_default()
}

/// Expands every `=?charset?B|Q?text?=` word in a header value (RFC 2047).
///
/// Adjacent encoded words separated only by whitespace are joined without it,
/// as the RFC requires — that is what lets a long subject be split mid-word
/// across two lines and still read correctly.
pub fn decode_encoded_words(input: &str) -> String {
    if !input.contains("=?") {
        return input.to_string();
    }
    let bytes = input.as_bytes();
    let mut out = String::with_capacity(input.len());
    let mut i = 0;
    let mut last_was_encoded = false;
    // Whitespace held back until we know whether the next token is another
    // encoded word (drop it) or ordinary text (keep it).
    let mut pending_space = String::new();

    while i < bytes.len() {
        if bytes[i] == b'=' && i + 1 < bytes.len() && bytes[i + 1] == b'?' {
            if let Some((decoded, next)) = parse_encoded_word(input, i) {
                if !last_was_encoded {
                    out.push_str(&pending_space);
                }
                pending_space.clear();
                out.push_str(&decoded);
                last_was_encoded = true;
                i = next;
                continue;
            }
        }
        let ch = input[i..].chars().next().unwrap_or(' ');
        let len = ch.len_utf8();
        if ch.is_whitespace() {
            pending_space.push(ch);
        } else {
            out.push_str(&pending_space);
            pending_space.clear();
            out.push(ch);
            last_was_encoded = false;
        }
        i += len;
    }
    out.push_str(&pending_space);
    out
}

/// Decodes the encoded word starting at `start`, returning it and the index
/// just past the closing `?=`.
fn parse_encoded_word(input: &str, start: usize) -> Option<(String, usize)> {
    let rest = &input[start + 2..];
    let end = rest.find("?=")?;
    let inner = &rest[..end];
    // charset[*language]?encoding?text
    let mut parts = inner.splitn(3, '?');
    let charset_full = parts.next()?;
    let encoding = parts.next()?;
    let text = parts.next()?;
    if text.contains('?') {
        // The `?=` we found was inside the payload; not a word we can trust.
        return None;
    }
    let charset = charset_full.split('*').next().unwrap_or(charset_full);
    let raw = match encoding.as_bytes().first()?.to_ascii_uppercase() {
        b'B' => decode_base64(text.as_bytes()),
        b'Q' => decode_quoted_printable(text.as_bytes(), true),
        _ => return None,
    };
    Some((decode_charset(&raw, charset), start + 2 + end + 2))
}

/// Milliseconds since the epoch for an RFC 5322 `Date` header.
///
/// Written by hand rather than pulled from a date crate: the only thing needed
/// is one number for sorting and display, and mail dates are a small, fixed
/// grammar. Returns 0 when the header is missing or unparseable, which the UI
/// reads as "show the raw string only".
pub fn parse_rfc5322_date(input: &str) -> i64 {
    let cleaned = input
        .split(&['(', ')'][..])
        .next()
        .unwrap_or(input)
        .trim();
    let mut tokens: Vec<&str> = cleaned.split_whitespace().collect();
    if tokens.is_empty() {
        return 0;
    }
    // Optional day-of-week, e.g. "Tue,".
    if tokens[0].ends_with(',') || tokens[0].len() == 3 && tokens[0].parse::<u32>().is_err() {
        if tokens[0].trim_end_matches(',').len() == 3
            && MONTHS
                .iter()
                .all(|m| !m.eq_ignore_ascii_case(tokens[0].trim_end_matches(',')))
        {
            tokens.remove(0);
        }
    }
    if tokens.len() < 4 {
        return 0;
    }
    let day: i64 = tokens[0].trim_end_matches(',').parse().unwrap_or(0);
    let month = MONTHS
        .iter()
        .position(|m| m.eq_ignore_ascii_case(tokens[1]))
        .map(|p| p as i64 + 1)
        .unwrap_or(0);
    if day == 0 || month == 0 {
        return 0;
    }
    let mut year: i64 = tokens[2].parse().unwrap_or(0);
    if year == 0 {
        return 0;
    }
    // Two-digit years, per RFC 5322 §4.3.
    if year < 50 {
        year += 2000;
    } else if year < 1000 {
        year += 1900;
    }

    let mut hms = tokens[3].split(':');
    let hour: i64 = hms.next().and_then(|v| v.parse().ok()).unwrap_or(0);
    let minute: i64 = hms.next().and_then(|v| v.parse().ok()).unwrap_or(0);
    let second: i64 = hms.next().and_then(|v| v.parse().ok()).unwrap_or(0);

    let offset_minutes = tokens.get(4).map(|z| parse_zone(z)).unwrap_or(0);

    let days = days_from_civil(year, month, day);
    (days * 86_400 + hour * 3_600 + minute * 60 + second - offset_minutes * 60) * 1000
}

const MONTHS: [&str; 12] = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
];

fn parse_zone(zone: &str) -> i64 {
    let z = zone.trim();
    if let Some(rest) = z.strip_prefix('+').or_else(|| z.strip_prefix('-')) {
        if rest.len() >= 4 {
            let hours: i64 = rest[..2].parse().unwrap_or(0);
            let minutes: i64 = rest[2..4].parse().unwrap_or(0);
            let total = hours * 60 + minutes;
            return if z.starts_with('-') { -total } else { total };
        }
        return 0;
    }
    // The obsolete alphabetic zones. "UT"/"GMT"/"Z" and the US ones are the
    // only ones still seen in the wild.
    match z.to_ascii_uppercase().as_str() {
        "UT" | "GMT" | "UTC" | "Z" => 0,
        "EST" => -300,
        "EDT" => -240,
        "CST" => -360,
        "CDT" => -300,
        "MST" => -420,
        "MDT" => -360,
        "PST" => -480,
        "PDT" => -420,
        _ => 0,
    }
}

/// Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's
/// `days_from_civil`).
fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let y = if month <= 2 { year - 1 } else { year };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let mp = (month + 9) % 12;
    let doy = (153 * mp + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// A readable plain-text rendering of an HTML body, for messages that ship no
/// `text/plain` alternative.
///
/// Not a browser: it drops script and style, turns block ends into newlines,
/// expands the handful of entities that matter, and collapses the rest. The
/// result is what the "Plain text" tab shows when there is nothing better.
pub fn html_to_text(html: &str) -> String {
    let mut out = String::with_capacity(html.len() / 2);
    let bytes = html.as_bytes();
    let mut i = 0;
    let mut skip_until: Option<&str> = None;

    while i < bytes.len() {
        if bytes[i] == b'<' {
            let Some(close) = html[i..].find('>') else { break };
            let tag_body = &html[i + 1..i + close];
            let name = tag_body
                .trim_start_matches('/')
                .split(|c: char| c.is_whitespace() || c == '>' || c == '/')
                .next()
                .unwrap_or("")
                .to_ascii_lowercase();

            if let Some(pending) = skip_until {
                if tag_body.starts_with('/') && name == pending {
                    skip_until = None;
                }
            } else if name == "script" || name == "style" || name == "head" {
                if !tag_body.starts_with('/') {
                    skip_until = Some(if name == "script" {
                        "script"
                    } else if name == "style" {
                        "style"
                    } else {
                        "head"
                    });
                }
            } else if matches!(
                name.as_str(),
                "p" | "div" | "br" | "tr" | "li" | "h1" | "h2" | "h3" | "h4" | "h5"
                    | "h6" | "blockquote" | "table" | "ul" | "ol" | "pre" | "hr"
            ) {
                out.push('\n');
            } else if name == "td" || name == "th" {
                out.push('\t');
            }
            i += close + 1;
            continue;
        }
        if skip_until.is_some() {
            i += 1;
            continue;
        }
        if bytes[i] == b'&' {
            if let Some(semi) = html[i..].find(';') {
                if semi <= 10 {
                    out.push_str(&decode_entity(&html[i + 1..i + semi]));
                    i += semi + 1;
                    continue;
                }
            }
        }
        let ch = html[i..].chars().next().unwrap_or(' ');
        out.push(ch);
        i += ch.len_utf8();
    }
    collapse_blank_lines(&out)
}

fn decode_entity(name: &str) -> String {
    match name {
        "nbsp" => " ".into(),
        "amp" => "&".into(),
        "lt" => "<".into(),
        "gt" => ">".into(),
        "quot" => "\"".into(),
        "apos" | "#39" => "'".into(),
        "mdash" => "—".into(),
        "ndash" => "–".into(),
        "hellip" => "…".into(),
        "rsquo" => "’".into(),
        "lsquo" => "‘".into(),
        "ldquo" => "“".into(),
        "rdquo" => "”".into(),
        other => {
            let code = if let Some(hex) = other
                .strip_prefix("#x")
                .or_else(|| other.strip_prefix("#X"))
            {
                u32::from_str_radix(hex, 16).ok()
            } else {
                other.strip_prefix('#').and_then(|d| d.parse::<u32>().ok())
            };
            match code.and_then(char::from_u32) {
                Some(c) => c.to_string(),
                // Unknown entity: put it back verbatim rather than eating it.
                None => format!("&{name};"),
            }
        }
    }
}

/// Trims trailing spaces and squeezes runs of blank lines down to one, which
/// is what turns tag-per-line HTML into something readable.
pub fn collapse_blank_lines(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    let mut blanks = 0;
    for line in input.replace("\r\n", "\n").split('\n') {
        let trimmed = line.trim_end();
        if trimmed.trim().is_empty() {
            blanks += 1;
            if blanks > 1 {
                continue;
            }
            out.push('\n');
        } else {
            blanks = 0;
            out.push_str(trimmed);
            out.push('\n');
        }
    }
    out.trim_matches('\n').to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn joins_adjacent_encoded_words_without_the_separating_space() {
        // RFC 2047 §6.2: a long word split across two encoded words must
        // rejoin seamlessly.
        let input = "=?utf-8?Q?Hello_?= =?utf-8?Q?world?=";
        assert_eq!(decode_encoded_words(input), "Hello world");
    }

    #[test]
    fn keeps_spaces_around_unencoded_text() {
        let input = "Re: =?utf-8?B?w6l0w6k=?= plans";
        assert_eq!(decode_encoded_words(input), "Re: été plans");
    }

    #[test]
    fn quoted_printable_swallows_soft_breaks() {
        let out = decode_quoted_printable(b"caf=C3=A9 au=\r\n lait", false);
        assert_eq!(String::from_utf8(out).unwrap(), "café au lait");
    }

    #[test]
    fn parses_a_date_with_an_offset() {
        // 2024-03-05T09:30:00+0100 == 2024-03-05T08:30:00Z == 1709627400s.
        let ms = parse_rfc5322_date("Tue, 5 Mar 2024 09:30:00 +0100");
        assert_eq!(ms, 1_709_627_400_000);
    }

    #[test]
    fn unknown_dates_are_zero_not_a_wrong_guess() {
        assert_eq!(parse_rfc5322_date("whenever"), 0);
        assert_eq!(parse_rfc5322_date(""), 0);
    }

    #[test]
    fn html_to_text_drops_style_blocks() {
        let text = html_to_text("<style>p{color:red}</style><p>Hi</p><p>There</p>");
        assert_eq!(text, "Hi\n\nThere", "each <p> should read as its own paragraph");
    }
}
