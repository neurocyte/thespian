#pragma once

#include <array>
#include <chrono>
#include <cstdint>
#include <functional>
#include <memory>
#include <netinet/in.h>
#include <system_error>
#include <vector>

using port_t = unsigned short;

namespace thespian::executor {

struct strand;

struct context_impl;
using context_ref = std::shared_ptr<context_impl>;

struct context {
  static auto create() -> context;
  auto create_strand() -> strand;
  void run();
  auto pending_tasks() -> size_t;
  auto pending_posts() -> size_t;
  context_ref ref;
};

struct strand_impl;
using strand_ref = std::shared_ptr<strand_impl>;

struct strand {
  void post(std::function<void()>);
  strand_ref ref;
};

struct signal_impl;
using signal_dtor = void (*)(signal_impl *);
using signal_ref = std::unique_ptr<signal_impl, signal_dtor>;

struct signal {
  using handler = std::function<void(const std::error_code &, int signum)>;

  explicit signal(context &);
  explicit signal(strand &);
  void fires_on(int signum);
  void on_fired(handler);
  void cancel();
  signal_ref ref;
};

struct timer_impl;
using timer_dtor = void (*)(timer_impl *);
using timer_ref = std::unique_ptr<timer_impl, timer_dtor>;

struct timer {
  using handler = std::function<void(const std::error_code &)>;

  explicit timer(context &);
  explicit timer(strand &);
  void expires_at(std::chrono::time_point<std::chrono::system_clock>);
  void expires_after(std::chrono::microseconds);
  void on_expired(handler);
  void cancel();
  timer_ref ref;
};

auto to_string(const in6_addr &ip) -> std::string;

constexpr auto receive_buffer_size{4L * 1024L};

struct endpoint {
  in6_addr ip;
  port_t port;
};

namespace udp {

struct socket_impl;
using socket_dtor = void (*)(socket_impl *);
using socket_ref = std::unique_ptr<socket_impl, socket_dtor>;

struct socket {
  using handler =
      std::function<void(const std::error_code &, std::size_t received)>;

  explicit socket(strand &);
  auto bind(const in6_addr &ip, port_t port) -> std::error_code;
  [[nodiscard]] auto send_to(std::string_view data, in6_addr ip,
                             port_t port) const -> size_t;
  void receive(handler);
  void close();
  [[nodiscard]] auto local_endpoint() const -> const endpoint &;
  [[nodiscard]] auto remote_endpoint() const -> const endpoint &;
  std::array<char, receive_buffer_size> receive_buffer{};
  socket_ref ref;
};

} // namespace udp

namespace tcp {

struct socket_impl;
using socket_dtor = void (*)(socket_impl *);
using socket_ref = std::unique_ptr<socket_impl, socket_dtor>;

struct socket {
  using connect_handler = std::function<void(const std::error_code &)>;
  using read_handler =
      std::function<void(const std::error_code &, std::size_t)>;
  using write_handler =
      std::function<void(const std::error_code &, std::size_t)>;

  explicit socket(strand &);
  explicit socket(strand &, int fd);
  auto bind(const in6_addr &ip, port_t port) -> std::error_code;
  void connect(const in6_addr &ip, port_t port, connect_handler);
  void write(const std::vector<uint8_t> &data, write_handler);
  void read(read_handler);
  void close();
  static void close(int fd);
  auto release() -> int;
  [[nodiscard]] auto local_endpoint() const -> const endpoint &;
  std::array<char, receive_buffer_size> read_buffer{};
  socket_ref ref;
};

struct acceptor_impl;
using acceptor_dtor = void (*)(acceptor_impl *);
using acceptor_ref = std::unique_ptr<acceptor_impl, acceptor_dtor>;

struct acceptor {
  using handler = std::function<void(int fd, const std::error_code &)>;

  explicit acceptor(strand &);
  auto bind(const in6_addr &, port_t) -> std::error_code;
  auto listen() -> std::error_code;
  void accept(handler);
  void close();
  [[nodiscard]] auto local_endpoint() const -> endpoint;
  acceptor_ref ref;
};

} // namespace tcp

namespace unx {

struct socket_impl;
using socket_dtor = void (*)(socket_impl *);
using socket_ref = std::unique_ptr<socket_impl, socket_dtor>;

struct socket {
  using connect_handler = std::function<void(const std::error_code &)>;
  using read_handler =
      std::function<void(const std::error_code &, std::size_t)>;
  using write_handler =
      std::function<void(const std::error_code &, std::size_t)>;

  explicit socket(strand &);
  explicit socket(strand &, int fd);
  auto bind(std::string_view path) -> std::error_code;
  void connect(std::string_view path, connect_handler);
  void write(const std::vector<uint8_t> &data, write_handler);
  void read(read_handler);
  void close();
  auto release() -> int;
  std::array<char, receive_buffer_size> read_buffer{};
  socket_ref ref;
};

struct acceptor_impl;
using acceptor_dtor = void (*)(acceptor_impl *);
using acceptor_ref = std::unique_ptr<acceptor_impl, acceptor_dtor>;

struct acceptor {
  using handler = std::function<void(int fd, const std::error_code &)>;

  explicit acceptor(strand &);
  auto bind(std::string_view path) -> std::error_code;
  auto listen() -> std::error_code;
  void accept(handler);
  void close();
  acceptor_ref ref;
};

} // namespace unx

namespace file_descriptor {

struct watcher_impl;
using watcher_dtor = void (*)(watcher_impl *);
using watcher_ref = std::unique_ptr<watcher_impl, watcher_dtor>;

struct watcher {
  using handler = std::function<void(const std::error_code &)>;

  explicit watcher(strand &, int fd);
  void wait_read(handler);
  void wait_write(handler);
  void cancel();
  watcher_ref ref;
};

} // namespace file_descriptor

} // namespace thespian::executor
