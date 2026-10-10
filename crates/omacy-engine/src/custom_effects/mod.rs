//! Original Macarchy effects. These use ttfx's cell transport and seeded RNG,
//! but do not delegate their choreography to upstream effect implementations.

mod aurora;
mod circuit;
mod common;
mod starfield;

pub use aurora::Aurora;
pub use circuit::Circuit;
pub use starfield::Starfield;

/// A fixed ceiling independent of artwork length and display resolution.
const MAX_SYNTHETIC_CELLS: usize = 4096;
