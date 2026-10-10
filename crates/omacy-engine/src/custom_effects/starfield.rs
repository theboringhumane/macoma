use ttfx::engine::character::CharId;
use ttfx::engine::ctx::{EffectHooks, EngineCtx};
use ttfx::engine::effect::Effect;
use ttfx::engine::error::EngineError;
use ttfx::engine::events::EffectCallback;
use ttfx::utils::geometry::Coord;

use super::common::{smooth, InkBank, Stage};

struct Star {
    x: f64,
    y: f64,
    depth: f64,
    velocity: f64,
    color: usize,
}

/// A sparse perspective field flies out from a seeded vanishing point. Stars
/// have independent depth and velocity; the art resolves as their trails fade.
#[derive(Default)]
pub struct Starfield {
    stage: Option<Stage>,
    inks: Option<InkBank>,
    stars: Vec<Star>,
    tick: u32,
    center_x: f64,
    center_y: f64,
}

impl EffectHooks for Starfield {
    fn dispatch_callback(&mut self, _: &mut EngineCtx, _: CharId, _: &EffectCallback) {}
}

impl Effect for Starfield {
    fn build(&mut self, ctx: &mut EngineCtx) -> Result<(), EngineError> {
        let palettes = [
            [[226, 243, 255], [133, 186, 255], [196, 158, 255]],
            [[247, 239, 206], [142, 209, 236], [243, 173, 164]],
            [[193, 241, 248], [160, 172, 242], [248, 205, 233]],
        ];
        let palette = palettes[ctx.rng.choice_index(palettes.len())];
        let width = ctx.terminal.canvas.width.max(1);
        let height = ctx.terminal.canvas.height.max(1);
        let area = (width * height) as usize;
        let count = (area / 38).clamp(16, 128).min(area);
        self.tick = 0;
        self.center_x = 1.0 + (width - 1) as f64 * ctx.rng.uniform(0.35, 0.65);
        self.center_y = 1.0 + (height - 1) as f64 * ctx.rng.uniform(0.35, 0.65);
        self.stars.clear();
        for _ in 0..count {
            self.stars.push(Star {
                x: ctx.rng.uniform(-1.0, 1.0),
                y: ctx.rng.uniform(-1.0, 1.0),
                depth: ctx.rng.uniform(0.0, 1.0),
                velocity: ctx.rng.uniform(0.003, 0.009),
                color: ctx.rng.choice_index(palette.len()),
            });
        }
        let mut stage = Stage::new(ctx, count * 4, &palette);
        for point in &mut stage.art {
            let x = (point.coord.column as f64 - self.center_x) / width as f64;
            let y = (point.coord.row as f64 - self.center_y) / height as f64;
            point.reveal_at = 235 + (x.hypot(y).min(1.0) * 90.0 + point.jitter * 28.0) as u32;
        }
        self.inks = Some(InkBank::new(
            &["·", "+", "*", "─", "│", "╱", "╲"],
            &palette,
            stage.background,
        ));
        self.stage = Some(stage);
        Ok(())
    }

    fn next_frame(&mut self, ctx: &mut EngineCtx) -> Option<String> {
        if self.tick >= 480 {
            return None;
        }
        let stage = self.stage.as_mut()?;
        let inks = self.inks.as_ref()?;
        stage.begin_frame();
        let envelope = smooth(f64::from(self.tick + 1) / 32.0)
            * (1.0 - smooth((f64::from(self.tick) - 290.0) / 100.0));
        if envelope > 0.001 {
            for star in &self.stars {
                let depth = (star.depth - f64::from(self.tick) * star.velocity).rem_euclid(1.0);
                let brightness = (0.2 + (1.0 - depth).powi(2) * 0.8) * envelope;
                let direction = if star.x.abs() > star.y.abs() * 2.0 {
                    3
                } else if star.y.abs() > star.x.abs() * 2.0 {
                    4
                } else if star.x * star.y > 0.0 {
                    5
                } else {
                    6
                };
                // Paint the older, darker tail first, then the brighter head.
                for tail in (0..4).rev() {
                    if tail > 0 && depth > 0.38 {
                        continue;
                    }
                    let tail_depth = depth + tail as f64 * star.velocity * 3.5;
                    let scale = 0.15 / (tail_depth + 0.075);
                    let x = self.center_x + star.x * stage.width as f64 * scale;
                    let y = self.center_y + star.y * stage.height as f64 * scale;
                    let symbol = if tail > 0 {
                        direction
                    } else if depth < 0.15 {
                        2
                    } else if depth < 0.42 {
                        1
                    } else {
                        0
                    };
                    stage.plot(
                        ctx,
                        Coord::new(x.round() as i64, y.round() as i64),
                        inks.get(star.color, brightness / (1.0 + tail as f64 * 0.7), symbol),
                    );
                }
            }
        }
        stage.finish_frame(ctx, self.tick);
        self.tick += 1;
        Some(ctx.frame())
    }
}
