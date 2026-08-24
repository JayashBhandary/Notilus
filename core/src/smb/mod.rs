//! SMB2 — a file server and a client, sharing one implementation of the wire
//! protocol.
//!
//! Notilus needs both halves: the server so a folder can be shared with any
//! machine on the network, and the client so another machine's share appears
//! next to the local folders. Building them together means every structure is
//! written once and exercised from both sides, which is also what makes the
//! round-trip tests in [`client`] worth anything.
//!
//! Dialects 2.0.2 through 3.1.1, NTLMv2 authentication, and packet signing are
//! implemented. Encryption, leases, DFS and multi-channel are not, and the
//! server declines them rather than pretending.

pub mod client;
pub mod crypto;
pub mod ntlm;
pub mod proto;
pub mod rpc;
pub mod server;
pub mod share;
pub mod spnego;
pub mod wire;

#[cfg(test)]
mod round_trip;
