use std::f64::consts::TAU;

use ttfx::engine::character::CharId;
use ttfx::engine::ctx::{EffectHooks, EngineCtx};
use ttfx::engine::effect::Effect;
use ttfx::engine::error::EngineError;
use ttfx::engine::events::EffectCallback;
use ttfx::utils::geometry::Coord;

use super::common::{smooth, InkBank, Stage};

/// Three independently phased, vertically feathered light curtains drift
/// across the canvas. Their shimmer subsides into a left-to-right art reveal.
#[derive(Default)]
pub struct Aurora {
    stage: Option<Stage>,
    inks: Option<InkBank>,
    tick: u32,
    phase: f64,
    speed: f64,
    columns: usize,
    tails: usize,
}

impl EffectHooks for Aurora {
    fn dispatch_callback(&mut self, _: &mut EngineCtx, _: CharId, _: &EffectCallback) {}
}

impl Effect for Aurora {
    fn build(&mut self, ctx: &mut EngineCtx) -> Result<(), EngineError> {
        let palettes = [
            [[51, 240, 174], [70, 166, 255], [213, 110, 247]],
            [[78, 216, 242], [134, 244, 170], [167, 128, 245]],
            [[107, 231, 162], [41, 191, 205], [222, 158, 243]],
        ];
        let palette = palettes[ctx.rng.choice_index(palettes.len())];
        self.tick = 0;
        self.phase = ctx.rng.uniform(0.0, TAU);
        self.speed = ctx.rng.uniform(0.0045, 0.0075);
        self.columns = (ctx.terminal.canvas.width.max(1) as usize).min(112);
        self.tails = (ctx.terminal.canvas.height.max(1) as usize).min(12);
        let mut stage = Stage::new(ctx, self.columns * self.tails * 3, &palette);
        for point in &mut stage.art {
            let across = (point.coord.column - 1) as f64 / (stage.width - 1).max(1) as f64;
            point.reveal_at = 245 + (across * 120.0 + point.jitter * 25.0) as u32;
        }
        self.inks = Some(InkBank::new(
            &["·", "░", "▒", "▓"],
            &palette,
            stage.background,
        ));
        self.stage = Some(stage);
        Ok(())
    }

    fn next_frame(&mut self, ctx: &mut EngineCtx) -> Option<String> {
        if self.tick >= 510 {
            return None;
        }
        let stage = self.stage.as_mut()?;
        let inks = self.inks.as_ref()?;
        stage.begin_frame();
        let t = f64::from(self.tick) * self.speed;
        let envelope = smooth(f64::from(self.tick + 1) / 42.0)
            * (1.0 - smooth((f64::from(self.tick) - 330.0) / 90.0));
        if envelope > 0.001 {
            for band in 0..3 {
                for column in 0..self.columns {
                    let across = column as f64 / self.columns.saturating_sub(1).max(1) as f64;
                    let x = 1 + (across * (stage.width - 1) as f64).round() as i64;
                    let phase = self.phase + band as f64 * 1.8;
                    let fold = (across * 5.8 + phase + t).sin() * 0.15
                        + (across * 11.0 - t * 0.62 + phase).sin() * 0.055;
                    let ridge = stage.height as f64 * (0.25 + band as f64 * 0.13 + fold);
                    let shimmer = 0.65 + 0.35 * (across * 31.0 + t * 3.0 + phase).sin();
                    for tail in 0..self.tails {
                        let fraction = tail as f64 / self.tails.saturating_sub(1).max(1) as f64;
                        let y = (ridge + fraction * stage.height as f64 * 0.36).round() as i64;
                        let brightness = (1.0 - fraction).powf(1.3) * shimmer * envelope;
                        if brightness < 0.035 {
                            continue;
                        }
                        let glyph = if brightness > 0.7 {
                            3
                        } else if brightness > 0.4 {
                            2
                        } else if brightness > 0.16 {
                            1
                        } else {
                            0
                        };
                        stage.plot(
                            ctx,
                            Coord::new(x, y.max(1)),
                            inks.get(band, brightness, glyph),
                        );
                    }
                }
            }
        }
        stage.finish_frame(ctx, self.tick);
        self.tick += 1;
        Some(ctx.frame())
    }
}
