//! Outlook's compressed RTF body, and what to do with it once decompressed.
//!
//! A `.msg` often carries its body only as `PR_RTF_COMPRESSED`. That stream is
//! LZFu ([MS-OXRTFCP]) around an RTF document which, when the message
//! originated as HTML, has the HTML *encapsulated* inside it ([MS-OXRTFEX]) —
//! the original markup is recoverable rather than merely approximable, which is
//! why this is worth doing properly instead of falling back to plain text.

use super::text::decode_charset;

/// Undoes the LZFu compression in a `PR_RTF_COMPRESSED` stream.
///
/// The dictionary starts pre-filled with the fixed 207-byte preamble below,
/// which is what makes the format's tiny window enough for RTF: every document
/// begins with almost exactly these bytes, so the first hundred are all
/// back-references.
pub fn decompress(input: &[u8]) -> Result<Vec<u8>, String> {
    const INIT: &[u8] = b"{\\rtf1\\ansi\\mac\\deff0\\deftab720{\\fonttbl;}{\\f0\\fnil \\froman \\fswiss \\fmodern \\fscript \\fdecor MS Sans SerifSymbolArialTimes New RomanCourier{\\colortbl\\red0\\green0\\blue0\r\n\\par \\pard\\plain\\f0\\fs20\\b\\i\\u\\tab\\tx";
    const DICT_SIZE: usize = 4096;

    if input.len() < 16 {
        return Err("The RTF body is too short to be a compressed stream.".into());
    }
    let comp_size = u32::from_le_bytes([input[0], input[1], input[2], input[3]]) as usize;
    let raw_size = u32::from_le_bytes([input[4], input[5], input[6], input[7]]) as usize;
    let magic = u32::from_le_bytes([input[8], input[9], input[10], input[11]]);

    // "MELA" — stored uncompressed, which small bodies often are.
    if magic == 0x414C_454D {
        return Ok(input[16..].to_vec());
    }
    // "LZFu"
    if magic != 0x7546_5A4C {
        return Err("Unrecognised RTF compression.".into());
    }

    // `comp_size` counts everything after itself. Trust it only as far as the
    // buffer actually goes.
    let end = (comp_size + 4).min(input.len());
    let body = &input[16..end.max(16)];

    let mut dict = [0u8; DICT_SIZE];
    dict[..INIT.len()].copy_from_slice(INIT);
    let mut write_at = INIT.len();

    // `raw_size` is a hint for the allocation, not a bound to enforce: a
    // truncated stream should still yield the part that did arrive.
    let mut out = Vec::with_capacity(raw_size.min(16 * 1024 * 1024));
    let mut i = 0;

    while i < body.len() {
        let control = body[i];
        i += 1;
        for bit in 0..8 {
            if i >= body.len() {
                return Ok(out);
            }
            if control & (1 << bit) == 0 {
                let byte = body[i];
                i += 1;
                out.push(byte);
                dict[write_at] = byte;
                write_at = (write_at + 1) % DICT_SIZE;
                continue;
            }
            if i + 1 >= body.len() {
                return Ok(out);
            }
            let hi = body[i] as usize;
            let lo = body[i + 1] as usize;
            i += 2;
            let offset = (hi << 4) | (lo >> 4);
            let length = (lo & 0x0F) + 2;
            // The reference that points at the write cursor is the end marker.
            if offset == write_at {
                return Ok(out);
            }
            for n in 0..length {
                let byte = dict[(offset + n) % DICT_SIZE];
                out.push(byte);
                dict[write_at] = byte;
                write_at = (write_at + 1) % DICT_SIZE;
            }
        }
    }
    Ok(out)
}

/// True when this RTF is an HTML message wearing an RTF coat.
pub fn is_encapsulated_html(rtf: &str) -> bool {
    rtf.contains("\\fromhtml1") || rtf.contains("\\fromhtml ")
}

/// What is in force inside the current RTF group.
///
/// RTF scopes formatting to groups: `{` saves the state and `}` restores it.
/// Both readers below therefore keep a stack rather than plain flags, which is
/// what makes an `\htmlrtf` inside a nested group stop applying when that group
/// closes — the case a flag gets wrong and that turns leaked `\fs22` runs into
/// visible text.
#[derive(Clone, Copy)]
struct Scope {
    /// Inside `\htmlrtf` … `\htmlrtf0`: content meant for an RTF reader, which
    /// the HTML recovered here must not include.
    htmlrtf: bool,
    /// Inside a destination whose contents are metadata.
    skip: bool,
    /// Inside `\*\htmltagN`, whose text is literal HTML markup.
    htmltag: bool,
}

impl Scope {
    const ROOT: Scope = Scope {
        htmlrtf: false,
        skip: false,
        htmltag: false,
    };
}

/// Shared scanning state for both RTF readers.
struct Reader {
    stack: Vec<Scope>,
    scope: Scope,
    codepage: String,
    /// Bytes of a `\'xx` run, buffered so a multi-byte character in a DBCS
    /// codepage decodes as one character rather than two replacements.
    pending: Vec<u8>,
    /// How many characters follow a `\uN` that are its ANSI fallback.
    unicode_skip: usize,
    skip_chars: usize,
    out: String,
}

impl Reader {
    fn new(capacity: usize) -> Self {
        Reader {
            stack: Vec::new(),
            scope: Scope::ROOT,
            codepage: "windows-1252".into(),
            pending: Vec::new(),
            unicode_skip: 1,
            skip_chars: 0,
            out: String::with_capacity(capacity),
        }
    }

    fn flush(&mut self) {
        if !self.pending.is_empty() {
            let text = decode_charset(&self.pending, &self.codepage);
            self.out.push_str(&text);
            self.pending.clear();
        }
    }

    fn open_group(&mut self) {
        self.flush();
        self.stack.push(self.scope);
        // `\htmltag` applies to the group it introduces, not to nested ones.
        self.scope.htmltag = false;
    }

    fn close_group(&mut self) {
        self.flush();
        self.scope = self.stack.pop().unwrap_or(Scope::ROOT);
    }

    fn push_char(&mut self, ch: char) {
        self.flush();
        self.out.push(ch);
    }
}

/// Recovers the original HTML from encapsulated RTF ([MS-OXRTFEX]).
///
/// Two things carry the markup. `\*\htmltagN` destinations hold literal HTML
/// tags, and the ordinary RTF text between them is the document's text content.
/// Everything the RTF writer added for its own benefit sits between `\htmlrtf`
/// and `\htmlrtf0` and must be skipped — that toggle is the whole trick.
pub fn deencapsulate_html(rtf: &str) -> String {
    let bytes = rtf.as_bytes();
    let mut r = Reader::new(rtf.len());
    let mut i = 0;

    while i < bytes.len() {
        match bytes[i] {
            b'{' => {
                r.open_group();
                i += 1;
            }
            b'}' => {
                r.close_group();
                i += 1;
            }
            b'\\' => {
                let (word, param, next) = read_control(bytes, i);
                i = next;
                // Inside an `\htmltag` destination the RTF writer's own state
                // doesn't apply: the group is pure markup.
                let visible = !r.scope.skip && (r.scope.htmltag || !r.scope.htmlrtf);
                match word.as_str() {
                    "" => {
                        if visible {
                            if let Some(c) = param.chars().next() {
                                r.pending.push(c as u8);
                            }
                        }
                    }
                    "'" => {
                        if visible {
                            if r.skip_chars > 0 {
                                r.skip_chars -= 1;
                            } else if let Ok(b) = u8::from_str_radix(&param, 16) {
                                r.pending.push(b);
                            }
                        }
                    }
                    "u" => {
                        r.flush();
                        if visible {
                            if let Some(c) = unicode_char(&param) {
                                r.out.push(c);
                            }
                        }
                        r.skip_chars = r.unicode_skip;
                    }
                    "uc" => r.unicode_skip = param.parse().unwrap_or(1),
                    "ansicpg" => {
                        if let Ok(cp) = param.parse::<u32>() {
                            r.codepage = codepage_label(cp);
                        }
                    }
                    "htmlrtf" => {
                        r.flush();
                        r.scope.htmlrtf = param != "0";
                    }
                    "htmltag" => {
                        r.flush();
                        r.scope.htmltag = true;
                    }
                    // `\par` and `\tab` inside encapsulated HTML are the RTF
                    // rendering of markup that is already present as tags, so
                    // they only contribute whitespace.
                    "par" | "line" => {
                        if visible {
                            r.push_char('\n');
                        } else {
                            r.flush();
                        }
                    }
                    "tab" => {
                        if visible {
                            r.push_char('\t');
                        } else {
                            r.flush();
                        }
                    }
                    "*" => {
                        // An optional destination. `\*\htmltag` is markup;
                        // everything else is for the RTF reader alone.
                        let (inner, _, after) = read_control(bytes, i);
                        if inner != "htmltag" {
                            r.scope.skip = true;
                            i = after;
                        }
                    }
                    other => {
                        if let Some(c) = symbol_word(other) {
                            if visible {
                                r.push_char(c);
                            } else {
                                r.flush();
                            }
                        } else {
                            if is_ignored_destination(other) {
                                r.scope.skip = true;
                            }
                            r.flush();
                        }
                    }
                }
            }
            b'\r' | b'\n' => i += 1,
            _ => {
                if !r.scope.skip && (r.scope.htmltag || !r.scope.htmlrtf) {
                    if r.skip_chars > 0 {
                        r.skip_chars -= 1;
                    } else {
                        r.pending.push(bytes[i]);
                    }
                }
                i += 1;
            }
        }
    }
    r.flush();
    r.out
}

/// A plain-text rendering of ordinary (non-encapsulated) RTF.
///
/// Enough to read a message: text, paragraph breaks, escapes and Unicode
/// characters, with the font, colour and style tables discarded.
pub fn rtf_to_text(rtf: &str) -> String {
    let bytes = rtf.as_bytes();
    let mut r = Reader::new(rtf.len() / 2);
    let mut i = 0;

    while i < bytes.len() {
        match bytes[i] {
            b'{' => {
                r.open_group();
                i += 1;
            }
            b'}' => {
                r.close_group();
                i += 1;
            }
            b'\\' => {
                let (word, param, next) = read_control(bytes, i);
                i = next;
                let visible = !r.scope.skip;
                match word.as_str() {
                    "" => {
                        if visible {
                            if let Some(c) = param.chars().next() {
                                r.pending.push(c as u8);
                            }
                        }
                    }
                    "'" => {
                        if visible {
                            if r.skip_chars > 0 {
                                r.skip_chars -= 1;
                            } else if let Ok(b) = u8::from_str_radix(&param, 16) {
                                r.pending.push(b);
                            }
                        }
                    }
                    "u" => {
                        r.flush();
                        if visible {
                            if let Some(c) = unicode_char(&param) {
                                r.out.push(c);
                            }
                        }
                        r.skip_chars = r.unicode_skip;
                    }
                    "uc" => r.unicode_skip = param.parse().unwrap_or(1),
                    "ansicpg" => {
                        if let Ok(cp) = param.parse::<u32>() {
                            r.codepage = codepage_label(cp);
                        }
                    }
                    "par" | "line" | "sect" => {
                        if visible {
                            r.push_char('\n');
                        } else {
                            r.flush();
                        }
                    }
                    "tab" => {
                        if visible {
                            r.push_char('\t');
                        } else {
                            r.flush();
                        }
                    }
                    "*" => r.scope.skip = true,
                    other => {
                        if let Some(c) = symbol_word(other) {
                            if visible {
                                r.push_char(c);
                            } else {
                                r.flush();
                            }
                        } else {
                            if is_ignored_destination(other) {
                                r.scope.skip = true;
                            }
                            r.flush();
                        }
                    }
                }
            }
            b'\r' | b'\n' => i += 1,
            _ => {
                if !r.scope.skip {
                    if r.skip_chars > 0 {
                        r.skip_chars -= 1;
                    } else {
                        r.pending.push(bytes[i]);
                    }
                }
                i += 1;
            }
        }
    }
    r.flush();
    super::text::collapse_blank_lines(&r.out)
}

/// The character a `\uN` stands for. Word writes values above 32767 as
/// negative 16-bit numbers, which is why this isn't a plain parse.
fn unicode_char(param: &str) -> Option<char> {
    let n: i32 = param.parse().ok()?;
    let scalar = if n < 0 { (n + 65536) as u32 } else { n as u32 };
    char::from_u32(scalar)
}

/// Control words that stand for a single character.
fn symbol_word(word: &str) -> Option<char> {
    Some(match word {
        "lquote" => '\u{2018}',
        "rquote" => '\u{2019}',
        "ldblquote" => '\u{201C}',
        "rdblquote" => '\u{201D}',
        "emdash" => '\u{2014}',
        "endash" => '\u{2013}',
        "bullet" => '\u{2022}',
        "emspace" | "enspace" => ' ',
        _ => return None,
    })
}

/// Reads the control word starting at the backslash at `at`.
///
/// Returns `(word, parameter, next_index)`. A symbol escape like `\\` or `\{`
/// comes back with an empty word and the symbol as the parameter; `\'a9` comes
/// back as `("'", "a9", …)`.
fn read_control(bytes: &[u8], at: usize) -> (String, String, usize) {
    let mut i = at + 1;
    if i >= bytes.len() {
        return (String::new(), String::new(), bytes.len());
    }
    let first = bytes[i];
    if first == b'\'' {
        let hex_end = (i + 3).min(bytes.len());
        let hex = String::from_utf8_lossy(&bytes[i + 1..hex_end]).to_string();
        return ("'".into(), hex, hex_end);
    }
    if !first.is_ascii_alphabetic() {
        // A symbol escape. `\~` is a non-breaking space and `\-` an optional
        // hyphen; both read better as their plain equivalents.
        let symbol = match first {
            b'~' => ' ',
            b'_' => '-',
            other => other as char,
        };
        return (String::new(), symbol.to_string(), i + 1);
    }
    let start = i;
    while i < bytes.len() && bytes[i].is_ascii_alphabetic() {
        i += 1;
    }
    let word = String::from_utf8_lossy(&bytes[start..i]).to_string();

    let param_start = i;
    if i < bytes.len() && bytes[i] == b'-' {
        i += 1;
    }
    while i < bytes.len() && bytes[i].is_ascii_digit() {
        i += 1;
    }
    let param = String::from_utf8_lossy(&bytes[param_start..i]).to_string();
    // A single space after a control word is the delimiter and not content.
    if i < bytes.len() && bytes[i] == b' ' {
        i += 1;
    }
    (word, param, i)
}

/// Destinations whose contents are metadata, not message text.
fn is_ignored_destination(word: &str) -> bool {
    matches!(
        word,
        "fonttbl"
            | "colortbl"
            | "stylesheet"
            | "listtable"
            | "listoverridetable"
            | "revtbl"
            | "rsidtbl"
            | "generator"
            | "info"
            | "pict"
            | "object"
            | "themedata"
            | "colorschememapping"
            | "latentstyles"
            | "datastore"
            | "xmlnstbl"
            | "filetbl"
            | "mmathPr"
    )
}

fn codepage_label(cp: u32) -> String {
    match cp {
        932 => "shift_jis".into(),
        936 => "gbk".into(),
        949 => "euc-kr".into(),
        950 => "big5".into(),
        1200 => "utf-16le".into(),
        65001 => "utf-8".into(),
        1250..=1258 => format!("windows-{cp}"),
        28591..=28599 => format!("iso-8859-{}", cp - 28590),
        _ => "windows-1252".into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uncompressed_streams_pass_through() {
        let mut stream = Vec::new();
        stream.extend_from_slice(&20u32.to_le_bytes()); // comp size
        stream.extend_from_slice(&4u32.to_le_bytes()); // raw size
        stream.extend_from_slice(&0x414C_454Du32.to_le_bytes()); // "MELA"
        stream.extend_from_slice(&0u32.to_le_bytes()); // crc
        stream.extend_from_slice(b"{\\rt");
        assert_eq!(decompress(&stream).unwrap(), b"{\\rt");
    }

    #[test]
    fn a_short_or_alien_stream_is_an_error_not_a_panic() {
        assert!(decompress(b"tiny").is_err());
        let mut stream = vec![0u8; 16];
        stream[8] = 0xAA;
        assert!(decompress(&stream).is_err());
    }

    #[test]
    fn rtf_to_text_drops_the_font_table() {
        let rtf = r"{\rtf1\ansi{\fonttbl{\f0\fnil Arial;}}\f0\fs20 Hello\par World\par}";
        assert_eq!(rtf_to_text(rtf), "Hello\nWorld");
    }

    #[test]
    fn hex_escapes_decode_in_the_declared_codepage() {
        let rtf = r"{\rtf1\ansi\ansicpg1252 caf\'e9\par}";
        assert_eq!(rtf_to_text(rtf), "café");
    }

    #[test]
    fn unicode_escapes_skip_their_ansi_fallback() {
        // `\uc1` says one character after `\u` is the ANSI stand-in, so the
        // `?` must not reach the output next to the euro sign it replaced.
        let rtf = "{\\rtf1\\ansi\\uc1 \\u8364 ?100\\par}";
        assert_eq!(rtf_to_text(rtf), "\u{20AC}100");
    }

    #[test]
    fn encapsulated_html_recovers_the_tags_and_skips_reader_only_runs() {
        let rtf = "{\\rtf1\\ansi\\fromhtml1\
{\\*\\htmltag19 <html>}\
{\\*\\htmltag34 <body>}\
\\htmlrtf {\\f0\\fs22 \\htmlrtf0 Hello\\htmlrtf\\par}\\htmlrtf0 \
{\\*\\htmltag58 </body>}{\\*\\htmltag27 </html>}}";
        assert!(is_encapsulated_html(rtf));
        let html = deencapsulate_html(rtf);
        assert!(html.contains("<html>"), "got {html:?}");
        assert!(html.contains("<body>"), "got {html:?}");
        assert!(html.contains("Hello"), "got {html:?}");
        assert!(
            !html.contains("\\fs22") && !html.contains("f0"),
            "reader-only RTF leaked: {html:?}"
        );
    }
}
