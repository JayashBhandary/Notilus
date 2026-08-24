//! RFC 5322 + MIME parsing for `.eml` files.
//!
//! The parse is deliberately forgiving. A `.eml` on disk has usually been
//! through at least one mail system that mangled something — bare `\n` line
//! endings, a missing closing boundary, an unlabelled charset — and a preview
//! that refuses to open the file is worse than one that shows it imperfectly.

use super::text::{
    collapse_blank_lines, decode_base64, decode_charset, decode_encoded_words,
    decode_quoted_printable, html_to_text, parse_rfc5322_date,
};
use super::{Address, Attachment, Header, Message};

/// One MIME entity: its headers, its decoded body, and — for a `multipart/*` —
/// its children.
struct Part {
    headers: Vec<(String, String)>,
    /// Body with the content-transfer-encoding already undone. Empty for a
    /// multipart, whose content is entirely in [`children`].
    body: Vec<u8>,
    children: Vec<Part>,
}

impl Part {
    fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_str())
    }

    /// Lowercased `type/subtype`, defaulting to `text/plain` as the RFC says.
    fn mime_type(&self) -> String {
        self.header("content-type")
            .and_then(|v| v.split(';').next())
            .map(|v| v.trim().to_ascii_lowercase())
            .filter(|v| !v.is_empty())
            .unwrap_or_else(|| "text/plain".into())
    }

    fn content_param(&self, header: &str, param: &str) -> Option<String> {
        param_of(self.header(header)?, param)
    }

    /// The filename this part wants to be saved as, from either of the two
    /// places senders put it.
    fn filename(&self) -> Option<String> {
        self.content_param("content-disposition", "filename")
            .or_else(|| self.content_param("content-type", "name"))
            .map(|n| decode_encoded_words(&n))
            .map(|n| sanitise_filename(&n))
            .filter(|n| !n.is_empty())
    }

    fn disposition(&self) -> String {
        self.header("content-disposition")
            .and_then(|v| v.split(';').next())
            .map(|v| v.trim().to_ascii_lowercase())
            .unwrap_or_default()
    }

    fn content_id(&self) -> String {
        self.header("content-id")
            .map(|v| v.trim().trim_start_matches('<').trim_end_matches('>').to_string())
            .unwrap_or_default()
    }

    fn text(&self) -> String {
        let charset = self
            .content_param("content-type", "charset")
            .unwrap_or_default();
        decode_charset(&self.body, &charset)
    }
}

pub fn parse(bytes: &[u8]) -> Message {
    let root = parse_part(bytes, 0);
    let mut message = Message {
        format: "eml".into(),
        ..Default::default()
    };

    for (name, value) in &root.headers {
        message.headers.push(Header {
            name: name.clone(),
            value: decode_encoded_words(value),
        });
    }

    message.subject = root
        .header("subject")
        .map(decode_encoded_words)
        .unwrap_or_default();
    message.from = parse_address_list(root.header("from").unwrap_or_default());
    message.to = parse_address_list(root.header("to").unwrap_or_default());
    message.cc = parse_address_list(root.header("cc").unwrap_or_default());
    message.bcc = parse_address_list(root.header("bcc").unwrap_or_default());
    message.reply_to = parse_address_list(root.header("reply-to").unwrap_or_default());
    message.date = root.header("date").unwrap_or_default().trim().to_string();
    message.date_epoch_ms = parse_rfc5322_date(&message.date);
    message.message_id = root
        .header("message-id")
        .unwrap_or_default()
        .trim()
        .to_string();

    let mut bodies = Bodies::default();
    let mut attachments = Vec::new();
    collect(&root, true, &mut bodies, &mut attachments);

    message.body_text = bodies.text;
    message.body_html = bodies.html;
    if message.body_text.is_empty() && !message.body_html.is_empty() {
        message.body_text = html_to_text(&message.body_html);
    }
    message.attachments = attachments
        .into_iter()
        .enumerate()
        .map(|(i, mut a)| {
            a.index = i as u32;
            a
        })
        .collect();
    message
}

/// The bytes of the `index`th attachment, walked in exactly the order [`parse`]
/// numbered them.
pub fn attachment_bytes(bytes: &[u8], index: u32) -> Result<(String, Vec<u8>), String> {
    let root = parse_part(bytes, 0);
    let mut found = Vec::new();
    collect_attachment_parts(&root, true, &mut found);
    let part = found
        .get(index as usize)
        .ok_or_else(|| format!("This message has no attachment #{}.", index + 1))?;
    let name = part
        .filename()
        .unwrap_or_else(|| default_name(index, &part.mime_type()));
    Ok((name, part.body.clone()))
}

#[derive(Default)]
struct Bodies {
    text: String,
    html: String,
}

/// Walks the MIME tree, sorting each leaf into "this is the message" or "this
/// is an attachment".
///
/// `in_body` tracks whether we are still inside the run of parts that make up
/// the displayed message. Once past it — inside a `multipart/mixed` after the
/// first part, say — a `text/plain` is a forwarded note to be saved, not a
/// second copy of the body, so it must not overwrite what was already found.
fn collect(part: &Part, in_body: bool, bodies: &mut Bodies, out: &mut Vec<Attachment>) {
    let mime = part.mime_type();

    if mime.starts_with("multipart/") {
        let alternative = mime == "multipart/alternative";
        for (i, child) in part.children.iter().enumerate() {
            // In `alternative` every child is a rendering of the same content,
            // so all of them are body candidates. Elsewhere only the first
            // child continues the body.
            collect(child, in_body && (alternative || i == 0), bodies, out);
        }
        return;
    }
    if mime == "message/rfc822" {
        // A forwarded message. Its own tree is the attachment's business, not
        // this message's body.
        out.push(attachment_for(part, out.len()));
        return;
    }

    let disposition = part.disposition();
    let named = part.filename();
    let is_text = mime == "text/plain" || mime == "text/html";
    let is_body = in_body
        && is_text
        && disposition != "attachment"
        // A named text part inside the body run is still an attachment: that
        // is how a `.txt` or `.html` file rides along.
        && named.is_none();

    if is_body {
        let text = part.text();
        if mime == "text/html" {
            if bodies.html.is_empty() {
                bodies.html = text;
            }
        } else if bodies.text.is_empty() {
            bodies.text = collapse_blank_lines(&text);
        }
        return;
    }
    // Empty unnamed parts are padding some senders emit; they would show up as
    // "attachment (1) — 0 bytes" rows that do nothing.
    if part.body.is_empty() && named.is_none() {
        return;
    }
    out.push(attachment_for(part, out.len()));
}

/// The same walk as [`collect`], but keeping the parts themselves so their
/// bytes can be handed out later.
fn collect_attachment_parts<'a>(part: &'a Part, in_body: bool, out: &mut Vec<&'a Part>) {
    let mime = part.mime_type();
    if mime.starts_with("multipart/") {
        let alternative = mime == "multipart/alternative";
        for (i, child) in part.children.iter().enumerate() {
            collect_attachment_parts(child, in_body && (alternative || i == 0), out);
        }
        return;
    }
    if mime == "message/rfc822" {
        out.push(part);
        return;
    }
    let disposition = part.disposition();
    let named = part.filename();
    let is_text = mime == "text/plain" || mime == "text/html";
    if in_body && is_text && disposition != "attachment" && named.is_none() {
        return;
    }
    if part.body.is_empty() && named.is_none() {
        return;
    }
    out.push(part);
}

fn attachment_for(part: &Part, index: usize) -> Attachment {
    let mime = part.mime_type();
    let content_id = part.content_id();
    Attachment {
        index: index as u32,
        name: part
            .filename()
            .unwrap_or_else(|| default_name(index as u32, &mime)),
        size: part.body.len() as u64,
        is_inline: part.disposition() == "inline" || !content_id.is_empty(),
        content_id,
        mime,
    }
}

fn default_name(index: u32, mime: &str) -> String {
    let ext = match mime {
        "message/rfc822" => "eml",
        "application/pdf" => "pdf",
        "image/png" => "png",
        "image/jpeg" => "jpg",
        "image/gif" => "gif",
        "text/html" => "html",
        "text/plain" => "txt",
        "text/calendar" => "ics",
        other => other.rsplit('/').next().unwrap_or("bin"),
    };
    format!("attachment-{}.{}", index + 1, sanitise_filename(ext))
}

// ── the parser proper ──────────────────────────────────────────────────────

/// Depth guard. Mail bombs and merely confused mail systems both produce
/// deeply nested multiparts; nothing legitimate goes near this.
const MAX_DEPTH: usize = 24;

fn parse_part(bytes: &[u8], depth: usize) -> Part {
    let (headers, body_start) = parse_headers(bytes);
    let raw_body = &bytes[body_start..];
    let mut part = Part {
        headers,
        body: Vec::new(),
        children: Vec::new(),
    };

    let mime = part.mime_type();
    if mime.starts_with("multipart/") && depth < MAX_DEPTH {
        if let Some(boundary) = part.content_param("content-type", "boundary") {
            if !boundary.is_empty() {
                for chunk in split_on_boundary(raw_body, &boundary) {
                    part.children.push(parse_part(chunk, depth + 1));
                }
                if !part.children.is_empty() {
                    return part;
                }
            }
        }
        // A multipart whose boundary is missing or never appears: fall through
        // and treat the whole thing as one body, so the text is still shown.
    }

    let encoding = part
        .header("content-transfer-encoding")
        .map(|v| v.trim().to_ascii_lowercase())
        .unwrap_or_default();
    part.body = match encoding.as_str() {
        "base64" => decode_base64(raw_body),
        "quoted-printable" => decode_quoted_printable(raw_body, false),
        _ => raw_body.to_vec(),
    };
    part
}

/// Splits the header block from the body and unfolds continuation lines.
///
/// Returns the headers and the byte offset the body starts at.
fn parse_headers(bytes: &[u8]) -> (Vec<(String, String)>, usize) {
    let mut headers = Vec::new();
    let mut i = 0;
    let mut current: Option<(String, String)> = None;

    while i < bytes.len() {
        let line_end = memchr::memchr(b'\n', &bytes[i..])
            .map(|p| i + p)
            .unwrap_or(bytes.len());
        let mut line = &bytes[i..line_end];
        if line.ends_with(b"\r") {
            line = &line[..line.len() - 1];
        }
        let next = (line_end + 1).min(bytes.len());

        if line.is_empty() {
            if let Some(pair) = current.take() {
                headers.push(pair);
            }
            return (headers, next);
        }
        // A line starting with space or tab continues the one before it.
        if line[0] == b' ' || line[0] == b'\t' {
            if let Some((_, value)) = current.as_mut() {
                value.push(' ');
                value.push_str(String::from_utf8_lossy(line).trim());
            }
            i = next;
            continue;
        }
        if let Some(pair) = current.take() {
            headers.push(pair);
        }
        let text = String::from_utf8_lossy(line);
        match text.find(':') {
            Some(colon) => {
                current = Some((
                    text[..colon].trim().to_string(),
                    text[colon + 1..].trim().to_string(),
                ));
            }
            // No colon before the first blank line: this isn't a header block
            // at all. Treat everything from here as body.
            None => {
                if let Some(pair) = current.take() {
                    headers.push(pair);
                }
                return (headers, i);
            }
        }
        i = next;
    }
    if let Some(pair) = current.take() {
        headers.push(pair);
    }
    (headers, bytes.len())
}

/// The chunks between `--boundary` lines, excluding the preamble and anything
/// after `--boundary--`.
fn split_on_boundary<'a>(body: &'a [u8], boundary: &str) -> Vec<&'a [u8]> {
    let marker = format!("--{boundary}");
    let marker = marker.as_bytes();
    let mut parts = Vec::new();
    let mut start: Option<usize> = None;
    let mut i = 0;

    while i < body.len() {
        let line_end = memchr::memchr(b'\n', &body[i..])
            .map(|p| i + p)
            .unwrap_or(body.len());
        let mut line = &body[i..line_end];
        if line.ends_with(b"\r") {
            line = &line[..line.len() - 1];
        }

        if line.starts_with(marker) {
            // Trailing whitespace after the boundary is legal and common.
            let tail = &line[marker.len()..];
            let closing = tail.starts_with(b"--");
            if let Some(from) = start.take() {
                // The CRLF before the boundary belongs to the boundary, not to
                // the part — keeping it would corrupt a binary attachment.
                let mut end = i;
                if end > from && body[end - 1] == b'\n' {
                    end -= 1;
                }
                if end > from && body[end - 1] == b'\r' {
                    end -= 1;
                }
                parts.push(&body[from..end]);
            }
            if closing {
                return parts;
            }
            start = Some((line_end + 1).min(body.len()));
        }
        i = (line_end + 1).min(body.len());
        if line_end >= body.len() {
            break;
        }
    }
    // No closing boundary — take what is left rather than dropping the last
    // part, which is the usual damage from a truncated download.
    if let Some(from) = start {
        if from < body.len() {
            parts.push(&body[from..]);
        }
    }
    parts
}

/// The value of `param` in a structured header like
/// `Content-Type: text/plain; charset="utf-8"`.
///
/// Handles RFC 2231 continuations (`name*0`, `name*1`, …) and the
/// `name*=charset''percent-encoded` form, which is how non-ASCII filenames
/// actually arrive.
fn param_of(header: &str, param: &str) -> Option<String> {
    let mut segments: Vec<(usize, String, bool)> = Vec::new();
    let mut simple: Option<String> = None;

    for raw in split_params(header).into_iter().skip(1) {
        let Some(eq) = raw.find('=') else { continue };
        let key = raw[..eq].trim().to_ascii_lowercase();
        let value = unquote(raw[eq + 1..].trim());

        if key == param {
            simple = Some(value);
            continue;
        }
        if key == format!("{param}*") {
            return Some(decode_rfc2231(&value));
        }
        if let Some(rest) = key.strip_prefix(&format!("{param}*")) {
            let extended = rest.ends_with('*');
            let digits = rest.trim_end_matches('*');
            if let Ok(n) = digits.parse::<usize>() {
                segments.push((n, value, extended));
            }
        }
    }

    if !segments.is_empty() {
        segments.sort_by_key(|(n, _, _)| *n);
        let joined: String = segments.iter().map(|(_, v, _)| v.as_str()).collect();
        // Only the first segment carries the charset prefix.
        return Some(if segments[0].2 {
            decode_rfc2231(&joined)
        } else {
            joined
        });
    }
    simple
}

/// Splits a structured header on `;`, ignoring separators inside quotes.
fn split_params(header: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut current = String::new();
    let mut quoted = false;
    let mut escaped = false;
    for ch in header.chars() {
        if escaped {
            current.push(ch);
            escaped = false;
            continue;
        }
        match ch {
            '\\' if quoted => escaped = true,
            '"' => {
                quoted = !quoted;
                current.push(ch);
            }
            ';' if !quoted => {
                out.push(current.trim().to_string());
                current = String::new();
            }
            _ => current.push(ch),
        }
    }
    out.push(current.trim().to_string());
    out
}

fn unquote(value: &str) -> String {
    let trimmed = value.trim();
    if trimmed.len() >= 2 && trimmed.starts_with('"') && trimmed.ends_with('"') {
        return trimmed[1..trimmed.len() - 1].replace("\\\"", "\"").replace("\\\\", "\\");
    }
    trimmed.to_string()
}

/// `utf-8''%E2%82%AC.pdf` → `€.pdf`.
fn decode_rfc2231(value: &str) -> String {
    let mut parts = value.splitn(3, '\'');
    let charset = parts.next().unwrap_or("");
    let _language = parts.next();
    let encoded = match parts.next() {
        Some(rest) => rest,
        // No charset prefix — it was a continuation segment, so the bytes are
        // already percent-encoded ASCII.
        None => value,
    };
    let mut bytes = Vec::with_capacity(encoded.len());
    let raw = encoded.as_bytes();
    let mut i = 0;
    while i < raw.len() {
        if raw[i] == b'%' && i + 2 < raw.len() {
            if let Ok(b) = u8::from_str_radix(&encoded[i + 1..i + 3], 16) {
                bytes.push(b);
                i += 3;
                continue;
            }
        }
        bytes.push(raw[i]);
        i += 1;
    }
    decode_charset(&bytes, charset)
}

/// Strips path separators and control characters so a hostile `filename=`
/// can't escape the folder a save lands in.
pub fn sanitise_filename(name: &str) -> String {
    let base = name
        .rsplit(['/', '\\'])
        .next()
        .unwrap_or(name)
        .trim()
        .trim_matches('.');
    let cleaned: String = base
        .chars()
        .map(|c| {
            if c.is_control() || matches!(c, ':' | '*' | '?' | '"' | '<' | '>' | '|') {
                '_'
            } else {
                c
            }
        })
        .collect();
    let cleaned = cleaned.trim().to_string();
    if cleaned.is_empty() || cleaned == "." || cleaned == ".." {
        String::new()
    } else {
        cleaned
    }
}

/// Splits an address header on commas that aren't inside quotes or angle
/// brackets, then parses each mailbox.
pub fn parse_address_list(header: &str) -> Vec<Address> {
    let mut out = Vec::new();
    let mut current = String::new();
    let mut quoted = false;
    let mut angled = false;
    let mut escaped = false;

    for ch in header.chars() {
        if escaped {
            current.push(ch);
            escaped = false;
            continue;
        }
        match ch {
            '\\' if quoted => escaped = true,
            '"' => {
                quoted = !quoted;
                current.push(ch);
            }
            '<' if !quoted => {
                angled = true;
                current.push(ch);
            }
            '>' if !quoted => {
                angled = false;
                current.push(ch);
            }
            ',' | ';' if !quoted && !angled => {
                push_address(&mut out, &current);
                current = String::new();
            }
            _ => current.push(ch),
        }
    }
    push_address(&mut out, &current);
    out
}

fn push_address(out: &mut Vec<Address>, raw: &str) {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return;
    }
    // A group syntax header — "Undisclosed recipients:;" — leaves a label with
    // no mailbox. Show it as a name.
    if let Some(open) = trimmed.rfind('<') {
        if let Some(close) = trimmed[open..].find('>') {
            let email = trimmed[open + 1..open + close].trim().to_string();
            let name = decode_encoded_words(trimmed[..open].trim())
                .trim()
                .trim_matches('"')
                .trim()
                .to_string();
            out.push(Address { name, email });
            return;
        }
    }
    // `addr@example.com (Display Name)`, the obsolete-but-alive comment form.
    if let (Some(open), true) = (trimmed.find('('), trimmed.ends_with(')')) {
        let email = trimmed[..open].trim().to_string();
        let name = decode_encoded_words(trimmed[open + 1..trimmed.len() - 1].trim());
        if email.contains('@') {
            out.push(Address { name, email });
            return;
        }
    }
    if trimmed.contains('@') {
        out.push(Address {
            name: String::new(),
            email: trimmed.to_string(),
        });
    } else {
        out.push(Address {
            name: decode_encoded_words(trimmed.trim_end_matches(':')),
            email: String::new(),
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SIMPLE: &[u8] = b"From: Ada Lovelace <ada@example.com>\r\n\
To: \"Babbage, Charles\" <charles@example.com>, someone@else.test\r\n\
Subject: =?utf-8?Q?Analytical_Engine?=\r\n\
Date: Tue, 5 Mar 2024 09:30:00 +0100\r\n\
Content-Type: text/plain; charset=utf-8\r\n\
\r\n\
Notes on the engine.\r\n";

    #[test]
    fn reads_headers_addresses_and_body() {
        let msg = parse(SIMPLE);
        assert_eq!(msg.subject, "Analytical Engine");
        assert_eq!(msg.from.len(), 1);
        assert_eq!(msg.from[0].name, "Ada Lovelace");
        assert_eq!(msg.from[0].email, "ada@example.com");
        assert_eq!(msg.to.len(), 2, "a quoted comma must not split the list");
        assert_eq!(msg.to[0].name, "Babbage, Charles");
        assert_eq!(msg.to[1].email, "someone@else.test");
        assert_eq!(msg.body_text, "Notes on the engine.");
        assert_eq!(msg.date_epoch_ms, 1_709_627_400_000);
    }

    const MULTIPART: &[u8] = b"Subject: Report\r\n\
MIME-Version: 1.0\r\n\
Content-Type: multipart/mixed; boundary=\"XX\"\r\n\
\r\n\
preamble, ignored\r\n\
--XX\r\n\
Content-Type: multipart/alternative; boundary=\"YY\"\r\n\
\r\n\
--YY\r\n\
Content-Type: text/plain; charset=utf-8\r\n\
\r\n\
plain body\r\n\
--YY\r\n\
Content-Type: text/html; charset=utf-8\r\n\
\r\n\
<p>html body</p>\r\n\
--YY--\r\n\
--XX\r\n\
Content-Type: application/pdf; name=\"q1.pdf\"\r\n\
Content-Disposition: attachment; filename=\"q1.pdf\"\r\n\
Content-Transfer-Encoding: base64\r\n\
\r\n\
JVBERi0=\r\n\
--XX--\r\n";

    #[test]
    fn picks_both_bodies_out_of_an_alternative_and_keeps_the_attachment() {
        let msg = parse(MULTIPART);
        assert_eq!(msg.body_text, "plain body");
        assert_eq!(msg.body_html, "<p>html body</p>");
        assert_eq!(msg.attachments.len(), 1);
        assert_eq!(msg.attachments[0].name, "q1.pdf");
        assert_eq!(msg.attachments[0].mime, "application/pdf");

        let (name, bytes) = attachment_bytes(MULTIPART, 0).unwrap();
        assert_eq!(name, "q1.pdf");
        assert_eq!(&bytes, b"%PDF-");
    }

    #[test]
    fn attachment_index_out_of_range_is_an_error_not_a_panic() {
        assert!(attachment_bytes(MULTIPART, 7).is_err());
    }

    #[test]
    fn html_only_messages_get_a_text_rendering() {
        let raw = b"Subject: x\r\nContent-Type: text/html\r\n\r\n<p>Hello</p><p>World</p>";
        let msg = parse(raw);
        assert_eq!(msg.body_html, "<p>Hello</p><p>World</p>");
        assert_eq!(msg.body_text, "Hello\n\nWorld");
    }

    #[test]
    fn rfc2231_filenames_survive() {
        let raw = b"Content-Type: multipart/mixed; boundary=B\r\n\r\n\
--B\r\n\
Content-Type: text/plain\r\n\r\nbody\r\n\
--B\r\n\
Content-Type: application/octet-stream\r\n\
Content-Disposition: attachment;\r\n filename*=utf-8''%E2%82%AC%20rates.txt\r\n\r\n\
x\r\n--B--\r\n";
        let msg = parse(raw);
        assert_eq!(msg.attachments.len(), 1);
        assert_eq!(msg.attachments[0].name, "€ rates.txt");
    }

    #[test]
    fn a_traversal_filename_cannot_escape_its_folder() {
        assert_eq!(sanitise_filename("../../etc/passwd"), "passwd");
        assert_eq!(sanitise_filename("..\\..\\win.ini"), "win.ini");
        assert_eq!(sanitise_filename(".."), "");
    }

    #[test]
    fn bare_lf_line_endings_still_parse() {
        let raw = b"Subject: Unix\nContent-Type: text/plain\n\nbody here\n";
        let msg = parse(raw);
        assert_eq!(msg.subject, "Unix");
        assert_eq!(msg.body_text, "body here");
    }
}
