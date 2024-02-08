#pragma once

#include "env.hpp"
#include "handle.hpp"

#include <functional>
#include <memory>

namespace thespian {

using behaviour = std::function<auto()->result>;
using exit_handler = std::function<void(std::string_view)>;

struct context {
  using dtor = void (*)(context *);
  using ref = std::unique_ptr<context, dtor>;
  using last_exit_handler = std::function<void()>;

  [[nodiscard]] static auto create() -> ref;
  [[nodiscard]] static auto create(dtor *) -> context *;
  void run();
  void on_last_exit(last_exit_handler);

  [[nodiscard]] auto spawn(behaviour b, std::string_view name)
      -> expected<handle, error>;
  [[nodiscard]] auto spawn(behaviour b, std::string_view name, env_t env)
      -> expected<handle, error>;
  [[nodiscard]] auto spawn_link(behaviour b, exit_handler eh,
                                std::string_view name)
      -> expected<handle, error>;
  [[nodiscard]] auto spawn_link(behaviour b, exit_handler eh,
                                std::string_view name, env_t env)
      -> expected<handle, error>;

protected:
  context() = default;
  ~context() = default;

public:
  context(const context &) = delete;
  context(context &&) = delete;
  void operator=(const context &) = delete;
  void operator=(context &&) = delete;
};

} // namespace thespian
