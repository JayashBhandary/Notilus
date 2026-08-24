//! Reading `.eml` and `.msg` mail files.
//!
//! Both formats end up as the same [`Message`]: a subject, a set of address
//! lists, a plain-text body, an HTML body, the raw headers, and a flat list of
//! attachments addressed by index. The preview only ever sees that struct, so
//! it doesn't care which of the two wildly different containers it came from.
//!
//! - [`eml`] parses RFC 5322 + MIME, which is text all the way down.
//! - [`msg`] parses Outlook's `.msg`, which is an OLE compound file holding
//!   MAPI properties, and whose body may only exist as compressed RTF — hence
//!   [`rtf`].

pub mod eml;
pub mod msg;
pub mod rtf;
pub mod text;

/// One mailbox, as `Name <addr@example.com>` decomposes.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Address {
    pub name: String,
    pub email: String,
}

impl Address {
    pub fn display(&self) -> String {
        match (self.name.is_empty(), self.email.is_empty()) {
            (true, _) => self.email.clone(),
            (false, true) => self.name.clone(),
            (false, false) => format!("{} <{}>", self.name, self.email),
        }
    }
}

/// A part the reader can save or, for an inline image, render into the HTML
/// body. `index` is this attachment's position in [`Message::attachments`] and
/// is the handle used to fetch the bytes in a second call — the preview
/// shouldn't have to hold a whole mailbox-sized message in Dart memory just to
/// open one PDF out of it.
#[derive(Clone, Debug, Default)]
pub struct Attachment {
    pub index: u32,
    pub name: String,
    pub mime: String,
    pub size: u64,
    /// The `Content-ID`, without the angle brackets. An HTML body refers to it
    /// as `cid:<this>`.
    pub content_id: String,
    /// True when the message positions this part inside the body rather than
    /// as something to download.
    pub is_inline: bool,
}

#[derive(Clone, Debug, Default)]
pub struct Header {
    pub name: String,
    pub value: String,
}

#[derive(Clone, Debug, Default)]
pub struct Message {
    pub subject: String,
    pub from: Vec<Address>,
    pub to: Vec<Address>,
    pub cc: Vec<Address>,
    pub bcc: Vec<Address>,
    pub reply_to: Vec<Address>,
    /// The `Date` header as written, kept because it carries the sender's own
    /// timezone, which an epoch can't.
    pub date: String,
    /// Milliseconds since the epoch, or 0 when no date could be read.
    pub date_epoch_ms: i64,
    pub message_id: String,
    pub body_text: String,
    pub body_html: String,
    pub headers: Vec<Header>,
    pub attachments: Vec<Attachment>,
    /// `"eml"` or `"msg"`.
    pub format: String,
}

impl Message {
    /// Everything the header table should show, in the order a reader expects,
    /// rather than the order the transport happened to stack them in.
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|h| h.name.eq_ignore_ascii_case(name))
            .map(|h| h.value.as_str())
    }
}

/// Chooses a parser by extension, then by content sniffing.
///
/// The sniff matters: mail exported by a script is regularly given the wrong
/// extension, and an OLE header is unmistakable (8 magic bytes), so trusting it
/// over the file name costs nothing.
pub fn parse_bytes(bytes: &[u8], hint_ext: &str) -> Result<Message, String> {
    const OLE_MAGIC: &[u8] = &[0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1];
    if bytes.starts_with(OLE_MAGIC) {
        return msg::parse(bytes);
    }
    if hint_ext.eq_ignore_ascii_case("msg") {
        return Err("This .msg file isn't an Outlook compound file.".into());
    }
    Ok(eml::parse(bytes))
}

/// The bytes of one attachment, chosen the same way [`parse_bytes`] chooses a
/// parser so the indices line up with the message the caller was shown.
pub fn attachment_bytes(
    bytes: &[u8],
    hint_ext: &str,
    index: u32,
) -> Result<(String, Vec<u8>), String> {
    const OLE_MAGIC: &[u8] = &[0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1];
    if bytes.starts_with(OLE_MAGIC) {
        return msg::attachment_bytes(bytes, index);
    }
    if hint_ext.eq_ignore_ascii_case("msg") {
        return Err("This .msg file isn't an Outlook compound file.".into());
    }
    eml::attachment_bytes(bytes, index)
}
