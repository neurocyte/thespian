#pragma once

// NOLINTBEGIN(modernize-use-trailing-return-type)
#ifdef __cplusplus
extern "C" {
#endif

#include <inttypes.h>

struct thespian_metronome_handle;
struct thespian_metronome_handle *
thespian_metronome_create_ms(uint64_t ms);
struct thespian_metronome_handle *
thespian_metronome_create_us(uint64_t us);
int thespian_metronome_start(struct thespian_metronome_handle *);
int thespian_metronome_stop(struct thespian_metronome_handle *);
void thespian_metronome_destroy(struct thespian_metronome_handle *);

#ifdef __cplusplus
}
#endif
// NOLINTEND(modernize-use-trailing-return-type)
