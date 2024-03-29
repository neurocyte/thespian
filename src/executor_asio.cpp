#include "asio/error_code.hpp"
#include "asio/posix/descriptor_base.hpp"
#include "executor.hpp"
#include <cstddef>
#include <memory>

#include <asio/basic_socket_acceptor.hpp>
#include <asio/bind_executor.hpp>
#include <asio/io_context.hpp>
#include <asio/ip/address_v6.hpp>
#include <asio/ip/tcp.hpp>
#include <asio/ip/udp.hpp>
#include <asio/local/stream_protocol.hpp>
#include <asio/posix/stream_descriptor.hpp>
#include <asio/signal_set.hpp>
#include <asio/socket_base.hpp>
#include <asio/strand.hpp>
#include <asio/system_timer.hpp>
#include <asio/thread.hpp>

#include <csignal>
#include <vector>

using asio::bind_executor;
using asio::buffer;
using asio::io_context;
using asio::string_view;
using asio::system_timer;
using asio::thread;
using asio::posix::stream_descriptor;
using std::atomic;
using std::error_code;
using std::function;
using std::make_shared;
using std::make_unique;
using std::max;
using std::memory_order_relaxed;
using std::min;
using std::move;
using std::shared_ptr;
using std::string;
using std::unique_ptr;
using std::vector;
using std::weak_ptr;
using std::chrono::microseconds;
using std::chrono::system_clock;
using std::chrono::time_point;

namespace thespian::executor {

const char *MAX_THREAD_STR = getenv("MAX_THREAD"); // NOLINT
const auto MAX_THREAD =
    static_cast<long>(atoi(MAX_THREAD_STR ? MAX_THREAD_STR : "64")); // NOLINT

const auto threads = min(sysconf(_SC_NPROCESSORS_ONLN), MAX_THREAD);

struct context_impl {
  context_impl() : asio{make_unique<io_context>(threads)} {}
  unique_ptr<io_context> asio;
  atomic<size_t> pending;
  atomic<size_t> posts;
};

auto context::create() -> context {
  if (::signal(SIGPIPE, SIG_IGN) == SIG_ERR) // NOLINT
    abort();
  return {context_ref(new context_impl(), [](context_impl *p) { delete p; })};
}

struct strand_impl {
  explicit strand_impl(const context_ref &ctx)
      : ctx{ctx}, strand_{*ctx->asio} {}
  void post(function<void()> f) {
    ctx->posts.fetch_add(1);
    strand_.post([&posts = ctx->posts, f = move(f)]() {
      posts.fetch_sub(1);
      f();
    });
  }
  context_ref ctx;
  io_context::strand strand_;
};

auto context::create_strand() -> strand {
  return {make_shared<strand_impl>(ref)};
}

void strand::post(function<void()> f) { ref->post(move(f)); }

auto context::run() -> void {
  const auto spawn_threads = max(threads - 1, 0L);
  vector<thread *> running;
  for (auto i = 0; i < spawn_threads; ++i) {
    auto *t = new thread([ctx = ref]() { ctx->asio->run(); });
    running.push_back(t);
  }
  ref->asio->run();
  for (auto &t : running) {
    t->join();
    delete t;
  }
}

auto context::pending_tasks() -> size_t { return ref->pending.load(); }
auto context::pending_posts() -> size_t { return ref->posts.load(); }

} // namespace thespian::executor

namespace {

static auto to_address(const in6_addr &ip) -> const asio::ip::address_v6 {
  asio::ip::address_v6::bytes_type bytes;
  memcpy(bytes.data(), ip.s6_addr, sizeof(ip.s6_addr));
  return asio::ip::address_v6{bytes};
}

static auto to_in6_addr(const asio::ip::address_v6 &address) -> in6_addr {
  auto bytes = address.to_bytes();
  in6_addr ip{};
  memcpy(ip.s6_addr, bytes.data(), sizeof(ip.s6_addr));
  return ip;
}

static auto to_in6_addr(const asio::ip::udp::endpoint &ep) -> in6_addr {
  return to_in6_addr(ep.address().to_v6());
}

static auto to_in6_addr(const asio::ip::tcp::endpoint &ep) -> in6_addr {
  return to_in6_addr(ep.address().to_v6());
}

static auto to_endpoint_tcp(const in6_addr &ip, port_t port)
    -> const asio::ip::tcp::endpoint {
  return {to_address(ip), port};
}

static auto to_endpoint_udp(const in6_addr &ip, port_t port)
    -> const asio::ip::udp::endpoint {
  return {to_address(ip), port};
}

} // namespace

namespace thespian::executor {

auto to_string(const in6_addr &ip) -> string {
  return to_address(ip).to_string();
}

struct signal_impl {
  explicit signal_impl(const context_ref &ctx)
      : ctx{ctx}, signals_{*ctx->asio} {}
  explicit signal_impl(strand &strand)
      : ctx{strand.ref->ctx}, signals_{*ctx->asio} {}
  void fires_on(int signum) { signals_.add(signum); }
  void on_fired(signal::handler f) {
    ctx->pending.fetch_add(1, memory_order_relaxed);
    weak_ptr<bool> weak_token{token_};
    signals_.async_wait([c_ = ctx, f = move(f), t = move(weak_token)](
                            const error_code &ec, int signum) {
      c_->pending.fetch_sub(1, memory_order_relaxed);
      if (auto p = t.lock()) {
        f(ec, signum);
      }
    });
  }
  void cancel() { signals_.cancel(); }
  context_ref ctx;
  asio::signal_set signals_;
  shared_ptr<bool> token_{make_shared<bool>(true)};
};

signal::signal(context &ctx)
    : ref{signal_ref(new signal_impl(ctx.ref),
                     [](signal_impl *p) { delete p; })} {}

signal::signal(strand &ref)
    : ref{signal_ref(new signal_impl(ref), [](signal_impl *p) { delete p; })} {}

void signal::fires_on(int signum) { ref->fires_on(signum); }
void signal::on_fired(handler f) { ref->on_fired(move(f)); }
void signal::cancel() { ref->cancel(); }

struct timer_impl {
  explicit timer_impl(const context_ref &ctx) : ctx{ctx}, timer_{*ctx->asio} {}
  explicit timer_impl(strand &strand)
      : ctx{strand.ref->ctx}, timer_{*ctx->asio} {}
  void expires_at(time_point<system_clock> t) { timer_.expires_at(t); }
  void expires_after(microseconds us) { timer_.expires_after(us); }
  void on_expired(timer::handler f) {
    ctx->pending.fetch_add(1, memory_order_relaxed);
    weak_ptr<bool> weak_token{token_};
    timer_.async_wait(
        [c_ = ctx, f = move(f), t = move(weak_token)](const error_code &ec) {
          c_->pending.fetch_sub(1, memory_order_relaxed);
          if (auto p = t.lock()) {
            f(ec);
          }
        });
  }
  void cancel() { timer_.cancel(); }
  context_ref ctx;
  system_timer timer_;
  bool pending_{};
  shared_ptr<bool> token_{make_shared<bool>(true)};
};

timer::timer(context &ctx)
    : ref{timer_ref(new timer_impl(ctx.ref), [](timer_impl *p) { delete p; })} {
}

timer::timer(strand &ref)
    : ref{timer_ref(new timer_impl(ref), [](timer_impl *p) { delete p; })} {}

void timer::expires_at(time_point<system_clock> t) { ref->expires_at(t); }
void timer::expires_after(microseconds us) { ref->expires_after(us); }
void timer::on_expired(handler f) { ref->on_expired(move(f)); }
void timer::cancel() { ref->cancel(); }

namespace udp {

struct socket_impl {
  explicit socket_impl(strand &strand)
      : ctx{strand.ref->ctx}, strand_{strand.ref->strand_},
        socket_{*ctx->asio, ::asio::ip::udp::v6()} {}
  auto bind(const in6_addr &ip, port_t port) -> error_code {
    error_code ec;
    socket_.bind(to_endpoint_udp(ip, port), ec);
    return ec;
  }
  [[nodiscard]] auto send_to(string_view data, in6_addr ip, port_t port)
      -> size_t {
    return socket_.send_to(buffer(data.data(), data.size()),
                           to_endpoint_udp(ip, port));
  }
  void receive(socket &s, socket::handler h) {
    ctx->pending.fetch_add(1, memory_order_relaxed);
    weak_ptr<bool> weak_token{token_};
    socket_.async_receive_from(
        buffer(s.receive_buffer), asio_remote_endpoint_,
        bind_executor(strand_,
                      [c = ctx, ep = &remote_endpoint_,
                       aep = &asio_remote_endpoint_, t = move(weak_token),
                       h = move(h)](const error_code &ec, size_t received) {
                        c->pending.fetch_sub(1, memory_order_relaxed);
                        if (auto p = t.lock()) {
                          ep->ip = to_in6_addr(*aep);
                          ep->port = aep->port();
                          h(ec, received);
                        }
                      }));
  }
  void close() { socket_.close(); }
  auto local_endpoint() -> const endpoint & {
    auto ep = socket_.local_endpoint();
    local_endpoint_.ip = to_in6_addr(ep);
    local_endpoint_.port = ep.port();
    return local_endpoint_;
  }
  auto remote_endpoint() -> const endpoint & { return remote_endpoint_; }
  context_ref ctx;
  io_context::strand strand_;
  asio::ip::udp::socket socket_;
  asio::ip::udp::endpoint asio_remote_endpoint_;
  executor::endpoint local_endpoint_{};
  executor::endpoint remote_endpoint_{};
  shared_ptr<bool> token_{make_shared<bool>(true)};
};

socket::socket(strand &strand)
    : ref{socket_ref(new socket_impl(strand),
                     [](socket_impl *p) { delete p; })} {}

auto socket::bind(const in6_addr &ip, port_t port) -> error_code {
  return ref->bind(ip, port);
}

auto socket::send_to(string_view data, in6_addr ip, port_t port) const
    -> size_t {
  return ref->send_to(data, ip, port);
}

void socket::receive(handler h) { ref->receive(*this, move(h)); }

void socket::close() {}

auto socket::local_endpoint() const -> const endpoint & {
  return ref->local_endpoint();
}

auto socket::remote_endpoint() const -> const endpoint & {
  return ref->remote_endpoint();
}

} // namespace udp

namespace tcp {

struct socket_impl {
  explicit socket_impl(strand &strand)
      : ctx{strand.ref->ctx}, strand_{strand.ref->strand_},
        socket_{*ctx->asio, asio::ip::tcp::v6()} {}
  explicit socket_impl(strand &strand, int fd)
      : ctx{strand.ref->ctx}, strand_{strand.ref->strand_},
        socket_{*ctx->asio, asio::ip::tcp::v6(), fd} {}
  auto bind(const in6_addr &ip, port_t port) -> error_code {
    error_code ec;
    socket_.bind(to_endpoint_tcp(ip, port), ec);
    return ec;
  }
  void connect(const in6_addr &ip, port_t port, socket::connect_handler h) {
    ctx->pending.fetch_add(1, memory_order_relaxed);
    weak_ptr<bool> weak_token{token_};
    socket_.async_connect(
        to_endpoint_tcp(ip, port),
        bind_executor(strand_, [c = ctx, h = move(h),
                                t = move(weak_token)](const error_code &ec) {
          c->pending.fetch_sub(1, memory_order_relaxed);
          if (auto p = t.lock())
            h(ec);
        }));
  }
  void write(const vector<uint8_t> &data, socket::write_handler h) {
    ctx->pending.fetch_add(1, memory_order_relaxed);
    weak_ptr<bool> weak_token{token_};
    socket_.async_write_some(
        buffer(data.data(), data.size()),
        bind_executor(strand_, [c = ctx, h = move(h), t = move(weak_token)](
                                   const error_code &ec, size_t written) {
          c->pending.fetch_sub(1, memory_order_relaxed);
          if (auto p = t.lock())
            h(ec, written);
        }));
  }
  void read(socket &s, socket::read_handler h) {
    ctx->pending.fetch_add(1, memory_order_relaxed);
    weak_ptr<bool> weak_token{token_};
    socket_.async_read_some(
        buffer(s.read_buffer.data(), s.read_buffer.size()),
        bind_executor(strand_, [c = ctx, h = move(h), t = move(weak_token)](
                                   const error_code &ec, size_t read) {
          c->pending.fetch_sub(1, memory_order_relaxed);
          if (auto p = t.lock())
            h(ec, read);
        }));
  }
  void close() { socket_.close(); }
  auto release() -> int { return socket_.release(); }
  auto local_endpoint() -> const endpoint & {
    auto ep = socket_.local_endpoint();
    local_endpoint_.ip = to_in6_addr(ep);
    local_endpoint_.port = ep.port();
    return local_endpoint_;
  }
  context_ref ctx;
  io_context::strand strand_;
  asio::ip::tcp::socket socket_;
  asio::ip::tcp::endpoint remote_endpoint_;
  executor::endpoint local_endpoint_{};
  shared_ptr<bool> token_{make_shared<bool>(true)};
};

socket::socket(strand &strand)
    : ref{socket_ref(new socket_impl(strand),
                     [](socket_impl *p) { delete p; })} {}

socket::socket(strand &strand, int fd)
    : ref{socket_ref(new socket_impl(strand, fd),
                     [](socket_impl *p) { delete p; })} {}

auto socket::bind(const in6_addr &ip, port_t port) -> error_code {
  return ref->bind(ip, port);
}

void socket::connect(const in6_addr &ip, port_t port, connect_handler h) {
  ref->connect(ip, port, move(h));
}

void socket::write(const vector<uint8_t> &data, write_handler h) {
  ref->write(data, move(h));
}
void socket::read(read_handler h) { ref->read(*this, move(h)); }

void socket::close() { ref->close(); }
void socket::close(int fd) { ::close(fd); }
auto socket::release() -> int { return ref->release(); }

auto socket::local_endpoint() const -> const endpoint & {
  return ref->local_endpoint();
}

struct acceptor_impl {
  explicit acceptor_impl(strand &strand)
      : ctx{strand.ref->ctx}, strand_{strand.ref->strand_},
        acceptor_{*ctx->asio, asio::ip::tcp::v6()}, socket_{*ctx->asio} {}
  auto bind(const in6_addr &ip, port_t port) -> error_code {
    error_code ec;
    acceptor_.bind(to_endpoint_tcp(ip, port), ec);
    return ec;
  }
  auto listen() -> error_code {
    error_code ec;
    acceptor_.listen(asio::socket_base::max_listen_connections, ec);
    return ec;
  }
  void accept(acceptor::handler h) {
    ctx->pending.fetch_add(1, memory_order_relaxed);
    weak_ptr<bool> weak_token{token_};
    acceptor_.async_accept(
        socket_,
        bind_executor(strand_, [c = ctx, s = &socket_, h = move(h),
                                t = move(weak_token)](const error_code &ec) {
          c->pending.fetch_sub(1, memory_order_relaxed);
          if (auto p = t.lock())
            h(ec ? 0 : s->release(), ec);
        }));
  }
  void close() { acceptor_.close(); }
  auto local_endpoint() -> const endpoint & {
    auto ep = acceptor_.local_endpoint();
    local_endpoint_.ip = to_in6_addr(ep);
    local_endpoint_.port = ep.port();
    return local_endpoint_;
  }
  context_ref ctx;
  io_context::strand strand_;
  asio::ip::tcp::acceptor acceptor_;
  asio::ip::tcp::socket socket_;
  executor::endpoint local_endpoint_{};
  shared_ptr<bool> token_{make_shared<bool>(true)};
};

acceptor::acceptor(strand &strand)
    : ref{acceptor_ref(new acceptor_impl(strand),
                       [](acceptor_impl *p) { delete p; })} {}

auto acceptor::bind(const in6_addr &ip, port_t port) -> error_code {
  return ref->bind(ip, port);
}

auto acceptor::listen() -> error_code { return ref->listen(); }

void acceptor::accept(acceptor::handler h) { ref->accept(move(h)); }

void acceptor::close() { ref->close(); }

[[nodiscard]] auto acceptor::local_endpoint() const -> endpoint {
  return ref->local_endpoint();
}

} // namespace tcp

namespace unx {

struct socket_impl {
  explicit socket_impl(strand &strand)
      : ctx{strand.ref->ctx}, strand_{strand.ref->strand_}, socket_{
                                                                *ctx->asio} {}
  explicit socket_impl(strand &strand, int fd)
      : ctx{strand.ref->ctx}, strand_{strand.ref->strand_}, socket_{*ctx->asio,
                                                                    fd} {}
  auto bind(string_view path) -> error_code {
    error_code ec;
    socket_.bind(path, ec);
    return ec;
  }
  void connect(string_view path, socket::connect_handler h) {
    ctx->pending.fetch_add(1, memory_order_relaxed);
    weak_ptr<bool> weak_token{token_};
    socket_.async_connect(
        path,
        bind_executor(strand_, [c = ctx, h = move(h),
                                t = move(weak_token)](const error_code &ec) {
          c->pending.fetch_sub(1, memory_order_relaxed);
          if (auto p = t.lock())
            h(ec);
        }));
  }
  void write(const vector<uint8_t> &data, socket::write_handler h) {
    ctx->pending.fetch_add(1, memory_order_relaxed);
    weak_ptr<bool> weak_token{token_};
    socket_.async_write_some(
        buffer(data.data(), data.size()),
        bind_executor(strand_, [c = ctx, h = move(h), t = move(weak_token)](
                                   const error_code &ec, size_t written) {
          c->pending.fetch_sub(1, memory_order_relaxed);
          if (auto p = t.lock())
            h(ec, written);
        }));
  }
  void read(socket &s, socket::read_handler h) {
    ctx->pending.fetch_add(1, memory_order_relaxed);
    weak_ptr<bool> weak_token{token_};
    socket_.async_read_some(
        buffer(s.read_buffer.data(), s.read_buffer.size()),
        bind_executor(strand_, [c = ctx, h = move(h), t = move(weak_token)](
                                   const error_code &ec, size_t read) {
          c->pending.fetch_sub(1, memory_order_relaxed);
          if (auto p = t.lock())
            h(ec, read);
        }));
  }
  void close() { socket_.close(); }
  auto release() -> int { return socket_.release(); }
  context_ref ctx;
  io_context::strand strand_;
  asio::local::stream_protocol::socket socket_;
  shared_ptr<bool> token_{make_shared<bool>(true)};
};

socket::socket(strand &strand)
    : ref{socket_ref(new socket_impl(strand),
                     [](socket_impl *p) { delete p; })} {}

socket::socket(strand &strand, int fd)
    : ref{socket_ref(new socket_impl(strand, fd),
                     [](socket_impl *p) { delete p; })} {}

auto socket::bind(string_view path) -> error_code { return ref->bind(path); }

void socket::connect(string_view path, connect_handler h) {
  ref->connect(path, move(h));
}

void socket::write(const vector<uint8_t> &data, write_handler h) {
  ref->write(data, move(h));
}
void socket::read(read_handler h) { ref->read(*this, move(h)); }

void socket::close() { ref->close(); }
auto socket::release() -> int { return ref->release(); }

struct acceptor_impl {
  explicit acceptor_impl(strand &strand)
      : ctx{strand.ref->ctx}, strand_{strand.ref->strand_},
        acceptor_{*ctx->asio, asio::local::stream_protocol()},
        socket_{*ctx->asio} {}
  auto bind(string_view path) -> error_code {
    error_code ec;
    acceptor_.bind(path, ec);
    return ec;
  }
  auto listen() -> error_code {
    error_code ec;
    acceptor_.listen(asio::socket_base::max_listen_connections, ec);
    return ec;
  }
  void accept(acceptor::handler h) {
    ctx->pending.fetch_add(1, memory_order_relaxed);
    weak_ptr<bool> weak_token{token_};
    acceptor_.async_accept(
        socket_,
        bind_executor(strand_, [c = ctx, s = &socket_, h = move(h),
                                t = move(weak_token)](const error_code &ec) {
          c->pending.fetch_sub(1, memory_order_relaxed);
          if (auto p = t.lock())
            h(ec ? 0 : s->release(), ec);
        }));
  }
  void close() { acceptor_.close(); }
  context_ref ctx;
  io_context::strand strand_;
  asio::local::stream_protocol::acceptor acceptor_;
  asio::local::stream_protocol::socket socket_;
  shared_ptr<bool> token_{make_shared<bool>(true)};
};

acceptor::acceptor(strand &strand)
    : ref{acceptor_ref(new acceptor_impl(strand),
                       [](acceptor_impl *p) { delete p; })} {}

auto acceptor::bind(string_view path) -> error_code { return ref->bind(path); }

auto acceptor::listen() -> error_code { return ref->listen(); }

void acceptor::accept(acceptor::handler h) { ref->accept(move(h)); }

void acceptor::close() { ref->close(); }

} // namespace unx

namespace file_descriptor {

struct watcher_impl {
  explicit watcher_impl(strand &strand, int fd)
      : ctx{strand.ref->ctx}, strand_{strand.ref->strand_}, fd_{*ctx->asio,
                                                                fd} {}

  void wait_read(watcher::handler h) {
    if (!read_in_progress_) {
      read_in_progress_ = true;
      ctx->pending.fetch_add(1, memory_order_relaxed);
      weak_ptr<bool> weak_token{token_};
      fd_.async_wait(
          asio::posix::descriptor_base::wait_type::wait_read,
          bind_executor(strand_, [c = ctx, b = &read_in_progress_, h = move(h),
                                  t = move(weak_token)](const error_code &ec) {
            c->pending.fetch_sub(1, memory_order_relaxed);
            if (auto p = t.lock()) {
              *b = false;
              h(ec);
            }
          }));
    }
  }

  void wait_write(watcher::handler h) {
    if (!write_in_progress_) {
      write_in_progress_ = true;
      ctx->pending.fetch_add(1, memory_order_relaxed);
      weak_ptr<bool> weak_token{token_};
      fd_.async_wait(
          asio::posix::descriptor_base::wait_type::wait_write,
          bind_executor(strand_, [c = ctx, b = &write_in_progress_, h = move(h),
                                  t = move(weak_token)](const error_code &ec) {
            c->pending.fetch_sub(1, memory_order_relaxed);
            if (auto p = t.lock()) {
              *b = false;
              h(ec);
            }
          }));
    }
  }

  void cancel() { fd_.cancel(); }

  context_ref ctx;
  io_context::strand strand_;
  stream_descriptor fd_;
  shared_ptr<bool> token_{make_shared<bool>(true)};
  bool read_in_progress_{false};
  bool write_in_progress_{false};
};

watcher::watcher(strand &strand, int fd)
    : ref{watcher_ref(new watcher_impl(strand, fd),
                      [](watcher_impl *p) { delete p; })} {}

void watcher::wait_read(watcher::handler h) { ref->wait_read(move(h)); }
void watcher::wait_write(watcher::handler h) { ref->wait_write(move(h)); }
void watcher::cancel() { ref->cancel(); }

} // namespace file_descriptor

} // namespace thespian::executor
