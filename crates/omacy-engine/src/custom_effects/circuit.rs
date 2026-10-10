use ttfx::engine::character::CharId;
use ttfx::engine::ctx::{EffectHooks, EngineCtx};
use ttfx::engine::effect::Effect;
use ttfx::engine::error::EngineError;
use ttfx::engine::events::EffectCallback;
use ttfx::utils::geometry::Coord;

use super::common::{smooth, InkBank, Stage};
use super::MAX_SYNTHETIC_CELLS;

struct Trace {
    path: Vec<Coord>,
    symbols: Vec<usize>,
    delay: u32,
    duration: u32,
    color: usize,
}

/// Seeded right-angle routes carry bright pulses from canvas edges into the
/// artwork. Glyph groups illuminate when their nearest route delivers a pulse.
#[derive(Default)]
pub struct Circuit {
    stage: Option<Stage>,
    inks: Option<InkBank>,
    traces: Vec<Trace>,
    tick: u32,
}

fn segment(path: &mut Vec<Coord>, end: Coord) {
    let mut position = *path.last().expect("route has an origin");
    while position != end {
        // Each step changes one axis, including degenerate one-row/column
        // canvases. The route builder supplies axis-aligned segments.
        if position.column != end.column {
            position.column += (end.column - position.column).signum();
        } else {
            position.row += (end.row - position.row).signum();
        }
        path.push(position);
    }
}

fn wire_symbol(path: &[Coord], index: usize) -> usize {
    if index == 0 || index + 1 == path.len() {
        return 6;
    }
    let before = path[index - 1];
    let here = path[index];
    let after = path[index + 1];
    if before.row == after.row {
        return 0;
    }
    if before.column == after.column {
        return 1;
    }
    let north = before.row > here.row || after.row > here.row;
    let east = before.column > here.column || after.column > here.column;
    match (north, east) {
        (true, true) => 2,
        (true, false) => 3,
        (false, true) => 4,
        (false, false) => 5,
    }
}

impl EffectHooks for Circuit {
    fn dispatch_callback(&mut self, _: &mut EngineCtx, _: CharId, _: &EffectCallback) {}
}

impl Effect for Circuit {
    fn build(&mut self, ctx: &mut EngineCtx) -> Result<(), EngineError> {
        let palettes = [
            [[75, 238, 185], [97, 190, 239], [240, 193, 95]],
            [[240, 184, 87], [130, 221, 188], [129, 167, 233]],
            [[164, 132, 240], [79, 230, 212], [239, 173, 122]],
        ];
        let palette = palettes[ctx.rng.choice_index(palettes.len())];
        let width = ctx.terminal.canvas.width.max(1);
        let height = ctx.terminal.canvas.height.max(1);
        let count = ((width * height) as usize / 160)
            .clamp(6, 18)
            .min((MAX_SYNTHETIC_CELLS / (width + height + 5) as usize).max(1));
        self.tick = 0;
        self.traces.clear();
        for _ in 0..count {
            let target = if ctx.terminal.input_characters.is_empty() {
                Coord::new((width + 1) / 2, (height + 1) / 2)
            } else {
                let id = ctx.terminal.input_characters
                    [ctx.rng.choice_index(ctx.terminal.input_characters.len())];
                ctx.terminal.arena[id.0 as usize].input_coord
            };
            let edge = ctx.rng.choice_index(4);
            let origin = match edge {
                0 => Coord::new(1, ctx.rng.randint(1, height)),
                1 => Coord::new(width, ctx.rng.randint(1, height)),
                2 => Coord::new(ctx.rng.randint(1, width), 1),
                _ => Coord::new(ctx.rng.randint(1, width), height),
            };
            let bend = if edge < 2 {
                Coord::new(target.column, origin.row)
            } else {
                Coord::new(origin.column, target.row)
            };
            let mut path = vec![origin];
            segment(&mut path, bend);
            segment(&mut path, target);
            let symbols = (0..path.len())
                .map(|index| wire_symbol(&path, index))
                .collect();
            self.traces.push(Trace {
                path,
                symbols,
                delay: ctx.rng.randint(8, 115) as u32,
                duration: ctx.rng.randint(90, 165) as u32,
                color: ctx.rng.choice_index(palette.len()),
            });
        }
        let particle_count = self.traces.iter().map(|trace| trace.path.len() + 4).sum();
        let mut stage = Stage::new(ctx, particle_count, &palette);
        for point in &mut stage.art {
            let trace = self
                .traces
                .iter()
                .min_by_key(|trace| {
                    let target = trace.path.last().expect("route has a target");
                    (target.column - point.coord.column).abs()
                        + (target.row - point.coord.row).abs()
                })
                .expect("at least one route");
            let target = trace.path.last().expect("route has a target");
            let distance =
                (target.column - point.coord.column).abs() + (target.row - point.coord.row).abs();
            point.reveal_at = (trace.delay
                + trace.duration
                + (distance as f64 / (width + height) as f64 * 80.0 + point.jitter * 22.0) as u32)
                .min(410);
        }
        self.inks = Some(InkBank::new(
            &["─", "│", "└", "┘", "┌", "┐", "○", "●", "+"],
            &palette,
            stage.background,
        ));
        self.stage = Some(stage);
        Ok(())
    }

    fn next_frame(&mut self, ctx: &mut EngineCtx) -> Option<String> {
        if self.tick >= 540 {
            return None;
        }
        let stage = self.stage.as_mut()?;
        let inks = self.inks.as_ref()?;
        stage.begin_frame();
        let envelope = 1.0 - smooth((f64::from(self.tick) - 360.0) / 90.0);
        if envelope > 0.001 {
            for trace in &self.traces {
                if self.tick < trace.delay {
                    continue;
                }
                let progress =
                    (f64::from(self.tick - trace.delay) / f64::from(trace.duration)).min(1.0);
                let head = (progress * trace.path.len().saturating_sub(1) as f64).floor() as usize;
                for (index, &coordinate) in trace.path.iter().enumerate().take(head + 1) {
                    let brightness = if index == head && progress < 1.0 {
                        0.95
                    } else {
                        0.25
                    };
                    stage.plot(
                        ctx,
                        coordinate,
                        inks.get(trace.color, brightness * envelope, trace.symbols[index]),
                    );
                }
                // A second pulse follows the established wire; it never
                // controls completion and cannot turn a route into a loop.
                for lag in [0_u32, 45] {
                    let elapsed = self.tick.saturating_sub(trace.delay);
                    if elapsed < lag || elapsed - lag > trace.duration {
                        continue;
                    }
                    let pulse = (f64::from(elapsed - lag) / f64::from(trace.duration)
                        * trace.path.len().saturating_sub(1) as f64)
                        .floor() as usize;
                    stage.plot(ctx, trace.path[pulse], inks.get(trace.color, envelope, 7));
                    if pulse > 0 {
                        stage.plot(
                            ctx,
                            trace.path[pulse - 1],
                            inks.get(trace.color, envelope * 0.7, 8),
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
