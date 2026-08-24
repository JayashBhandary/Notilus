//! Mail files, in the shape the bridge can carry.
//!
//! The parsers in [`crate::email`] work on bytes and their own types; this
//! module reads the file, converts, and adds the two things a *preview* needs
//! that a parser doesn't: a cap on how much it will read, and a safe way to
//! save one attachment to a folder the user picked.

use std::fs;
use std::path::{Path, PathBuf};

use crate::email::{self, eml::sanitise_filename};

/// Largest mail file that will be parsed.
///
/// Parsing decodes the whole message into memory — twice, briefly, for a
/// base64 body — so this bounds the app's footprint. Mail servers cap
/// attachments an order of magnitude below this; anything larger is a mailbox
/// archive that was given the wrong extension.
const MAX_FILE_BYTES: u64 = 256 * 1024 * 1024;

#[derive(Clone, Debug)]
pub struct EmailAddressInfo {
    pub name: String,
    pub email: String,
}

#[derive(Clone, Debug)]
pub struct EmailAttachmentInfo {
    pub index: u32,
    pub name: String,
    pub mime: String,
    pub size: u64,
    pub content_id: String,
    pub is_inline: bool,
}

#[derive(Clone, Debug)]
pub struct EmailHeaderInfo {
    pub name: String,
    pub value: String,
}

#[derive(Clone, Debug)]
pub struct EmailMessageInfo {
    pub subject: String,
    pub from: Vec<EmailAddressInfo>,
    pub to: Vec<EmailAddressInfo>,
    pub cc: Vec<EmailAddressInfo>,
    pub bcc: Vec<EmailAddressInfo>,
    pub reply_to: Vec<EmailAddressInfo>,
    pub date: String,
    /// Milliseconds since the epoch, or 0 when the message carried no date.
    pub date_epoch_ms: i64,
    pub message_id: String,
    pub body_text: String,
    pub body_html: String,
    pub headers: Vec<EmailHeaderInfo>,
    pub attachments: Vec<EmailAttachmentInfo>,
    /// `"eml"` or `"msg"`.
    pub format: String,
}

/// One attachment's bytes, for rendering inline or handing to the OS.
#[derive(Clone, Debug)]
pub struct EmailAttachmentData {
    pub name: String,
    pub mime: String,
    pub bytes: Vec<u8>,
}

pub fn read_email(path: String) -> Result<EmailMessageInfo, String> {
    let bytes = read_capped(&path)?;
    let message = email::parse_bytes(&bytes, extension_of(&path).as_str())?;
    Ok(convert(message))
}

pub fn read_email_attachment(
    path: String,
    index: u32,
) -> Result<EmailAttachmentData, String> {
    let bytes = read_capped(&path)?;
    let ext = extension_of(&path);
    let (name, data) = email::attachment_bytes(&bytes, &ext, index)?;
    // The listing already knows the MIME type; re-deriving it here keeps this
    // call self-contained for callers that only have an index.
    let mime = email::parse_bytes(&bytes, &ext)
        .ok()
        .and_then(|m| m.attachments.get(index as usize).map(|a| a.mime.clone()))
        .unwrap_or_else(|| "application/octet-stream".into());
    Ok(EmailAttachmentData {
        name,
        mime,
        bytes: data,
    })
}

/// Writes attachment `index` into `dest_dir` and returns the path written.
///
/// The name comes from the message, which means it comes from whoever sent it.
/// It is stripped to a bare filename before use, and a collision is resolved by
/// numbering rather than by overwriting whatever was already there.
pub fn save_email_attachment(
    path: String,
    index: u32,
    dest_dir: String,
) -> Result<String, String> {
    let bytes = read_capped(&path)?;
    let (name, data) = email::attachment_bytes(&bytes, &extension_of(&path), index)?;

    let dir = PathBuf::from(&dest_dir);
    if !dir.is_dir() {
        return Err(format!("{dest_dir} isn't a folder."));
    }
    let safe = sanitise_filename(&name);
    let safe = if safe.is_empty() {
        format!("attachment-{}", index + 1)
    } else {
        safe
    };
    let target = unique_path(&dir, &safe);
    fs::write(&target, &data)
        .map_err(|e| format!("Couldn't save {}: {e}", target.display()))?;
    Ok(target.to_string_lossy().to_string())
}

fn read_capped(path: &str) -> Result<Vec<u8>, String> {
    let meta = fs::metadata(path).map_err(|e| format!("Can't open {path}: {e}"))?;
    if !meta.is_file() {
        return Err(format!("{path} isn't a file."));
    }
    if meta.len() > MAX_FILE_BYTES {
        return Err(format!(
            "This message is {:.0} MB, larger than the {} MB preview limit.",
            meta.len() as f64 / (1024.0 * 1024.0),
            MAX_FILE_BYTES / (1024 * 1024)
        ));
    }
    fs::read(path).map_err(|e| format!("Can't read {path}: {e}"))
}

fn extension_of(path: &str) -> String {
    Path::new(path)
        .extension()
        .map(|e| e.to_string_lossy().to_string())
        .unwrap_or_default()
}

/// `report.pdf`, then `report (2).pdf`, … — the same collision rule the file
/// operations use, so saving an attachment behaves like any other copy.
fn unique_path(dir: &Path, name: &str) -> PathBuf {
    let candidate = dir.join(name);
    if !candidate.exists() {
        return candidate;
    }
    let (stem, ext) = match name.rfind('.') {
        Some(dot) if dot > 0 => (&name[..dot], &name[dot..]),
        _ => (name, ""),
    };
    for n in 2..1000 {
        let candidate = dir.join(format!("{stem} ({n}){ext}"));
        if !candidate.exists() {
            return candidate;
        }
    }
    dir.join(format!("{stem} ({}){ext}", std::process::id()))
}

fn convert(message: email::Message) -> EmailMessageInfo {
    fn addresses(list: Vec<email::Address>) -> Vec<EmailAddressInfo> {
        list.into_iter()
            .map(|a| EmailAddressInfo {
                name: a.name,
                email: a.email,
            })
            .collect()
    }
    EmailMessageInfo {
        subject: message.subject,
        from: addresses(message.from),
        to: addresses(message.to),
        cc: addresses(message.cc),
        bcc: addresses(message.bcc),
        reply_to: addresses(message.reply_to),
        date: message.date,
        date_epoch_ms: message.date_epoch_ms,
        message_id: message.message_id,
        body_text: message.body_text,
        body_html: message.body_html,
        headers: message
            .headers
            .into_iter()
            .map(|h| EmailHeaderInfo {
                name: h.name,
                value: h.value,
            })
            .collect(),
        attachments: message
            .attachments
            .into_iter()
            .map(|a| EmailAttachmentInfo {
                index: a.index,
                name: a.name,
                mime: a.mime,
                size: a.size,
                content_id: a.content_id,
                is_inline: a.is_inline,
            })
            .collect(),
        format: message.format,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_an_eml_off_disk() {
        let dir = std::env::temp_dir().join(format!("notilus-eml-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("m.eml");
        fs::write(
            &path,
            b"Subject: Hello\r\nFrom: a@b.test\r\nContent-Type: text/plain\r\n\r\nbody",
        )
        .unwrap();

        let message = read_email(path.to_string_lossy().to_string()).unwrap();
        assert_eq!(message.subject, "Hello");
        assert_eq!(message.body_text, "body");
        assert_eq!(message.format, "eml");
        fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn saving_an_attachment_never_overwrites() {
        let dir = std::env::temp_dir().join(format!("notilus-att-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("note.txt"), b"already here").unwrap();

        let mail = dir.join("m.eml");
        fs::write(
            &mail,
            b"Content-Type: multipart/mixed; boundary=B\r\n\r\n\
--B\r\nContent-Type: text/plain\r\n\r\nbody\r\n\
--B\r\nContent-Type: text/plain; name=\"note.txt\"\r\n\
Content-Disposition: attachment; filename=\"note.txt\"\r\n\r\nfrom the mail\r\n--B--\r\n",
        )
        .unwrap();

        let written = save_email_attachment(
            mail.to_string_lossy().to_string(),
            0,
            dir.to_string_lossy().to_string(),
        )
        .unwrap();
        assert!(written.ends_with("note (2).txt"), "got {written}");
        assert_eq!(fs::read_to_string(dir.join("note.txt")).unwrap(), "already here");
        fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn a_missing_file_is_a_readable_error() {
        let err = read_email("/definitely/not/here.eml".into()).unwrap_err();
        assert!(err.contains("Can't open"), "got {err}");
    }
}
