//! The surface Dart calls through `flutter_rust_bridge`.
//!
//! Every public function here takes and returns bridge-compatible types.
//! Errors surface as `Result<_, String>` so they arrive in Dart as a thrown
//! exception carrying a readable message, rather than an opaque error code.

pub mod archive;
pub mod bridge;
pub mod dedupe;
pub mod fileops;
pub mod hashing;
pub mod listing;
pub mod quick;
pub mod search;
pub mod thumbnail;
pub mod trash;
