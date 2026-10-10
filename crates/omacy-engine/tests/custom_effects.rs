//! Native-cell acceptance for Macarchy's original effects. These tests exercise
//! the public session lifecycle rather than each effect's animation machinery.

use crate::abi::{OmacyCell, OmacyFrame, OMACY_CELL_HAS_BACKGROUND, OMACY_CELL_HAS_GLYPH};
use crate::session::{ClockKind, Session};
use std::collections::{BTreeMap, HashSet};
use std::hash::{Hash, Hasher};

const ORIGINALS: [&str; 3] = ["aurora", "starfield", "circuit"];
const DT: f64 = 1.0 / 60.0;
const MAX_CYCLE_FRAMES: usize = 1_800;
const BACKGROUND: [u8; 4] = [17, 19, 24, 255];

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
struct Cell {
    glyph: u32,
    foreground: [u8; 4],
    background: [u8; 4],
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
struct NativeFrame {
    cols: u32,
    rows: u32,
    clear: [u8; 4],
    cells: Vec<Cell>,
}

impl NativeFrame {
    fn copy(frame: OmacyFrame) -> Self {
        assert!(frame.cols > 0 && frame.rows > 0);
        assert!(!frame.cells.is_null(), "native frame lost its cell buffer");
        let count = (frame.cols * frame.rows) as usize;
        assert!(
            count <= 32_768,
            "native frame exceeds the public geometry limit"
        );
        let cells = unsafe { std::slice::from_raw_parts(frame.cells, count) };
        let cells = cells.iter().map(Self::copy_visible_cell).collect();
        Self {
            cols: frame.cols,
            rows: frame.rows,
            clear: [frame.clear_r, frame.clear_g, frame.clear_b, frame.clear_a],
            cells,
        }
    }

    fn copy_visible_cell(cell: &OmacyCell) -> Cell {
        assert_eq!(cell.flags, 0, "native frame contains unsupported flags");
        assert_eq!(
            cell.occupancy & !3,
            0,
            "native frame contains unsupported occupancy"
        );
        let has_glyph = cell.occupancy & OMACY_CELL_HAS_GLYPH != 0;
        if has_glyph {
            assert!(
                char::from_u32(cell.glyph).is_some(),
                "native frame contains an invalid scalar"
            );
        }
        // Ignore fields the renderer does not paint. A changed unused color
        // must not let a visually frozen animation pass this test.
        let visible_glyph =
            has_glyph && cell.glyph != 0 && cell.glyph != u32::from(' ') && cell.fg_a > 0;
        let visible_background = cell.occupancy & OMACY_CELL_HAS_BACKGROUND != 0 && cell.bg_a > 0;
        Cell {
            glyph: if visible_glyph { cell.glyph } else { 0 },
            foreground: if visible_glyph {
                [cell.fg_r, cell.fg_g, cell.fg_b, cell.fg_a]
            } else {
                [0; 4]
            },
            background: if visible_background {
                [cell.bg_r, cell.bg_g, cell.bg_b, cell.bg_a]
            } else {
                [0; 4]
            },
        }
    }

    fn digest(&self) -> u64 {
        let mut hasher = std::collections::hash_map::DefaultHasher::new();
        self.hash(&mut hasher);
        hasher.finish()
    }

    fn glyphs(&self) -> BTreeMap<(u32, u32), char> {
        self.cells
            .iter()
            .enumerate()
            .filter_map(|(index, cell)| {
                (cell.glyph != 0).then(|| {
                    (
                        (index as u32 % self.cols, index as u32 / self.cols),
                        char::from_u32(cell.glyph).unwrap(),
                    )
                })
            })
            .collect()
    }

    fn has_visible_content(&self) -> bool {
        self.cells.iter().any(|cell| {
            (cell.glyph != 0 && cell.foreground[..3] != self.clear[..3])
                || (cell.background[3] > 0 && cell.background[..3] != self.clear[..3])
        })
    }
}

fn create(effect: &str, art: &str, pool: &[&str], seed: u64, cols: u32, rows: u32) -> Session {
    Session::create(
        art.into(),
        effect.into(),
        pool.iter().map(|name| (*name).into()).collect(),
        BACKGROUND,
        Some(seed),
        cols,
        rows,
        ClockKind::Virtual60,
    )
    .unwrap_or_else(|error| panic!("{effect} {cols}x{rows} could not start: {error:?}"))
}

struct CompletedCycle {
    trace: Vec<u64>,
    final_frame: NativeFrame,
    visible_frames: usize,
}

fn complete(session: &mut Session, label: &str) -> CompletedCycle {
    let mut trace = Vec::new();
    let mut visible_frames = 0;
    for _ in 0..MAX_CYCLE_FRAMES {
        let step = session
            .step(DT)
            .unwrap_or_else(|error| panic!("{label}: {error:?}"));
        assert!(
            step.steps_taken <= 4,
            "{label}: exceeded the per-call step cap"
        );
        let frame = NativeFrame::copy(step.frame);
        assert_eq!(
            frame.clear, BACKGROUND,
            "{label}: replaced the chosen background"
        );
        visible_frames += usize::from(frame.has_visible_content());
        trace.push(frame.digest());
        if step.waiting {
            let held = session.step(1.0).expect("waiting frame");
            assert!(
                held.waiting,
                "{label}: completed effect resumed without begin_next"
            );
            assert_eq!(held.steps_taken, 0, "{label}: waiting state kept advancing");
            assert_eq!(
                NativeFrame::copy(held.frame),
                frame,
                "{label}: final image changed while waiting"
            );
            return CompletedCycle {
                trace,
                final_frame: frame,
                visible_frames,
            };
        }
    }
    panic!("{label}: did not finish within {MAX_CYCLE_FRAMES} frames (30 virtual seconds)");
}

fn prefix(session: &mut Session, frames: usize) -> Vec<u64> {
    (0..frames)
        .map(|_| NativeFrame::copy(session.step(DT).unwrap().frame).digest())
        .collect()
}

#[test]
fn originals_publish_visible_changing_frames_and_finish_with_a_readable_hold() {
    for name in ORIGINALS {
        let mut session = create(name, "MACARCHY\n /\\ /\\", &[], 42, 48, 16);
        let cycle = complete(&mut session, name);
        assert_eq!(
            session.generation(),
            0,
            "{name}: advanced generation without a host transition"
        );
        assert!(
            cycle.visible_frames >= 30,
            "{name}: artwork was not visible for a useful interval"
        );
        assert!(
            cycle.trace.iter().copied().collect::<HashSet<_>>().len() >= 10,
            "{name}: too few distinct visible frames"
        );
        let final_digest = cycle.final_frame.digest();
        let held_frames = cycle
            .trace
            .iter()
            .rev()
            .take_while(|digest| **digest == final_digest)
            .count();
        assert!(
            held_frames >= 30,
            "{name}: final art was not held for at least half a second"
        );
    }
}

#[test]
fn originals_restore_exact_ascii_positions_without_stray_particles() {
    // Top-left native coordinates for centered, asymmetric 3x2 artwork in a
    // 12x8 canvas. The internal blank must remain a blank.
    let expected = BTreeMap::from([((5, 3), 'A'), ((6, 3), 'B'), ((5, 4), 'C'), ((7, 4), 'D')]);
    for name in ORIGINALS {
        let mut session = create(name, "AB\nC D", &[], 81, 12, 8);
        let final_frame = complete(&mut session, name).final_frame;
        assert_eq!(
            final_frame.glyphs(),
            expected,
            "{name}: final art was moved, lost, or covered by particles"
        );
        for (x, y) in expected.keys() {
            let cell = &final_frame.cells[(y * final_frame.cols + x) as usize];
            let background = if cell.background[3] > 0 {
                cell.background
            } else {
                final_frame.clear
            };
            assert_ne!(
                cell.foreground[..3],
                background[..3],
                "{name}: final glyph is indistinguishable from its background"
            );
        }
    }
}

#[test]
fn originals_restore_unicode_scalars_in_native_cells() {
    let expected = BTreeMap::from([((4, 2), 'λ'), ((5, 2), '█'), ((4, 3), '⣿'), ((5, 3), '界')]);
    for name in ORIGINALS {
        let mut session = create(name, "λ█\n⣿界", &[], 19, 10, 6);
        assert_eq!(
            complete(&mut session, name).final_frame.glyphs(),
            expected,
            "{name}: final Unicode art did not survive the packed-cell path"
        );
    }
}

#[test]
fn originals_are_repeatable_for_one_seed_and_vary_for_another() {
    for name in ORIGINALS {
        let mut first = create(name, "MACARCHY\n /\\ /\\", &[], 7, 32, 12);
        let mut repeated = create(name, "MACARCHY\n /\\ /\\", &[], 7, 32, 12);
        let mut different = create(name, "MACARCHY\n /\\ /\\", &[], 1_024, 32, 12);
        let first = complete(&mut first, name);
        let repeated = complete(&mut repeated, name);
        let different = complete(&mut different, name);
        assert_eq!(
            first.trace, repeated.trace,
            "{name}: identical seeds produced different visible playback"
        );
        assert_ne!(
            first.trace, different.trace,
            "{name}: the seed did not affect visible playback"
        );
        assert_eq!(
            first.final_frame.glyphs(),
            different.final_frame.glyphs(),
            "{name}: seed changed the final artwork"
        );
    }
}

#[test]
fn originals_handle_tiny_and_narrow_canvases_without_losing_fitting_art() {
    for name in ORIGINALS {
        for (art, cols, rows, expected) in [
            ("X", 1, 1, BTreeMap::from([((0, 0), 'X')])),
            ("AB", 2, 1, BTreeMap::from([((0, 0), 'A'), ((1, 0), 'B')])),
            ("A\nB", 1, 2, BTreeMap::from([((0, 0), 'A'), ((0, 1), 'B')])),
            ("X", 1, 8, BTreeMap::from([((0, 3), 'X')])),
            ("X", 8, 1, BTreeMap::from([((4, 0), 'X')])),
        ] {
            let mut session = create(name, art, &[], 11, cols, rows);
            let frame = complete(&mut session, name).final_frame;
            assert_eq!((frame.cols, frame.rows), (cols, rows));
            assert_eq!(
                frame.glyphs(),
                expected,
                "{name}: incorrect final art on {cols}x{rows}"
            );
        }
    }
}

#[test]
fn originals_reject_blank_art_with_an_error_instead_of_panicking() {
    for name in ORIGINALS {
        for art in ["", " ", "   \n   ", "\n\n"] {
            let outcome = std::panic::catch_unwind(|| {
                Session::create(
                    art.into(),
                    name.into(),
                    vec![],
                    BACKGROUND,
                    Some(1),
                    8,
                    4,
                    ClockKind::Virtual60,
                )
            });
            assert!(outcome.is_ok(), "{name}: blank art panicked");
            assert!(
                outcome.unwrap().is_err(),
                "{name}: blank art should produce an explicit input error"
            );
        }
    }
}

#[test]
fn singleton_random_pools_run_each_selected_original() {
    for name in ORIGINALS {
        let mut random = create("random", "AB\nC D", &[name], 27, 20, 8);
        let mut pinned = create(name, "AB\nC D", &[name], 27, 20, 8);
        assert_eq!(
            complete(&mut random, name).trace,
            complete(&mut pinned, name).trace,
            "{name}: a single-selection random pool ran a different effect"
        );
    }
}

#[test]
fn mixed_random_pool_can_select_all_originals_and_an_upstream_effect() {
    let pool = ["aurora", "starfield", "circuit", "wipe"];
    let mut observed = HashSet::new();
    for seed in 0..64 {
        let mut random = create("random", "MACARCHY\n /\\ /\\", &pool, seed, 20, 8);
        let actual = prefix(&mut random, 60);
        let matches: Vec<_> = pool
            .iter()
            .filter(|&&name| {
                let mut control = create(name, "MACARCHY\n /\\ /\\", &pool, seed, 20, 8);
                prefix(&mut control, 60) == actual
            })
            .copied()
            .collect();
        assert_eq!(
            matches.len(),
            1,
            "seed {seed}: random output did not match exactly one allowed effect"
        );
        observed.insert(matches[0]);
    }
    assert_eq!(
        observed,
        HashSet::from(pool),
        "mixed random selection omitted a catalog member"
    );
}

#[test]
fn original_and_mixed_pools_accept_artwork_and_geometry_changes_across_cycles() {
    let mut session = create("random", "G0\nR0", &ORIGINALS, 103, 20, 8);
    let mut control = create("random", "G0\nR0", &ORIGINALS, 103, 20, 8);
    let pools: [&[&str]; 6] = [
        &["aurora"],
        &["starfield"],
        &["circuit"],
        &["wipe"],
        &["wipe", "aurora", "circuit"],
        &["starfield", "wipe"],
    ];
    for generation in 0..=pools.len() {
        let actual = complete(&mut session, "transitioned session");
        let repeated = complete(&mut control, "transition control");
        assert_eq!(
            actual.trace, repeated.trace,
            "generation {generation}: seed stream changed across transitions"
        );
        assert_eq!(session.generation(), generation as u64);
        let rendered: String = actual
            .final_frame
            .cells
            .iter()
            .filter_map(|cell| (cell.glyph != 0).then(|| char::from_u32(cell.glyph).unwrap()))
            .collect();
        assert_eq!(
            rendered,
            format!("G{generation}R{generation}"),
            "generation {generation}: final art is stale"
        );
        if generation == pools.len() {
            break;
        }
        let pool: Vec<String> = pools[generation]
            .iter()
            .map(|name| (*name).into())
            .collect();
        let (cols, rows) = if generation % 2 == 0 {
            (24, 10)
        } else {
            (16, 6)
        };
        for next in [&mut session, &mut control] {
            next.begin_next_with_config(
                format!("G{}\nR{}", generation + 1, generation + 1),
                pool.clone(),
                cols,
                rows,
            )
            .unwrap();
            let initial = next.step(0.0).unwrap();
            assert!(!initial.waiting);
            assert_eq!((initial.frame.cols, initial.frame.rows), (cols, rows));
            assert_eq!(next.selected_effect_pool(), pool.as_slice());
        }
    }
}
