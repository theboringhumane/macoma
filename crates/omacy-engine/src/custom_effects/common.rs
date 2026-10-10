use std::collections::HashMap;
use std::rc::Rc;

use ttfx::engine::animation::{CharacterVisual, VisualParams};
use ttfx::engine::character::CharId;
use ttfx::engine::ctx::EngineCtx;
use ttfx::utils::ansi::ColorCode;
use ttfx::utils::geometry::Coord;

use super::MAX_SYNTHETIC_CELLS;

pub type Rgb = [u8; 3];

pub fn mix(a: Rgb, b: Rgb, amount: f64) -> Rgb {
    let amount = amount.clamp(0.0, 1.0);
    std::array::from_fn(|index| {
        (f64::from(a[index]) * (1.0 - amount) + f64::from(b[index]) * amount).round() as u8
    })
}

pub fn smooth(value: f64) -> f64 {
    let value = value.clamp(0.0, 1.0);
    value * value * (3.0 - 2.0 * value)
}

fn visual(symbol: &str, color: Rgb) -> Rc<CharacterVisual> {
    Rc::new(CharacterVisual::new(
        symbol,
        VisualParams {
            fg_color_code: Some(ColorCode::Rgb(format!(
                "{:02x}{:02x}{:02x}",
                color[0], color[1], color[2]
            ))),
            ..VisualParams::default()
        },
    ))
}

/// Small immutable visual tables avoid allocating strings for every particle
/// on every tick. Brightness is quantized to 32 levels, including background.
pub struct InkBank {
    symbols: usize,
    visuals: Vec<Rc<CharacterVisual>>,
}

impl InkBank {
    pub fn new(symbols: &[&str], colors: &[Rgb], background: Rgb) -> Self {
        let mut visuals = Vec::with_capacity(symbols.len() * colors.len() * 32);
        for &color in colors {
            for level in 0..32 {
                for symbol in symbols {
                    visuals.push(visual(
                        symbol,
                        mix(background, color, f64::from(level) / 31.0),
                    ));
                }
            }
        }
        Self {
            symbols: symbols.len(),
            visuals,
        }
    }

    pub fn get(&self, color: usize, brightness: f64, symbol: usize) -> Rc<CharacterVisual> {
        let level = (brightness.clamp(0.0, 1.0) * 31.0).round() as usize;
        self.visuals[(color * 32 + level) * self.symbols + symbol].clone()
    }
}

pub struct ArtPoint {
    pub coord: Coord,
    pub reveal_at: u32,
    pub jitter: f64,
    id: CharId,
    glow: Rc<CharacterVisual>,
    settled: Rc<CharacterVisual>,
    appearance: u8,
}

/// Owns only native character IDs. The terminal remains the single authority
/// for canvas clipping, layer order, ANSI output, and the packed C cell grid.
pub struct Stage {
    pub width: i64,
    pub height: i64,
    pub background: Rgb,
    pub art: Vec<ArtPoint>,
    particles: Vec<CharId>,
    used: usize,
    previously_used: usize,
}

impl Stage {
    pub fn new(ctx: &mut EngineCtx, particle_count: usize, palette: &[Rgb]) -> Self {
        let (r, g, b) = ctx.terminal.config.terminal_background_color.rgb_ints();
        let background = [r, g, b];
        let light_background = u32::from(r) + u32::from(g) + u32::from(b) > 480;
        let ink = if light_background {
            [16, 24, 36]
        } else {
            [230, 245, 255]
        };
        let width = ctx.terminal.canvas.width.max(1);
        let height = ctx.terminal.canvas.height.max(1);
        let ids = ctx.terminal.input_characters.clone();
        let mut art = Vec::with_capacity(ids.len());
        let mut visuals = HashMap::<(String, Rgb), Rc<CharacterVisual>>::new();
        for id in ids {
            let character = &mut ctx.terminal.arena[id.0 as usize];
            character.layer = 2;
            character.motion.set_coordinate(character.input_coord);
            let band = (character.input_coord.column.max(0) as usize * palette.len()
                / width as usize)
                .min(palette.len() - 1);
            let color = mix(
                palette[band],
                ink,
                if light_background { 0.85 } else { 0.72 },
            );
            let settled = visuals
                .entry((character.input_symbol.clone(), color))
                .or_insert_with(|| visual(&character.input_symbol, color))
                .clone();
            let glow = visuals
                .entry((character.input_symbol.clone(), ink))
                .or_insert_with(|| visual(&character.input_symbol, ink))
                .clone();
            art.push(ArtPoint {
                id,
                coord: character.input_coord,
                reveal_at: 0,
                jitter: ctx.rng.random(),
                glow,
                settled,
                appearance: 0,
            });
            ctx.terminal.set_character_visibility(id, false);
        }
        let particles = (0..particle_count.min(MAX_SYNTHETIC_CELLS))
            .map(|_| ctx.terminal.add_character("·", Coord::new(1, 1)))
            .collect();
        Self {
            width,
            height,
            background,
            art,
            particles,
            used: 0,
            previously_used: 0,
        }
    }

    pub fn begin_frame(&mut self) {
        self.used = 0;
    }

    pub fn plot(&mut self, ctx: &mut EngineCtx, coord: Coord, appearance: Rc<CharacterVisual>) {
        if coord.column < 1 || coord.column > self.width || coord.row < 1 || coord.row > self.height
        {
            return;
        }
        let Some(&id) = self.particles.get(self.used) else {
            return;
        };
        self.used += 1;
        let character = &mut ctx.terminal.arena[id.0 as usize];
        character.motion.set_coordinate(coord);
        character.animation.current_character_visual = appearance;
        ctx.terminal.set_character_visibility(id, true);
    }

    pub fn finish_frame(&mut self, ctx: &mut EngineCtx, tick: u32) {
        for &id in &self.particles[self.used..self.previously_used.max(self.used)] {
            ctx.terminal.set_character_visibility(id, false);
        }
        self.previously_used = self.used;
        for point in &mut self.art {
            let appearance = if tick < point.reveal_at {
                0
            } else if tick < point.reveal_at + 24 {
                1
            } else {
                2
            };
            if appearance == point.appearance {
                continue;
            }
            point.appearance = appearance;
            if appearance == 0 {
                ctx.terminal.set_character_visibility(point.id, false);
            } else {
                let character = &mut ctx.terminal.arena[point.id.0 as usize];
                character.animation.current_character_visual = if appearance == 1 {
                    point.glow.clone()
                } else {
                    point.settled.clone()
                };
                ctx.terminal.set_character_visibility(point.id, true);
            }
        }
    }
}
