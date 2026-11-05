//! Isolated native candidate; not registered with Flutter or a live application.
#![cfg(unix)]
#[allow(dead_code)]
#[path = "upstream/core.rs"]
pub mod core;
#[path = "upstream/desktop_text.rs"]
mod desktop_text;
#[allow(dead_code)]
#[path = "upstream/native.rs"]
pub mod native;
#[allow(dead_code)]
#[path = "upstream/zcode_file_lock.rs"]
mod zcode_file_lock;
mod error {
    #[derive(Debug)]
    pub enum AppError {
        Config(String),
    }
    impl std::fmt::Display for AppError {
        fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            match self {
                Self::Config(value) => write!(f, "配置错误: {value}"),
            }
        }
    }
}
pub mod switch;
#[cfg(test)]
mod tests;

pub mod ffi;

pub mod owner_context;
pub mod runtime_context;
pub mod owner_context_ffi;
#[cfg(test)]
mod owner_context_tests;

pub mod promotion_owner;
