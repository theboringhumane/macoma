//! One registry for the unchanged upstream effects and Macarchy originals.

use std::sync::OnceLock;
use ttfx::effects::EffectCommand;
use ttfx::engine::effect::Effect;

use crate::custom_effects::{Aurora, Circuit, Starfield};

const CUSTOM_NAMES: &[&str] = &["aurora", "starfield", "circuit"];

pub fn names() -> &'static [&'static str] {
    static NAMES: OnceLock<Vec<&'static str>> = OnceLock::new();
    NAMES.get_or_init(|| {
        EffectCommand::NAMES
            .iter()
            .chain(CUSTOM_NAMES.iter())
            .copied()
            .collect()
    })
}

pub fn contains(name: &str) -> bool {
    names().contains(&name)
}

pub fn create(name: &str) -> Option<Box<dyn Effect>> {
    match name {
        "aurora" => Some(Box::new(Aurora::default())),
        "starfield" => Some(Box::new(Starfield::default())),
        "circuit" => Some(Box::new(Circuit::default())),
        _ => EffectCommand::from_name(name),
    }
}
