/* Exercise the exported ABI on the actual process main thread. Rust's test
 * workers cannot execute the main-thread-only session API on macOS. */
#define _POSIX_C_SOURCE 200809L
#include "omacy.h"

#include <assert.h>
#include <inttypes.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

static double seconds(void) {
  struct timespec now;
  assert(clock_gettime(CLOCK_MONOTONIC, &now) == 0);
  return (double)now.tv_sec + (double)now.tv_nsec / 1000000000.0;
}

static void require_ok(omacy_status status, const OmacySession *session) {
  if (status != OMACY_OK) {
    char message[512] = {0};
    (void)omacy_session_error_message(session, message, sizeof(message));
    fprintf(stderr, "Engine status %d: %s\n", status, message);
    assert(status == OMACY_OK);
  }
}

static uint64_t frame_hash(const OmacyFrame *frame, uint32_t cols, uint32_t rows,
                           bool *saw_glyph) {
  assert(frame->cols == cols && frame->rows == rows);
  assert(frame->cells != NULL && frame->clear_a == 255);
  uint64_t hash = UINT64_C(14695981039346656037);
  for (size_t index = 0; index < (size_t)cols * rows; ++index) {
    const OmacyCell *cell = &frame->cells[index];
    assert(cell->flags == 0);
    assert((cell->occupancy & ~(OMACY_CELL_HAS_BACKGROUND | OMACY_CELL_HAS_GLYPH)) == 0);
    if (cell->occupancy & OMACY_CELL_HAS_GLYPH) {
      assert(cell->glyph <= 0x10ffff);
      assert(cell->glyph < 0xd800 || cell->glyph > 0xdfff);
      *saw_glyph = *saw_glyph || (cell->glyph != 0 && cell->glyph != ' ');
    }
    const uint8_t *bytes = (const uint8_t *)cell;
    /* Padding is intentionally excluded from the renderer-visible digest. */
    for (size_t byte = 0; byte < offsetof(OmacyCell, _pad); ++byte) {
      hash = (hash ^ bytes[byte]) * UINT64_C(1099511628211);
    }
  }
  return hash;
}

static size_t complete_cycle(OmacySession *session, const char *name,
                             uint32_t cols, uint32_t rows) {
  const bool uses_wall_clock = strcmp(name, "matrix") == 0 || strcmp(name, "thunderstorm") == 0;
  const double started = seconds();
  uint64_t first_hash = 0;
  bool changed = false;
  bool saw_glyph = false;
  for (size_t frame_index = 0; frame_index < 40000; ++frame_index) {
    OmacyStepResult step = {0};
    require_ok(omacy_session_step(session, 1.0 / 60.0, &step), session);
    assert(step.steps_taken <= 4);
    const uint64_t digest = frame_hash(&step.frame, cols, rows, &saw_glyph);
    if (frame_index == 0) {
      first_hash = digest;
    } else {
      changed = changed || digest != first_hash;
    }
    if (step.needs_begin_next) {
      assert(changed && saw_glyph);
      OmacyStepResult held = {0};
      require_ok(omacy_session_step(session, 1.0, &held), session);
      assert(held.needs_begin_next && held.steps_taken == 0);
      assert(frame_hash(&held.frame, cols, rows, &saw_glyph) == digest);
      printf("PASS %s frames=%zu seconds=%.3f\n", name, frame_index + 1, seconds() - started);
      fflush(stdout);
      return frame_index + 1;
    }
    if (seconds() - started > 45.0) {
      fprintf(stderr, "Timeout: %s after %zu frames\n", name, frame_index + 1);
      assert(false);
    }
    if (uses_wall_clock) {
      const struct timespec interval = {0, 16666667};
      (void)nanosleep(&interval, NULL);
    }
  }
  fprintf(stderr, "Frame budget exhausted: %s\n", name);
  assert(false);
  return 0;
}

int main(void) {
  const char *art = "MACARCHY\n  /\\  /\\\n [__][__]";
  const size_t count = omacy_effect_catalog_count();
  assert(count == 37);
  size_t total_frames = 0;
  for (size_t index = 0; index < count; ++index) {
    const uint8_t *name_bytes = NULL;
    size_t name_length = 0;
    require_ok(omacy_effect_catalog_get(index, &name_bytes, &name_length), NULL);
    assert(name_length > 0 && name_length < 64);
    char name[64] = {0};
    memcpy(name, name_bytes, name_length);
    OmacySessionConfig config = {0};
    config.ascii = (const uint8_t *)art;
    config.ascii_len = strlen(art);
    config.effect = name_bytes;
    config.effect_len = name_length;
    config.bg_r = 17;
    config.bg_g = 19;
    config.bg_b = 24;
    config.bg_a = 255;
    config.has_seed = 1;
    config.seed = 42;
    OmacySession *session = NULL;
    require_ok(omacy_session_create(&config, 60, 20, &session), session);
    assert(session != NULL);
    total_frames += complete_cycle(session, name, 60, 20);
    uint64_t generation = UINT64_MAX;
    require_ok(omacy_session_generation(session, &generation), session);
    assert(generation == 0);

    /* After every effect, atomically change artwork, size, and effect. */
    const uint8_t next_art[] = "NEXT\nGENERATION";
    const OmacyByteSlice next_pool = {(const uint8_t *)"wipe", 4};
    require_ok(omacy_session_begin_next_with_config(session, next_art, sizeof(next_art) - 1,
                                                   &next_pool, 1, 48, 16), session);
    require_ok(omacy_session_generation(session, &generation), session);
    assert(generation == 1);
    total_frames += complete_cycle(session, "transition-wipe", 48, 16);
    omacy_session_destroy(session);
  }
  printf("PASS catalog lifecycle: %zu effects, %zu config transitions, %zu frames\n",
         count, count, total_frames);
  return 0;
}
