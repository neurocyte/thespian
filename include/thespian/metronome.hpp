#pragma once

#include <chrono>
#include <functional>
#include <memory>

namespace thespian {

struct metronome_impl;
using metronome_dtor = void (*)(metronome_impl *);
using metronome_ref = std::unique_ptr<metronome_impl, metronome_dtor>;

struct metronome {
  auto start() -> void;
  auto stop() -> void;

  metronome_ref ref;
};

[[nodiscard]] auto create_metronome(std::chrono::microseconds us) -> metronome;
void start_metronome(metronome_impl *);
void stop_metronome(metronome_impl *);
void destroy_metronome(metronome_impl *);

} // namespace thespian
