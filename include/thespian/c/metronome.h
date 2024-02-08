#pragma once

// NOLINTBEGIN(modernize-use-trailing-return-type)
#ifdef __cplusplus
extern "C" {
#endif

struct thespian_metronome_handle;
struct thespian_metronome_handle *
thespian_metronome_create_ms(unsigned long ms);
struct thespian_metronome_handle *
thespian_metronome_create_us(unsigned long us);
int thespian_metronome_start(struct thespian_metronome_handle *);
int thespian_metronome_stop(struct thespian_metronome_handle *);
void thespian_metronome_destroy(struct thespian_metronome_handle *);

#ifdef __cplusplus
}
#endif
// NOLINTEND(modernize-use-trailing-return-type)
