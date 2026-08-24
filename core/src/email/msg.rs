//! Outlook `.msg` files: an OLE compound file holding MAPI properties.
//!
//! There is no text to scan here. Each property lives in its own stream named
//! after its tag (`__substg1.0_0037001F` is the subject as UTF-16), fixed-width
//! properties share one `__properties_version1.0` table, and attachments and
//! recipients are sub-storages with the same layout one level down. See
//! [MS-OXMSG].

use std::collections::HashMap;
use std::io::{Cursor, Read};

use super::eml::{parse_address_list, sanitise_filename};
use super::rtf;
use super::text::{collapse_blank_lines, decode_charset, html_to_text};
use super::{Address, Attachment, Header, Message};

// ── property tags ──────────────────────────────────────────────────────────
// Property *ids*; the type nibble is appended when a stream is looked up.

const PID_SUBJECT: u16 = 0x0037;
const PID_BODY: u16 = 0x1000;
const PID_RTF_COMPRESSED: u16 = 0x1009;
const PID_HTML: u16 = 0x1013;
const PID_TRANSPORT_HEADERS: u16 = 0x007D;
const PID_MESSAGE_ID: u16 = 0x1035;
const PID_CLIENT_SUBMIT_TIME: u16 = 0x0039;
const PID_DELIVERY_TIME: u16 = 0x0E06;
const PID_DISPLAY_TO: u16 = 0x0E04;
const PID_DISPLAY_CC: u16 = 0x0E03;
const PID_DISPLAY_BCC: u16 = 0x0E02;
const PID_SENDER_NAME: u16 = 0x0C1A;
const PID_SENDER_ADDRTYPE: u16 = 0x0C1E;
const PID_SENDER_EMAIL: u16 = 0x0C1F;
const PID_SENDER_SMTP: u16 = 0x5D01;
const PID_REPRESENTING_NAME: u16 = 0x0042;
const PID_REPRESENTING_ADDRTYPE: u16 = 0x0064;
const PID_REPRESENTING_EMAIL: u16 = 0x0065;
const PID_REPRESENTING_SMTP: u16 = 0x5D02;
const PID_INTERNET_CPID: u16 = 0x3FDE;
const PID_MESSAGE_CODEPAGE: u16 = 0x3FFD;

const PID_DISPLAY_NAME: u16 = 0x3001;
const PID_RECIPIENT_TYPE: u16 = 0x0C15;
const PID_EMAIL_ADDRESS: u16 = 0x3003;
const PID_SMTP_ADDRESS: u16 = 0x39FE;
const PID_ADDRTYPE: u16 = 0x3002;

const PID_ATTACH_DATA: u16 = 0x3701;
const PID_ATTACH_FILENAME: u16 = 0x3704;
const PID_ATTACH_LONG_FILENAME: u16 = 0x3707;
const PID_ATTACH_EXTENSION: u16 = 0x3703;
const PID_ATTACH_MIME_TAG: u16 = 0x370E;
const PID_ATTACH_CONTENT_ID: u16 = 0x3712;
const PID_ATTACH_METHOD: u16 = 0x3705;
const PID_ATTACH_FLAGS: u16 = 0x3714;
const PID_ATTACHMENT_HIDDEN: u16 = 0x7FFE;

const PT_STRING8: u16 = 0x001E;
const PT_UNICODE: u16 = 0x001F;
const PT_BINARY: u16 = 0x0102;

/// `ATTACH_EMBEDDED_MSG` — the attachment is a whole message, stored as a
/// nested storage rather than as bytes.
const ATTACH_EMBEDDED_MSG: i32 = 5;
/// `ATT_MHTML_REF` in `PR_ATTACH_FLAGS`: the body refers to this part.
const ATT_MHTML_REF: i32 = 0x0000_0004;

type Cf = cfb::CompoundFile<Cursor<Vec<u8>>>;

/// Everything read out of one storage level: the variable-length property
/// streams, the fixed-width property table, and the names of the sub-storages.
struct Props {
    /// Full 32-bit tag → raw stream bytes.
    streams: HashMap<u32, Vec<u8>>,
    /// Full 32-bit tag → the 8-byte value from `__properties_version1.0`.
    fixed: HashMap<u32, [u8; 8]>,
    attachments: Vec<String>,
    recipients: Vec<String>,
    /// Codepage for the `PT_STRING8` properties in this storage.
    codepage: String,
}

pub fn parse(bytes: &[u8]) -> Result<Message, String> {
    let mut cf = open(bytes)?;
    let props = read_storage(&mut cf, "/", HeaderSize::TopLevel)?;
    Ok(build_message(&mut cf, &props))
}

pub fn attachment_bytes(bytes: &[u8], index: u32) -> Result<(String, Vec<u8>), String> {
    let mut cf = open(bytes)?;
    let props = read_storage(&mut cf, "/", HeaderSize::TopLevel)?;
    let path = props
        .attachments
        .get(index as usize)
        .cloned()
        .ok_or_else(|| format!("This message has no attachment #{}.", index + 1))?;
    let attach = read_storage(&mut cf, &path, HeaderSize::Sub)?;
    let descriptor = describe_attachment(index, &attach);

    if attach.int(PID_ATTACH_METHOD) == Some(ATTACH_EMBEDDED_MSG) {
        // The bytes aren't bytes: it's a nested message. Render it as an
        // `.eml`, which is something the preview and the OS can both open.
        let inner_path = child_path(&path, &substg_name(PID_ATTACH_DATA, 0x000D));
        let inner = read_storage(&mut cf, &inner_path, HeaderSize::Embedded)?;
        let message = build_message(&mut cf, &inner);
        return Ok((descriptor.name, to_rfc822(&message).into_bytes()));
    }

    let data = attach
        .binary(PID_ATTACH_DATA)
        .cloned()
        .ok_or_else(|| format!("Attachment \"{}\" has no content.", descriptor.name))?;
    Ok((descriptor.name, data))
}

fn open(bytes: &[u8]) -> Result<Cf, String> {
    cfb::CompoundFile::open(Cursor::new(bytes.to_vec()))
        .map_err(|e| format!("This .msg file couldn't be opened: {e}"))
}

// ── message assembly ───────────────────────────────────────────────────────

fn build_message(cf: &mut Cf, props: &Props) -> Message {
    let mut message = Message {
        format: "msg".into(),
        subject: props.string(PID_SUBJECT).unwrap_or_default(),
        message_id: props.string(PID_MESSAGE_ID).unwrap_or_default(),
        ..Default::default()
    };

    // The original headers, when Outlook kept them, are the best source for
    // everything a transport set — including the `Date` in the sender's own
    // timezone, which the MAPI timestamp has already flattened to UTC.
    let transport = props.string(PID_TRANSPORT_HEADERS).unwrap_or_default();
    if !transport.is_empty() {
        let parsed = super::eml::parse(format!("{}\r\n\r\n", transport.trim_end()).as_bytes());
        message.headers = parsed.headers;
        message.date = parsed.date;
        message.date_epoch_ms = parsed.date_epoch_ms;
        message.reply_to = parsed.reply_to;
        if message.message_id.is_empty() {
            message.message_id = parsed.message_id;
        }
        if message.subject.is_empty() {
            message.subject = parsed.subject;
        }
    }
    if message.date_epoch_ms == 0 {
        message.date_epoch_ms = props
            .filetime(PID_CLIENT_SUBMIT_TIME)
            .or_else(|| props.filetime(PID_DELIVERY_TIME))
            .unwrap_or(0);
    }

    message.from = sender_of(props);
    let (to, cc, bcc) = recipients_of(cf, props);
    message.to = to;
    message.cc = cc;
    message.bcc = bcc;
    // A message that was never sent has no recipient sub-storages; the display
    // strings are all there is.
    if message.to.is_empty() {
        message.to = parse_address_list(&props.string(PID_DISPLAY_TO).unwrap_or_default());
    }
    if message.cc.is_empty() {
        message.cc = parse_address_list(&props.string(PID_DISPLAY_CC).unwrap_or_default());
    }
    if message.bcc.is_empty() {
        message.bcc = parse_address_list(&props.string(PID_DISPLAY_BCC).unwrap_or_default());
    }

    let (text, html) = bodies_of(props);
    message.body_text = text;
    message.body_html = html;
    if message.body_text.is_empty() && !message.body_html.is_empty() {
        message.body_text = html_to_text(&message.body_html);
    }

    for (index, path) in props.attachments.iter().enumerate() {
        let Ok(attach) = read_storage(cf, path, HeaderSize::Sub) else {
            continue;
        };
        message
            .attachments
            .push(describe_attachment(index as u32, &attach));
    }

    if message.headers.is_empty() {
        message.headers = synthetic_headers(&message);
    }
    message
}

/// The three body representations, in the order of how much they preserve.
fn bodies_of(props: &Props) -> (String, String) {
    let text = props
        .string(PID_BODY)
        .map(|b| collapse_blank_lines(&b))
        .unwrap_or_default();

    // PR_HTML is nominally binary, but plenty of writers store it as a string.
    let mut html = props
        .binary(PID_HTML)
        .map(|raw| decode_charset(raw, &props.codepage))
        .or_else(|| props.string(PID_HTML))
        .unwrap_or_default();

    if html.is_empty() {
        if let Some(compressed) = props.binary(PID_RTF_COMPRESSED) {
            if let Ok(raw) = rtf::decompress(compressed) {
                let doc = decode_charset(&raw, "windows-1252");
                if rtf::is_encapsulated_html(&doc) {
                    html = rtf::deencapsulate_html(&doc);
                } else if text.is_empty() {
                    return (rtf::rtf_to_text(&doc), String::new());
                }
            }
        }
    }
    (text, html)
}

fn sender_of(props: &Props) -> Vec<Address> {
    // Exchange stores an internal X.500 name in `PR_SENDER_EMAIL_ADDRESS`;
    // the SMTP property beside it is the address a human recognises.
    let candidates: [(u16, u16, u16, u16); 2] = [
        (
            PID_SENDER_NAME,
            PID_SENDER_ADDRTYPE,
            PID_SENDER_EMAIL,
            PID_SENDER_SMTP,
        ),
        (
            PID_REPRESENTING_NAME,
            PID_REPRESENTING_ADDRTYPE,
            PID_REPRESENTING_EMAIL,
            PID_REPRESENTING_SMTP,
        ),
    ];
    for (name_id, addrtype_id, email_id, smtp_id) in candidates {
        let name = props.string(name_id).unwrap_or_default();
        let email = best_address(props, addrtype_id, email_id, smtp_id);
        if !name.is_empty() || !email.is_empty() {
            return vec![Address { name, email }];
        }
    }
    Vec::new()
}

fn best_address(props: &Props, addrtype_id: u16, email_id: u16, smtp_id: u16) -> String {
    let smtp = props.string(smtp_id).unwrap_or_default();
    let email = props.string(email_id).unwrap_or_default();
    let addrtype = props.string(addrtype_id).unwrap_or_default();
    if !smtp.is_empty() {
        return smtp;
    }
    if addrtype.eq_ignore_ascii_case("EX") && !email.contains('@') {
        // An X.500 DN is not an address; showing it would be worse than
        // showing nothing, and the display name carries the identity.
        return String::new();
    }
    email
}

fn recipients_of(cf: &mut Cf, props: &Props) -> (Vec<Address>, Vec<Address>, Vec<Address>) {
    let (mut to, mut cc, mut bcc) = (Vec::new(), Vec::new(), Vec::new());
    for path in &props.recipients {
        let Ok(recip) = read_storage(cf, path, HeaderSize::Sub) else {
            continue;
        };
        let address = Address {
            name: recip.string(PID_DISPLAY_NAME).unwrap_or_default(),
            email: best_address(&recip, PID_ADDRTYPE, PID_EMAIL_ADDRESS, PID_SMTP_ADDRESS),
        };
        if address.name.is_empty() && address.email.is_empty() {
            continue;
        }
        match recip.int(PID_RECIPIENT_TYPE) {
            Some(2) => cc.push(address),
            Some(3) => bcc.push(address),
            // 1 is To; 0 ("originator") and anything unexpected read best as a
            // recipient rather than being dropped.
            _ => to.push(address),
        }
    }
    (to, cc, bcc)
}

fn describe_attachment(index: u32, attach: &Props) -> Attachment {
    let embedded = attach.int(PID_ATTACH_METHOD) == Some(ATTACH_EMBEDDED_MSG);
    let mut name = attach
        .string(PID_ATTACH_LONG_FILENAME)
        .or_else(|| attach.string(PID_ATTACH_FILENAME))
        .or_else(|| attach.string(PID_DISPLAY_NAME))
        .map(|n| sanitise_filename(&n))
        .filter(|n| !n.is_empty())
        .unwrap_or_else(|| format!("attachment-{}", index + 1));

    if !name.contains('.') {
        if let Some(ext) = attach.string(PID_ATTACH_EXTENSION) {
            let ext = sanitise_filename(ext.trim_start_matches('.'));
            if !ext.is_empty() {
                name = format!("{name}.{ext}");
            }
        }
    }
    if embedded && !name.to_ascii_lowercase().ends_with(".eml") {
        name = format!("{name}.eml");
    }

    let content_id = attach.string(PID_ATTACH_CONTENT_ID).unwrap_or_default();
    let flags = attach.int(PID_ATTACH_FLAGS).unwrap_or(0);
    Attachment {
        index,
        size: if embedded {
            0
        } else {
            attach.binary(PID_ATTACH_DATA).map(|d| d.len()).unwrap_or(0) as u64
        },
        mime: attach
            .string(PID_ATTACH_MIME_TAG)
            .filter(|m| !m.is_empty())
            .unwrap_or_else(|| {
                if embedded {
                    "message/rfc822".into()
                } else {
                    guess_mime(&name)
                }
            }),
        is_inline: flags & ATT_MHTML_REF != 0
            || (!content_id.is_empty() && attach.int(PID_ATTACHMENT_HIDDEN) == Some(1)),
        content_id,
        name,
    }
}

fn guess_mime(name: &str) -> String {
    let ext = name.rsplit('.').next().unwrap_or("").to_ascii_lowercase();
    match ext.as_str() {
        "pdf" => "application/pdf",
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "bmp" => "image/bmp",
        "txt" => "text/plain",
        "html" | "htm" => "text/html",
        "csv" => "text/csv",
        "ics" => "text/calendar",
        "zip" => "application/zip",
        "doc" => "application/msword",
        "docx" => {
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        }
        "xls" => "application/vnd.ms-excel",
        "xlsx" => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "ppt" => "application/vnd.ms-powerpoint",
        "pptx" => {
            "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        }
        "msg" => "application/vnd.ms-outlook",
        "eml" => "message/rfc822",
        _ => "application/octet-stream",
    }
    .to_string()
}

/// A header table for a `.msg` that never carried one, so the preview's header
/// panel isn't empty for locally composed mail.
fn synthetic_headers(message: &Message) -> Vec<Header> {
    let mut out = Vec::new();
    let mut add = |name: &str, value: String| {
        if !value.is_empty() {
            out.push(Header {
                name: name.into(),
                value,
            });
        }
    };
    add("Subject", message.subject.clone());
    add("From", join_addresses(&message.from));
    add("To", join_addresses(&message.to));
    add("Cc", join_addresses(&message.cc));
    add("Bcc", join_addresses(&message.bcc));
    add("Date", message.date.clone());
    add("Message-ID", message.message_id.clone());
    out
}

fn join_addresses(list: &[Address]) -> String {
    list.iter()
        .map(|a| a.display())
        .collect::<Vec<_>>()
        .join(", ")
}

/// A minimal RFC 822 rendering, used when an embedded message has to be handed
/// out as a file.
fn to_rfc822(message: &Message) -> String {
    let mut out = String::new();
    for header in synthetic_headers(message) {
        out.push_str(&header.name);
        out.push_str(": ");
        out.push_str(&header.value);
        out.push_str("\r\n");
    }
    if !message.body_html.is_empty() {
        out.push_str("MIME-Version: 1.0\r\n");
        out.push_str("Content-Type: text/html; charset=utf-8\r\n\r\n");
        out.push_str(&message.body_html);
    } else {
        out.push_str("MIME-Version: 1.0\r\n");
        out.push_str("Content-Type: text/plain; charset=utf-8\r\n\r\n");
        out.push_str(&message.body_text);
    }
    out
}

// ── storage reading ────────────────────────────────────────────────────────

/// How many bytes of `__properties_version1.0` precede the property entries.
/// [MS-OXMSG] §2.4 gives a different preamble for each kind of storage.
#[derive(Clone, Copy)]
enum HeaderSize {
    TopLevel,
    Embedded,
    Sub,
}

impl HeaderSize {
    fn bytes(self) -> usize {
        match self {
            HeaderSize::TopLevel => 32,
            HeaderSize::Embedded => 24,
            HeaderSize::Sub => 8,
        }
    }
}

fn read_storage(cf: &mut Cf, path: &str, header: HeaderSize) -> Result<Props, String> {
    let entries: Vec<(String, bool)> = cf
        .read_storage(path)
        .map_err(|e| format!("Couldn't read the message structure: {e}"))?
        .map(|entry| (entry.name().to_string(), entry.is_stream()))
        .collect();

    let mut props = Props {
        streams: HashMap::new(),
        fixed: HashMap::new(),
        attachments: Vec::new(),
        recipients: Vec::new(),
        codepage: "windows-1252".into(),
    };

    let mut property_table = None;
    for (name, is_stream) in entries {
        if is_stream {
            if let Some(tag) = tag_of(&name) {
                if let Some(bytes) = read_stream(cf, &child_path(path, &name)) {
                    props.streams.insert(tag, bytes);
                }
            } else if name == "__properties_version1.0" {
                property_table = read_stream(cf, &child_path(path, &name));
            }
            continue;
        }
        if name.starts_with("__attach_version1.0_") {
            props.attachments.push(child_path(path, &name));
        } else if name.starts_with("__recip_version1.0_") {
            props.recipients.push(child_path(path, &name));
        }
    }
    // `#00000000`, `#00000001`, … The directory is stored in the compound
    // file's own collation order, which is not numeric, so sort to get the
    // order Outlook wrote them in.
    props.attachments.sort();
    props.recipients.sort();

    if let Some(table) = property_table {
        parse_property_table(&table, header, &mut props.fixed);
    }
    props.codepage = codepage_of(&props);
    Ok(props)
}

/// The 16-byte entries of `__properties_version1.0`.
///
/// Only the 8-byte value matters here: variable-length properties keep their
/// payload in a stream and record only its size, which we already have.
fn parse_property_table(
    table: &[u8],
    header: HeaderSize,
    out: &mut HashMap<u32, [u8; 8]>,
) {
    let mut i = header.bytes();
    while i + 16 <= table.len() {
        let tag = u32::from_le_bytes([table[i], table[i + 1], table[i + 2], table[i + 3]]);
        let mut value = [0u8; 8];
        value.copy_from_slice(&table[i + 8..i + 16]);
        out.insert(tag, value);
        i += 16;
    }
}

fn read_stream(cf: &mut Cf, path: &str) -> Option<Vec<u8>> {
    let mut stream = cf.open_stream(path).ok()?;
    let mut buffer = Vec::new();
    stream.read_to_end(&mut buffer).ok()?;
    Some(buffer)
}

fn child_path(parent: &str, name: &str) -> String {
    if parent == "/" {
        format!("/{name}")
    } else {
        format!("{parent}/{name}")
    }
}

/// `__substg1.0_0037001F` → `0x0037001F`.
fn tag_of(name: &str) -> Option<u32> {
    let hex = name.strip_prefix("__substg1.0_")?;
    // Multi-valued properties append `-XXXXXXXX`; only the first is read.
    let hex = hex.split('-').next()?;
    if hex.len() < 8 {
        return None;
    }
    u32::from_str_radix(&hex[..8], 16).ok()
}

fn substg_name(id: u16, ty: u16) -> String {
    format!("__substg1.0_{id:04X}{ty:04X}")
}

fn codepage_of(props: &Props) -> String {
    let cp = props
        .int_from(PID_INTERNET_CPID)
        .or_else(|| props.int_from(PID_MESSAGE_CODEPAGE))
        .unwrap_or(0);
    match cp {
        0 => "windows-1252".into(),
        65001 => "utf-8".into(),
        932 => "shift_jis".into(),
        936 => "gbk".into(),
        949 => "euc-kr".into(),
        950 => "big5".into(),
        1250..=1258 => format!("windows-{cp}"),
        28591..=28599 => format!("iso-8859-{}", cp - 28590),
        other => format!("windows-{other}"),
    }
}

impl Props {
    fn tag(id: u16, ty: u16) -> u32 {
        (id as u32) << 16 | ty as u32
    }

    /// A string property, preferring the UTF-16 form Outlook writes today over
    /// the codepage-dependent one it wrote a decade ago.
    fn string(&self, id: u16) -> Option<String> {
        if let Some(bytes) = self.streams.get(&Self::tag(id, PT_UNICODE)) {
            return Some(decode_utf16le(bytes));
        }
        if let Some(bytes) = self.streams.get(&Self::tag(id, PT_STRING8)) {
            return Some(decode_charset(bytes, &self.codepage));
        }
        None
    }

    fn binary(&self, id: u16) -> Option<&Vec<u8>> {
        self.streams.get(&Self::tag(id, PT_BINARY))
    }

    /// A `PT_LONG` or `PT_BOOLEAN` from the fixed-width table.
    fn int(&self, id: u16) -> Option<i32> {
        self.int_from(id)
    }

    fn int_from(&self, id: u16) -> Option<i32> {
        for ty in [0x0003u16, 0x000B, 0x0002] {
            if let Some(value) = self.fixed.get(&Self::tag(id, ty)) {
                return Some(i32::from_le_bytes([value[0], value[1], value[2], value[3]]));
            }
        }
        None
    }

    /// A `PT_SYSTIME`, converted from Windows FILETIME to Unix milliseconds.
    fn filetime(&self, id: u16) -> Option<i64> {
        let value = self.fixed.get(&Self::tag(id, 0x0040))?;
        let ticks = u64::from_le_bytes(*value);
        if ticks == 0 {
            return None;
        }
        // FILETIME counts 100ns intervals from 1601-01-01; 11644473600 seconds
        // separate that epoch from the Unix one.
        Some((ticks / 10_000) as i64 - 11_644_473_600_000)
    }
}

fn decode_utf16le(bytes: &[u8]) -> String {
    let units: Vec<u16> = bytes
        .chunks_exact(2)
        .map(|pair| u16::from_le_bytes([pair[0], pair[1]]))
        .collect();
    String::from_utf16_lossy(&units)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tag_names_parse_and_reject() {
        assert_eq!(tag_of("__substg1.0_0037001F"), Some(0x0037_001F));
        assert_eq!(tag_of("__substg1.0_10130102-00000001"), Some(0x1013_0102));
        assert_eq!(tag_of("__properties_version1.0"), None);
        assert_eq!(tag_of("__substg1.0_00"), None);
    }

    #[test]
    fn filetime_converts_to_unix_milliseconds() {
        let mut props = Props {
            streams: HashMap::new(),
            fixed: HashMap::new(),
            attachments: vec![],
            recipients: vec![],
            codepage: "utf-8".into(),
        };
        // 2024-03-05T08:30:00Z in FILETIME ticks.
        let ticks: u64 = (1_709_627_400 + 11_644_473_600) * 10_000_000;
        props
            .fixed
            .insert(Props::tag(PID_CLIENT_SUBMIT_TIME, 0x0040), ticks.to_le_bytes());
        assert_eq!(props.filetime(PID_CLIENT_SUBMIT_TIME), Some(1_709_627_400_000));
    }

    #[test]
    fn a_zero_filetime_reads_as_absent() {
        let mut props = Props {
            streams: HashMap::new(),
            fixed: HashMap::new(),
            attachments: vec![],
            recipients: vec![],
            codepage: "utf-8".into(),
        };
        props.fixed.insert(Props::tag(PID_DELIVERY_TIME, 0x0040), [0; 8]);
        assert_eq!(props.filetime(PID_DELIVERY_TIME), None);
    }

    #[test]
    fn unicode_properties_win_over_codepage_ones() {
        let mut props = Props {
            streams: HashMap::new(),
            fixed: HashMap::new(),
            attachments: vec![],
            recipients: vec![],
            codepage: "windows-1252".into(),
        };
        props
            .streams
            .insert(Props::tag(PID_SUBJECT, PT_STRING8), b"old".to_vec());
        let utf16: Vec<u8> = "new".encode_utf16().flat_map(|u| u.to_le_bytes()).collect();
        props.streams.insert(Props::tag(PID_SUBJECT, PT_UNICODE), utf16);
        assert_eq!(props.string(PID_SUBJECT).as_deref(), Some("new"));
    }

    #[test]
    fn a_file_that_is_not_a_compound_file_errors() {
        assert!(parse(b"not an OLE file at all").is_err());
    }
}
