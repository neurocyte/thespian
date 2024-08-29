#include <cbor/cbor.hpp>

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <thespian/context.hpp>
#include <thespian/debug.hpp>
#include <thespian/endpoint.hpp>
#include <thespian/file_descriptor.hpp>
#include <thespian/file_stream.hpp>
#include <thespian/instance.hpp>
#include <thespian/metronome.hpp>
#include <thespian/signal.hpp>
#include <thespian/socket.hpp>
#include <thespian/tcp.hpp>
#include <thespian/timeout.hpp>
#include <thespian/trace.hpp>
#include <thespian/udp.hpp>
#include <thespian/unx.hpp>

#include "executor.hpp"

#include <atomic>
#include <forward_list>
#include <map>
#include <memory>
#include <mutex>
#include <sstream>
#include <string>
#include <string_view>
#include <system_error>
#include <utility>

#if !defined(_WIN32)

#include <netinet/in.h>

#else

#include <in6addr.h>
#include <winsock2.h>
#include <ws2ipdef.h>
#include <ws2tcpip.h>

#endif

#ifdef TRACY_ENABLE
#include <tracy/Tracy.hpp>
#endif

using cbor::any;
using cbor::array;
using cbor::buffer;
using cbor::extract;
using cbor::more;
using cbor::type;

using std::atomic;
using std::domain_error;
using std::enable_shared_from_this;
using std::error_code;
using std::forward;
using std::forward_list;
using std::lock_guard;
using std::make_pair;
using std::make_shared;
using std::map;
using std::memory_order_relaxed;
using std::move;
using std::mutex;
using std::pair;
using std::shared_ptr;
using std::string;
using std::string_view;
using std::stringstream;
using std::swap;
using std::vector;
using std::chrono::microseconds;
using std::chrono::milliseconds;
using std::chrono::system_clock;

using clk = std::chrono::system_clock;
using namespace std::chrono_literals;

namespace thespian {

struct context_impl : context {
  explicit context_impl(executor::context executor)
      : executor{move(executor)} {}
  atomic<size_t> active;
  executor::context executor;
  last_exit_handler last_exit{};

  map<string, handle> registry;
  mutex registry_mux;
  atomic<size_t> debug_enabled{0};

  auto active_add() { return active.fetch_add(1, memory_order_relaxed); }
  auto active_sub() { return active.fetch_sub(1, memory_order_relaxed); }
  auto active_load() { return active.load(); }

  void on_last_exit(last_exit_handler h) { last_exit = move(h); }

  static void destroy(context *p) {
    delete reinterpret_cast<context_impl *>(p); // NOLINT
  }
};
thread_local instance *current_instance{}; // NOLINT

auto impl(context &ctx) -> context_impl & {
  return *reinterpret_cast<context_impl *>(&ctx); // NOLINT
}

auto context::create() -> ref {
  return {new context_impl{executor::context::create()}, context_impl::destroy};
}

auto context::create(dtor *d) -> context * {
  *d = context_impl::destroy;
  return new context_impl{executor::context::create()};
}

void context::run() { impl(*this).executor.run(); }

void context::on_last_exit(last_exit_handler h) {
  impl(*this).last_exit = move(h);
}

namespace debug {

void register_instance(context_impl &ctx, const handle &h);
void unregister_instance(context_impl &ctx, const string &name);
auto get_name(context_impl &ctx, const string &name) -> handle;
auto get_names(context_impl &ctx) -> buffer;

} // namespace debug

namespace {

auto is_exit_msg(const buffer &m) -> bool { return m("exit", any, more); }
const auto link_msg{array("link")};
auto is_link_msg(const buffer &m) -> bool { return m == link_msg; }
constexpr auto context_error = "call out of context";

} // namespace

auto handle_ref(handle &h) -> ref & { return h.ref_; }
auto handle_ref(const handle &h) -> const ref & { return h.ref_; }
auto make_handle(ref &&r) -> handle {
  handle h{};
  handle_ref(h) = move(r);
  return h;
}
auto ref_m(const instance *p) -> buffer;
auto ref_m(const ref &r) -> buffer;

template <typename... Ts> auto exit_message(string_view e, Ts &&...parms) {
  return buffer(array("exit", e, forward<Ts>(parms)...));
}

[[nodiscard]] auto exit() -> result { return to_error(exit_message("normal")); }

template <typename... Ts>
[[nodiscard]] auto exit(std::string_view e, Ts &&...parms) -> result {
  return to_error(exit_message(e, std::forward<Ts>(parms)...));
}

[[nodiscard]] auto exit(std::string_view e) -> result {
  return to_error(exit_message(e));
}

[[nodiscard]] auto exit(std::string_view e, std::string_view m) -> result {
  return to_error(exit_message(e, m));
}

[[nodiscard]] auto exit(std::string_view e, int err) -> result {
  return to_error(exit_message(e, err));
}

[[nodiscard]] auto exit(std::string_view e, size_t n) -> result {
  return to_error(exit_message(e, n));
}

[[nodiscard]] auto unexpected(const cbor::buffer &b) -> result {
  return exit("UNEXPECTED_MESSAGE:" + b.to_json());
}

auto deadsend(const buffer &m, const ref &from) -> result;
const auto exit_normal_msg = array("exit", "normal");
const auto exit_noreceive_msg = array("exit", "noreceive");
const auto exit_nosyncreceive_msg = array("exit", "nosyncreceive");

struct msg_task {
  explicit msg_task() = default;
  msg_task(const msg_task &) = default;
  msg_task(msg_task &&) = default;
  auto operator=(const msg_task &) -> msg_task & = default;
  auto operator=(msg_task &&) -> msg_task & = default;
  virtual ~msg_task() = default;
  virtual void operator()() = 0;
};

template <class F> struct msg_task_T : msg_task {
  explicit msg_task_T(F f) : f_(move(f)) {}
  void operator()() override { f_(); }

private:
  F f_;
};

struct instance : std::enable_shared_from_this<instance> {
  instance(const instance &) = delete;
  instance(const instance &&) = delete;
  auto operator=(const instance &) -> instance & = delete;
  auto operator=(instance &&) -> instance & = delete;

  instance(context_impl &ctx, behaviour b, exit_handler eh, string_view name,
           env_t env)
      : ctx(ctx), strand_(ctx.executor.create_strand()), name_{name},
        env_(move(env)) {
    if (eh)
      exit_handlers_.emplace_front(eh);
    receiver_ = [this, b{move(b)}](auto, auto) {
      this->do_trace(channel::lifetime, "init");
      receiver b_;
      b_.swap(receiver_);
      return b();
    };
    ctx.active_add();
  }
  ~instance() {
    auto prev = ctx.active_sub();
    if (debug::isenabled(ctx)) {
      do_trace_links(channel::link);
      if (is_enabled(channel::lifetime))
        do_trace_raw(ref_m(this), "living", debug::get_names(ctx));
    }
    do_trace(channel::lifetime, "destroyed", prev - 1);
    if (prev == 1) {
      do_trace(channel::lifetime, "last_exit");
      if (ctx.last_exit)
        ctx.last_exit();
    }
  }

  static auto spawn(context_impl &ctx, behaviour b, exit_handler eh,
                    string_view name, const ref &link, env_t env)
      -> expected<handle, error> {
    auto pimpl = make_shared<instance>(ctx, move(b), move(eh), name, move(env));
    pimpl->lifetime_ = pimpl;
    handle_ref(pimpl->self_ref_) = pimpl->lifetime_;
    pimpl->do_trace(channel::lifetime, "spawn");
    auto h = make_handle(pimpl);
    if (!link.expired()) {
      auto ret = pimpl->queue(link, link_msg);
      if (not ret)
        return to_error(ret.error());
    }
    auto ret = pimpl->schedule();
    if (not ret)
      return to_error(ret.error());
    debug::register_instance(ctx, h);
    return h;
  }

  auto name() const -> const string & { return name_; }

  auto is_enabled(channel c) -> bool { return env_.enabled(c); }

  template <typename... Ts> void do_trace_raw(Ts &&...parms) {
    auto a = ctx.active_load();
    long use_count{0};
    if (auto p = weak_from_this().lock())
      use_count = p.use_count() - 1;
    env_.trace(array(ctx.executor.pending_tasks(), ctx.executor.pending_posts(),
                     a, use_count, forward<Ts>(parms)...));
  }

  template <typename Tag, typename... Ts>
  void do_trace_to(channel c, Tag &&tag, const ref &to, Ts &&...parms) {
    if (is_enabled(c))
      do_trace_raw(ref_m(this), forward<Tag>(tag), ref_m(to),
                   forward<Ts>(parms)...);
  }

  template <typename... Ts> void do_trace(channel c, Ts &&...parms) {
    if (is_enabled(c))
      do_trace_raw(ref_m(this), forward<Ts>(parms)...);
  }

  template <typename... Ts> void do_trace_links(channel c) {
    if (is_enabled(c)) {
      int count{0};
      buffer c;
      for (auto &l : links_) {
        if (auto h = handle_ref(l).lock()) {
          ++count;
          c.push(h->name_);
        }
      }
      buffer b;
      b.array_header(count);
      b.push(c);
      do_trace_raw(ref_m(this), "links", b);
    }
  }

  auto get_strand() -> executor::strand & { return strand_; }

  void private_call() {
    if (!current_instance || current_instance != this)
      throw domain_error{context_error};
  }

  auto trace_enabled(channel c) { return env_.enabled(c); }

  template <class F> void submit_msg_task(F f) {
    strand_.post(msg_task_T<F>(f));
  }

  [[nodiscard]] auto dispatch_sync_raw(buffer m) -> result {
    ref from{};
    if (current_instance)
      from = current_instance->lifetime_;
    if (in_shutdown)
      return deadsend(m, from);
    run(from, move(m));
    return ok();
  }
  template <typename... Ts>
  [[nodiscard]] auto dispatch_sync(Ts &&...parms) -> result {
    return dispatch_sync_raw(array(std::forward<Ts>(parms)...));
  }

  [[nodiscard]] auto queue(const ref &from, buffer m) -> result {
    if ((not m.is_null()) and is_enabled(channel::send))
      do_trace_raw(ref_m(from), "send", ref_m(this), m);
    if (in_shutdown)
      return deadsend(m, from);

    auto run_m = [this, from{from}, m{move(m)}, lifelock{lifetime_}]() {
      run(from, m);
    };
    submit_msg_task(move(run_m));
    return ok();
  }
  [[nodiscard]] auto schedule() -> result {
    return queue(ref{}, buffer::null_value);
  }

  void handle_exit(const buffer &m) {
    in_shutdown = true;
    for (const auto &h : links_)
      auto _ = h.send_raw(m);
    do_trace(channel::lifetime, "exit", m);
    if (!exit_handlers_.empty()) {
      forward_list<exit_handler> exit_handlers;
      exit_handlers.swap(exit_handlers_);
      string bad_err;
      string_view err;
      if (!m(type::string, extract(err), type::more)) {
        bad_err = "bad_exit_message: " + m.to_json();
        err = bad_err;
      }
      for (auto &eh : exit_handlers)
        eh(err);
    }
    exited_receiver_.swap(receiver_);
    exited_sync_receiver_.swap(sync_receiver_);
    lifetime_.reset();
  }

  void run(ref from, buffer msg) {
#ifdef TRACY_ENABLE
    ZoneScopedN("actor");
#endif
    if (is_link_msg(msg)) {
      do_trace(channel::execute, "run");
      do_trace_to(channel::link, "link", from);
      links_.emplace_front(make_handle(move(from)));
      if (debug::isenabled(ctx))
        do_trace_links(channel::link);
      do_trace(channel::execute, "sleep");
      return;
    }
    if (in_shutdown)
      return;
    do_trace(channel::execute, "run");
    result ret;
    auto lifelock{lifetime_};
    try {
      if (current_instance && current_instance != this)
        throw domain_error{context_error};
      current_instance = this;
      if (!trap_exit_ && is_exit_msg(msg)) {
        if (msg != exit_normal_msg)
          handle_exit(msg);
      } else {
        if (!msg.is_null())
          do_trace_to(channel::receive, "receive", from, msg);
        ret = receiver_(make_handle(move(from)), move(msg));
        if (ret && current_instance && !receiver_)
          handle_exit(exit_noreceive_msg);
      }
      if (not ret)
        handle_exit(ret.error());
    } catch (std::exception &e) {
      if (!current_instance)
        throw;
      handle_exit(exit_message(string("UNHANDLED_EXCEPTION: ") + e.what()));
    } catch (...) {
      if (!current_instance)
        throw;
      handle_exit(exit_message("UNHANDLED_EXCEPTION"));
    }
    if (current_instance) {
      if (!in_shutdown)
        do_trace(channel::execute, "sleep");
      current_instance = nullptr;
    }
    receiver cleanup_receiver_;
    sync_receiver cleanup_sync_receiver_;
    cleanup_receiver_.swap(exited_receiver_);
    cleanup_sync_receiver_.swap(exited_sync_receiver_);
  }

  void receive(receiver &&b) {
    private_call();
    do_trace(channel::receive, "receive", "set");
    receiver_ = move(b);
  }

  void receive_sync(sync_receiver &&b) {
    private_call();
    do_trace(channel::receive, "receive_sync", "set");
    sync_receiver_ = move(b);
  }

  [[nodiscard]] auto send_raw(buffer m) -> result {
    ref from{};
    if (current_instance)
      from = current_instance->lifetime_;
    return queue(from, move(m));
  }
  template <typename... Ts> [[nodiscard]] auto send(Ts &&...parms) -> result {
    return send_raw(array(std::forward<Ts>(parms)...));
  }

  auto spawn_link(behaviour b, string_view name, env_t env)
      -> expected<handle, error> {
    auto ret = instance::spawn(ctx, move(b), exit_handler{}, name, lifetime_,
                               move(env));
    if (not ret)
      return ret;
    handle h = ret.value();
    do_trace_to(channel::link, "link", handle_ref(h));
    links_.emplace_front(h);
    return ret;
  }

  auto spawn_link(behaviour b, string_view name) -> expected<handle, error> {
    return spawn_link(move(b), name, env_);
  }

  auto trap() const -> bool { return trap_exit_; }
  auto trap(bool trap) -> bool {
    swap(trap, trap_exit_);
    return trap;
  }

  auto link(const handle &h) -> result {
    auto ret = h.send_raw(link_msg);
    if (not ret)
      return ret;
    do_trace_to(channel::link, "link", handle_ref(h));
    links_.emplace_front(h);
    return ok();
  }

  auto is_in_shutdown() -> bool { return in_shutdown; }

  context_impl &ctx;
  executor::strand strand_;
  string name_;
  receiver receiver_;
  receiver exited_receiver_;
  sync_receiver sync_receiver_;
  sync_receiver exited_sync_receiver_;
  forward_list<exit_handler> exit_handlers_;
  shared_ptr<instance> lifetime_;
  handle self_ref_;
  pair<ref, buffer> mailbox_;
  bool trap_exit_{false};
  bool in_shutdown{false};
  forward_list<handle> links_;
  env_t env_;
};

auto deadsend(const buffer &m) -> result {
  if (current_instance and !current_instance->is_in_shutdown() and
      !m("exit", type::more)) {
    return to_error(exit_message("DEADSEND", m));
  }
  return ok();
}

[[nodiscard]] auto handle::send_raw(buffer m) const -> result {
  if (auto p = ref_.lock()) {
    return p->send_raw(move(m));
  }
  return deadsend(m, ref_);
}

auto operator==(const handle &a, const handle &b) -> bool {
  return a.ref_.lock() == b.ref_.lock();
}

auto ref_m(const void *p, string name) -> buffer {
  stringstream ss;
  ss << p;
  return array("PID", ss.str(), move(name));
}

auto ref_m(const instance *p) -> buffer { return ref_m(p, p->name()); }

auto ref_m(const ref &r) -> buffer {
  if (auto p = r.lock())
    return ref_m(p.get(), p->name());
  return ref_m(nullptr, "none");
}

auto private_call() -> instance & {
  if (!current_instance)
    throw domain_error{context_error};
  return *current_instance;
}

auto private_call_noexcept() noexcept -> instance * {
  if (!current_instance)
    return nullptr;
  return current_instance;
}

auto trace_enabled(channel c) { return private_call().env_.enabled(c); }

auto spawn(behaviour b, string_view name) -> expected<handle, error> {
  auto &p = private_call();
  return instance::spawn(p.ctx, move(b), exit_handler{}, name, thespian::ref{},
                         p.env_);
}

auto spawn(behaviour b, string_view name, env_t env)
    -> expected<handle, error> {
  auto &p = private_call();
  return instance::spawn(p.ctx, move(b), exit_handler{}, name, thespian::ref{},
                         move(env));
}

auto context::spawn(behaviour b, string_view name, env_t env)
    -> expected<handle, error> {
  return instance::spawn(impl(*this), move(b), exit_handler{}, name,
                         thespian::ref{}, move(env));
}

auto context::spawn(behaviour b, string_view name) -> expected<handle, error> {
  return instance::spawn(impl(*this), move(b), exit_handler{}, name,
                         thespian::ref{}, env_t{});
}

auto context::spawn_link(behaviour b, exit_handler eh, string_view name,
                         env_t env) -> expected<handle, error> {
  if (!eh)
    throw domain_error{"exit_handler required"};
  return instance::spawn(impl(*this), move(b), move(eh), name, thespian::ref{},
                         move(env));
}

auto context::spawn_link(behaviour b, exit_handler eh, string_view name)
    -> expected<handle, error> {
  return spawn_link(move(b), move(eh), name, env_t{});
}

auto env() -> env_t & { return private_call().env_; }
auto self() -> handle { return make_handle(private_call().lifetime_); }
auto self_ref() -> handle & { return private_call().self_ref_; }
auto spawn_link(behaviour b, string_view name) -> expected<handle, error> {
  return private_call().spawn_link(move(b), name);
}
auto spawn_link(behaviour b, string_view name, env_t env)
    -> expected<handle, error> {
  return private_call().spawn_link(move(b), name, move(env));
}
auto send_raw(buffer m) -> result { return private_call().send_raw(move(m)); }
void receive(receiver r) { private_call().receive(move(r)); }
void receive_sync(sync_receiver r) { private_call().receive_sync(move(r)); }
auto trap() -> bool { return private_call().trap(); }
auto trap(bool t) -> bool { return private_call().trap(t); }
void link(const handle &h) { private_call().link(h); }

auto on_trace(trace_handler h) -> trace_handler {
  return private_call().env_.on_trace(move(h));
}

auto get_strand(const handle &h) -> executor::strand * {
  if (auto p = handle_ref(h).lock())
    return &p->strand_;
  return nullptr;
}

struct signal_impl {
  signal_impl(const signal_impl &) = delete;
  signal_impl(signal_impl &&) = delete;
  auto operator=(const signal_impl &) -> signal_impl & = delete;
  auto operator=(signal_impl &&) -> signal_impl & = delete;

  auto is_trace_enabled() { return owner_.env_.enabled(channel::signal); }

  signal_impl(int signum, buffer m)
      : owner_(private_call()), signal_(owner_.ctx.executor) {

    if (is_trace_enabled())
      owner_.env_.trace(array("signal", "set", m, signum));

    signal_.fires_on(signum);
    signal_.on_fired([this, m(move(m)), lifelock{owner_.lifetime_}](
                         const error_code &error, int signum) {
      if (is_trace_enabled())
        owner_.env_.trace(array("signal", "fired", m, signum, error.value(),
                                error.message()));
      if (!error)
        auto _ = owner_.send_raw(m);
      else
        auto _ = owner_.send_raw(
            exit_message("signal_error", error.value(), error.message()));
    });
  }
  ~signal_impl() { cancel(); }
  void cancel() { signal_.cancel(); }

  instance &owner_;
  executor::signal signal_;
};
void signal::cancel() {
  if (ref)
    ref->cancel();
}

auto create_signal(int signum, buffer m) -> signal {
  return {signal_ref(new signal_impl(signum, move(m)),
                     [](signal_impl *p) { delete p; })};
}
void cancel_signal(signal_impl *p) { p->cancel(); }
void destroy_signal(signal_impl *p) { delete p; }

struct metronome_impl {
  metronome_impl(const metronome_impl &) = delete;
  metronome_impl(metronome_impl &&) = delete;
  auto operator=(const metronome_impl &) -> metronome_impl & = delete;
  auto operator=(metronome_impl &&) -> metronome_impl & = delete;

  explicit metronome_impl(microseconds us)
      : owner_(private_call()), strand_(owner_.get_strand()), us_(us),
        timer_(strand_), is_trace_enabled_{trace_enabled(channel::metronome)},
        env_{private_call().env_} {}
  ~metronome_impl() { stop(); }

  void tick(const error_code &error) {
    if (error)
      return; // aborted
    if (not running_)
      return;
    last_tick_ = last_tick_ + us_;
    if (is_trace_enabled_)
      env_.trace(array("metronome", "tick", counter, us_.count()));
    result ret;
    if (!error)
      ret = owner_.send("tick", counter);
    else
      ret = owner_.send_raw(
          exit_message("metronome_error", error.message(), error.value()));
    counter++;
    if (ret)
      schedule_tick();
    else
      stop();
  }

  void schedule_tick() {
    timer_.expires_at(last_tick_ + us_);
    timer_.on_expired([this, lifelock{owner_.lifetime_}](
                          const error_code &error) { this->tick(error); });
  }

  void start() {
    if (running_)
      return;
    running_ = true;
    last_tick_ = clk::now();
    if (is_trace_enabled_)
      env_.trace(array("metronome", "start", us_.count()));
    schedule_tick();
  }

  void stop() {
    timer_.cancel();
    running_ = false;
  }

  instance &owner_;
  executor::strand strand_;
  microseconds us_;
  executor::timer timer_;
  system_clock::time_point last_tick_;
  bool running_{false};
  bool is_trace_enabled_{false};
  const env_t &env_;
  size_t counter{0};
};
void metronome::start() { ref->start(); }
void metronome::stop() { ref->stop(); }

auto create_metronome(microseconds us) -> metronome {
  return {metronome_ref(new metronome_impl(us), destroy_metronome)};
}
void start_metronome(metronome_impl *p) { p->start(); }
void stop_metronome(metronome_impl *p) { p->stop(); }
void destroy_metronome(metronome_impl *p) { delete p; }

struct timeout_impl {
  timeout_impl(const timeout_impl &) = delete;
  timeout_impl(timeout_impl &&) = delete;
  auto operator=(const timeout_impl &) -> timeout_impl & = delete;
  auto operator=(timeout_impl &&) -> timeout_impl & = delete;

  auto is_trace_enabled() { return owner_.env_.enabled(channel::timer); }

  timeout_impl(microseconds us, buffer m)
      : owner_(private_call()), timer_(owner_.ctx.executor) {
    auto start = clk::now().time_since_epoch().count();

    if (is_trace_enabled())
      owner_.env_.trace(array("timeout", "set", m, us.count()));

    timer_.expires_after(us);
    timer_.on_expired([this, start, m(move(m)),
                       lifelock{owner_.lifetime_}](const error_code &error) {
      if (is_trace_enabled())
        owner_.env_.trace(array("timeout", "expired", m,
                                clk::now().time_since_epoch().count() - start,
                                error.value(), error.message()));
      if (!error)
        auto _ = owner_.send_raw(m);
      else
        auto _ = owner_.send_raw(
            exit_message("timeout_error", error.value(), error.message()));
    });
  }
  ~timeout_impl() { cancel(); }
  void cancel() { timer_.cancel(); }

  instance &owner_;
  executor::timer timer_;
};
void timeout::cancel() {
  if (ref)
    ref->cancel();
}

auto create_timeout(microseconds us, buffer m) -> timeout {
  return {timeout_ref(new timeout_impl(us, move(m)), destroy_timeout)};
}
void cancel_timeout(timeout_impl *p) { p->cancel(); }
void destroy_timeout(timeout_impl *p) { delete p; }
auto never() -> timeout { return {timeout_ref(nullptr, destroy_timeout)}; }

struct udp_impl {
  udp_impl(const udp_impl &) = delete;
  udp_impl(udp_impl &&) = delete;
  auto operator=(const udp_impl &) -> udp_impl & = delete;
  auto operator=(udp_impl &&) -> udp_impl & = delete;

  explicit udp_impl(string tag)
      : owner_(private_call()), strand_(owner_.get_strand()), socket_(strand_),
        tag_(move(tag)), is_trace_enabled_{owner_.env_.enabled(channel::udp)} {}
  ~udp_impl() = default;

  auto open(in6_addr ip, port_t port) -> port_t {
    if (is_trace_enabled_)
      owner_.env_.trace(array("udp", tag_, "open", port));
    if (auto ec = socket_.bind(ip, port)) {
      auto _ = owner_.send("udp", tag_, "open_error", ec.value(), ec.message());
    } else {
      open_ = true;
      do_receive();
    }
    return socket_.local_endpoint().port;
  }

  void do_receive() {
    socket_.receive([this, lifelock{owner_.lifetime_}](error_code error,
                                                       std::size_t received) {
      this->receive(error, received);
    });
  }

  void receive(error_code ec, std::size_t received) {
    if (!open_)
      return;
    if (received == 0)
      return;
    if (ec) {
      if (is_trace_enabled_)
        owner_.env_.trace(array("udp", tag_, "receive_error", received,
                                ec.value(), ec.message()));
      auto _ =
          owner_.send("udp", tag_, "receive_error", ec.value(), ec.message());
    } else {
      string_view data(socket_.receive_buffer.data(), received);
      if (is_trace_enabled_)
        owner_.env_.trace(array("udp", tag_, "receive", received, data));
      auto _ = owner_.send("udp", tag_, "receive", data,
                           socket_.remote_endpoint().ip,
                           socket_.remote_endpoint().port);
      do_receive();
    }
  }

  [[nodiscard]] auto sendto(string_view data, in6_addr ip, port_t port)
      -> size_t {
    if (is_trace_enabled_)
      owner_.env_.trace(
          array("udp", tag_, "sendto", data, executor::to_string(ip), port));
    return socket_.send_to(data, ip, port);
  }

  void close() {
    if (open_) {
      socket_.close();
      open_ = false;
    }
    auto _ = owner_.send("udp", tag_, "closed");
  }

  instance &owner_;
  executor::strand strand_;
  executor::udp::socket socket_;
  string tag_;
  bool open_{false};
  bool is_trace_enabled_{false};
};

auto udp::open(const in6_addr &ip, port_t port) -> port_t {
  return ref->open(ip, port);
}
auto udp::sendto(string_view data, in6_addr ip, port_t port) -> size_t {
  return ref->sendto(data, ip, port);
}
void udp::close() { ref->close(); }

auto udp::create(string tag) -> udp {
  return {udp_ref(new udp_impl(move(tag)), [](udp_impl *p) { delete p; })};
}

#if !defined(_WIN32)

struct file_descriptor_impl {
  file_descriptor_impl(const file_descriptor_impl &) = delete;
  file_descriptor_impl(file_descriptor_impl &&) = delete;
  auto operator=(const file_descriptor_impl &)
      -> file_descriptor_impl & = delete;
  auto operator=(file_descriptor_impl &&) -> file_descriptor_impl & = delete;

  file_descriptor_impl(string_view tag, int fd)
      : owner_(private_call()), strand_(owner_.get_strand()),
        file_descriptor_(strand_, fd), tag_(tag) {}

  ~file_descriptor_impl() = default;

  void wait_write() {
    private_call();
    file_descriptor_.wait_write(
        [this, liffile_descriptor_elock{owner_.lifetime_}](error_code ec) {
          if (ec) {
            auto _ = owner_.send("fd", tag_, "write_error", ec.value(),
                                 ec.message());
          } else {
            auto _ = owner_.send("fd", tag_, "write_ready");
          }
        });
  }

  void wait_read() {
    private_call();
    file_descriptor_.wait_read(
        [this, liffile_descriptor_elock{owner_.lifetime_}](error_code ec) {
          if (ec) {
            auto _ =
                owner_.send("fd", tag_, "read_error", ec.value(), ec.message());
          } else {
            auto _ = owner_.send("fd", tag_, "read_ready");
          }
        });
  }

  void cancel() {
    private_call();
    file_descriptor_.cancel();
  }

  instance &owner_;
  executor::strand strand_;
  executor::file_descriptor::watcher file_descriptor_;
  string tag_;
};

auto file_descriptor::create(string_view tag, int fd) -> file_descriptor {
  return {file_descriptor_ref(new file_descriptor_impl(tag, fd),
                              [](file_descriptor_impl *p) { delete p; })};
}

void file_descriptor::wait_write() { ref->wait_write(); }
void file_descriptor::wait_read() { ref->wait_read(); }
void file_descriptor::cancel() { ref->cancel(); }

void file_descriptor::wait_write(file_descriptor_impl *p) { p->wait_write(); }
void file_descriptor::wait_read(file_descriptor_impl *p) { p->wait_read(); }
void file_descriptor::cancel(file_descriptor_impl *p) { p->cancel(); }
void file_descriptor::destroy(file_descriptor_impl *p) { delete p; }

#else

struct file_stream_impl {
  file_stream_impl(const file_stream_impl &) = delete;
  file_stream_impl(file_stream_impl &&) = delete;
  auto operator=(const file_stream_impl &) -> file_stream_impl & = delete;
  auto operator=(file_stream_impl &&) -> file_stream_impl & = delete;

  file_stream_impl(string_view tag, void *handle)
      : owner_(private_call()), strand_(owner_.get_strand()),
        file_stream_(strand_, handle), tag_(tag) {}

  ~file_stream_impl() = default;

  void start_read() {
    private_call();
    file_stream_.start_read([this, liffile_stream_elock{owner_.lifetime_}](
                                error_code ec, string_view data) {
      if (ec) {
        auto _ =
            owner_.send("stream", tag_, "read_error", ec.value(), ec.message());
      } else {
        auto _ = owner_.send("stream", tag_, "read_complete", data);
      }
    });
  }

  void start_write(string_view data) {
    private_call();
    file_stream_.start_write(data, [this,
                                    liffile_stream_elock{owner_.lifetime_}](
                                       error_code ec, size_t bytes_written) {
      if (ec) {
        auto _ =
            owner_.send("stream", tag_, "write_error", ec.value(), ec.message());
      } else {
        auto _ = owner_.send("stream", tag_, "write_complete", bytes_written);
      }
    });
  }

  void cancel() {
    private_call();
    file_stream_.cancel();
  }

  instance &owner_;
  executor::strand strand_;
  executor::file_stream file_stream_;
  string tag_;
};

auto file_stream::create(string_view tag, void *handle) -> file_stream {
  return {file_stream_ref(new file_stream_impl(tag, handle),
                          [](file_stream_impl *p) { delete p; })};
}

void file_stream::start_read() { ref->start_read(); }
void file_stream::start_write(string_view data) { ref->start_write(data); }
void file_stream::cancel() { ref->cancel(); }

void file_stream::start_read(file_stream_impl *p) { p->start_read(); }
void file_stream::start_write(file_stream_impl *p, string_view data) {
  p->start_write(data);
}
void file_stream::cancel(file_stream_impl *p) { p->cancel(); }
void file_stream::destroy(file_stream_impl *p) { delete p; }

#endif

struct socket_impl {
  socket_impl(const socket_impl &) = delete;
  socket_impl(socket_impl &&) = delete;
  auto operator=(const socket_impl &) -> socket_impl & = delete;
  auto operator=(socket_impl &&) -> socket_impl & = delete;

  socket_impl(string_view tag, int fd)
      : owner_(private_call()), strand_(owner_.get_strand()), fd_(fd),
        socket_(strand_, fd), tag_(tag), open_(true) {}

  virtual ~socket_impl() { socket_.close(); };

  void write_complete(std::size_t length) {
    auto ret = owner_.dispatch_sync("socket", tag_, "write_complete", length);
    if (not ret)
      auto _ = close_internal();
    write_pending_ = false;
    if (length < write_buf_.size()) {
      auto e = write_buf_.begin();
      for (size_t x{0}; x < length; ++x)
        e++;
      write_buf_.erase(write_buf_.begin(), e);
      write_internal();
      return;
    }
    write_buf_.clear();
    if (not write_q_.empty()) {
      write_buf_.swap(write_q_);
      write_internal();
    }
  }

  void write_internal() {
    write_pending_ = true;
    socket_.write(write_buf_, [this, lifelock{owner_.lifetime_}](
                                  error_code ec, std::size_t length) {
      if (ec) {
        auto _ = owner_.dispatch_sync("socket", tag_, "write_error", ec.value(),
                                      ec.message());
        _ = close_internal();
      } else {
        write_complete(length);
      }
    });
  }

  void write(string_view buf) {
    private_call();
    if (write_pending_) {
      write_q_.insert(write_q_.end(), buf.begin(), buf.end());
      return;
    }
    write_buf_.insert(write_buf_.begin(), buf.begin(), buf.end());
    write_internal();
  }

  void write(const vector<uint8_t> &buf) {
    private_call();
    if (write_pending_) {
      write_q_.insert(write_q_.end(), buf.begin(), buf.end());
      return;
    }
    write_buf_.insert(write_buf_.begin(), buf.begin(), buf.end());
    write_internal();
  }

  void read() {
    private_call();
    socket_.read([this, lifelock{owner_.lifetime_}](error_code ec,
                                                    std::size_t length) {
      if (!open_)
        return;
      if (ec) {
        if (length == 0 and ec.value() == 2) { // EOF
          auto ret = owner_.dispatch_sync("socket", tag_, "read_complete",
                                          string_view{});
          if (not ret)
            auto _ = close_internal();
        } else if (ec.value() == 125) { // ECANCELLED
          auto _ = close_internal();
        } else {
          auto _ = owner_.dispatch_sync("socket", tag_, "read_error",
                                        ec.value(), ec.message());
        }
      } else {
        string_view buf{};
        if (length > 0)
          buf = string_view(socket_.read_buffer.data(), length);
        auto ret = owner_.dispatch_sync("socket", tag_, "read_complete", buf);
        if (not ret)
          auto _ = close_internal();
      }
    });
  }

  [[nodiscard]] auto close_internal() -> result {
    if (open_) {
      open_ = false;
      socket_.close();
    }
    return owner_.send("socket", tag_, "closed");
  }

  auto close() -> result {
    private_call();
    return close_internal();
  }

  instance &owner_;
  executor::strand strand_;
  int fd_;
  executor::tcp::socket socket_;
  string tag_;
  bool open_{false};
  vector<uint8_t> write_buf_;
  vector<uint8_t> write_q_;
  bool write_pending_{false};
};

auto socket::create(string_view tag, int fd) -> socket {
  return {
      socket_ref(new socket_impl(tag, fd), [](socket_impl *p) { delete p; })};
}

void socket::write(string_view data) { ref->write(data); }
void socket::write(const vector<uint8_t> &data) { ref->write(data); }
void socket::read() { ref->read(); }
void socket::close() { ref->close(); }

namespace tcp {

struct acceptor_impl {
  explicit acceptor_impl(string_view tag)
      : owner_(private_call()), strand_(owner_.get_strand()),
        acceptor_(strand_), tag_(tag) {}

  auto listen(const in6_addr &ip, port_t port) -> port_t {
    private_call();
    if (auto ec = acceptor_.bind(ip, port)) {
      auto _ = owner_.send("acceptor", tag_, "error", ec.value(), ec.message());
      return 0;
    }
    if (auto ec = acceptor_.listen()) {
      auto _ = owner_.send("acceptor", tag_, "error", ec.value(), ec.message());
      return 0;
    }
    start_accept();
    open_ = true;
    return acceptor_.local_endpoint().port;
  }

  void accept(int fd, error_code ec) {
    if (!open_)
      return;
    if (ec) {
      auto _ = owner_.dispatch_sync("acceptor", tag_, "error", ec.value(),
                                    ec.message());
      return;
    }
    auto ret = owner_.dispatch_sync("acceptor", tag_, "accept", fd);
    if (not ret)
      return close();
    start_accept();
  }

  void start_accept() {
    acceptor_.accept([this](int fd, error_code ec) -> void { accept(fd, ec); });
  }

  void close() {
    private_call();
    acceptor_.close();
    auto _ = owner_.send("acceptor", tag_, "closed");
    open_ = false;
  }

  instance &owner_;
  executor::strand strand_;
  executor::tcp::acceptor acceptor_;
  string tag_;
  bool open_{false};
};

auto acceptor::create(string_view tag) -> acceptor {
  return {
      acceptor_ref(new acceptor_impl(tag), [](acceptor_impl *p) { delete p; })};
}

auto acceptor::listen(in6_addr ip, port_t port) -> port_t {
  return ref->listen(ip, port);
}
void acceptor::close() { ref->close(); }

struct connector_impl {
  explicit connector_impl(string_view tag)
      : owner_(private_call()), strand_(owner_.get_strand()), socket_(strand_),
        tag_(tag) {}

  void connect(in6_addr ip, port_t port, in6_addr lip, port_t lport) {
    private_call();
    open_ = true;
    if (auto ec = socket_.bind(lip, lport)) {
      auto _ =
          owner_.send("connector", tag_, "error", ec.value(), ec.message());
      return;
    }
    socket_.connect(ip, port, [this](error_code ec) -> void {
      if (!open_)
        return;
      if (ec) {
        auto _ = owner_.dispatch_sync("connector", tag_, "error", ec.value(),
                                      ec.message());
        return;
      }
      auto fd = socket_.release();
      auto ret = owner_.dispatch_sync("connector", tag_, "connected", fd);
      if (not ret) {
        cancel();
        executor::tcp::socket socket_cleanup(strand_, fd);
        socket_cleanup.close();
      }
    });
  }

  void cancel() {
    private_call();
    socket_.close();
    open_ = false;
    auto _ = owner_.send("connector", tag_, "cancelled");
  }

  instance &owner_;
  executor::strand strand_;
  executor::tcp::socket socket_;
  string tag_;
  bool open_{false};
};

auto connector::create(string_view tag) -> connector {
  return {connector_ref(new connector_impl(tag),
                        [](connector_impl *p) { delete p; })};
}

void connector::connect(in6_addr ip, port_t port) {
  ref->connect(ip, port, in6addr_any, 0);
}

void connector::connect(in6_addr ip, port_t port, in6_addr lip) {
  ref->connect(ip, port, lip, 0);
}

void connector::connect(in6_addr ip, port_t port, port_t lport) {
  ref->connect(ip, port, in6addr_any, lport);
}
void connector::connect(in6_addr ip, port_t port, in6_addr lip, port_t lport) {
  ref->connect(ip, port, lip, lport);
}

void connector::cancel() { ref->cancel(); }

} // namespace tcp

namespace unx {

auto unx_mode_string(mode m) -> const char * {
  switch (m) {
  case mode::file:
    return "file";
  case mode::abstract:
    return "abstract";
  }
  return "unknown";
}

auto unx_mode_path(mode m, string_view path) -> string {
  switch (m) {
  case mode::file:
    return string(path);
  case mode::abstract:
    string abspath = "#";
    abspath.append(path);
    abspath[0] = '\0';
    return abspath;
  }
  return "unknown";
}

struct acceptor_impl {
  explicit acceptor_impl(string_view tag)
      : owner_(private_call()), strand_(owner_.get_strand()),
        acceptor_(strand_), tag_(tag) {}

  void listen(string_view origpath, mode m) {
    private_call();
    const string path = unx_mode_path(m, origpath);
    if (auto ec = acceptor_.bind(path)) {
      auto _ = owner_.send("acceptor", tag_, "error", ec.value(), ec.message());
      return;
    }
    if (auto ec = acceptor_.listen()) {
      auto _ = owner_.send("acceptor", tag_, "error", ec.value(), ec.message());
      return;
    }
    start_accept();
    open_ = true;
  }

  void accept(int fd, error_code ec) {
    if (!open_)
      return;
    if (ec) {
      auto _ = owner_.dispatch_sync("acceptor", tag_, "error", ec.value(),
                                    ec.message());
      return;
    }
    auto ret = owner_.dispatch_sync("acceptor", tag_, "accept", fd);
    if (not ret)
      return close();
    start_accept();
  }

  void start_accept() {
    acceptor_.accept([this](int fd, error_code ec) -> void { accept(fd, ec); });
  }

  void close() {
    private_call();
    acceptor_.close();
    auto _ = owner_.send("acceptor", tag_, "closed");
    open_ = false;
  }

  instance &owner_;
  executor::strand strand_;
  executor::unx::acceptor acceptor_;
  string tag_;
  bool open_{false};
};

auto acceptor::create(string_view tag) -> acceptor {
  return {
      acceptor_ref(new acceptor_impl(tag), [](acceptor_impl *p) { delete p; })};
}

void acceptor::listen(string_view path, mode m) { ref->listen(path, m); }
void acceptor::close() { ref->close(); }

struct connector_impl {
  explicit connector_impl(string_view tag)
      : owner_(private_call()), strand_(owner_.get_strand()), socket_(strand_),
        tag_(tag) {}

  void connect(string_view origpath, mode m) {
    private_call();
    open_ = true;
    const string path = unx_mode_path(m, origpath);
    socket_.connect(path, [this](error_code ec) -> void {
      if (!open_)
        return;
      if (ec) {
        auto _ = owner_.dispatch_sync("connector", tag_, "error", ec.value(),
                                      ec.message());
        return;
      }
      auto fd = socket_.release();
      auto ret = owner_.dispatch_sync("connector", tag_, "connected", fd);
      if (not ret) {
        cancel();
        executor::unx::socket socket_cleanup(strand_, fd);
        socket_cleanup.close();
      }
    });
  }

  void cancel() {
    private_call();
    socket_.close();
    open_ = false;
    auto _ = owner_.send("connector", tag_, "cancelled");
  }

  instance &owner_;
  executor::strand strand_;
  executor::unx::socket socket_;
  string tag_;
  bool open_{false};
};

auto connector::create(string_view tag) -> connector {
  return {connector_ref(new connector_impl(tag),
                        [](connector_impl *p) { delete p; })};
}

void connector::connect(string_view path, mode m) { ref->connect(path, m); }

void connector::cancel() { ref->cancel(); }

} // namespace unx

namespace endpoint {

struct connection {
  socket s;
  handle owner;
  vector<uint8_t> read_buf;
  bool is_trace_enabled_{false};
  const env_t &env_;
  string_view tag;

  bool write_pending{false};
  bool close_on_write_complete{false};

  template <typename... Ts> auto trace(Ts &&...parms) {
    if (is_trace_enabled_) {
      stringstream ss;
      ss << this;
      env_.trace(array(ref_m(private_call_noexcept()), tag, ss.str(),
                       forward<Ts>(parms)...));
    }
  }

  connection(int fd, handle o, const char *tag)
      : s{socket::create(tag, fd)}, owner{move(o)},
        is_trace_enabled_{trace_enabled(channel::endpoint)},
        env_{private_call().env_}, tag{tag} {
    read();
  }

  void read() {
    trace("read");
    s.read();
  }

  void write(const buffer &buf) {
    write_pending = true;
    trace("write", buf);
    s.write(buf);
  }

  void close() {
    close_on_write_complete = true;
    if (!write_pending) {
      trace("close");
      s.close();
    }
  }

  auto receive(const handle & /*from*/, const buffer &m) -> result {
    string_view data;
    int written = 0;
    int err = 0;
    string_view err_msg{};
    if (m("socket", tag, "read_error", extract(err), extract(err_msg))) {
      owner.exit("read_error", err_msg);
      close();
    } else if (m("socket", tag, "read_complete", extract(data))) {
      if (data.empty()) {
        close();
      } else {
        read_buf.insert(read_buf.end(), data.begin(), data.end());
        while (not read_buf.empty()) {
          try {
            auto msg_e = read_buf.cbegin();
            auto b = read_buf.cbegin();
            buffer::range msg;
            if (!extract(msg)(msg_e, read_buf.cend())) {
              owner.exit("framing_error");
              close();
            }
            auto ret = owner.send_raw(buffer(b, msg_e));
            read_buf.erase(b, msg_e);
            if (not ret)
              close();
          } catch (const domain_error &e) {
            break;
          }
        }
        read();
      }
    } else if (m("socket", tag, "write_error", extract(err),
                 extract(err_msg))) {
      owner.exit("write_error", err_msg);
      close();
    } else if (m("socket", tag, "write_complete", extract(written))) {
      write_pending = false;
      if (close_on_write_complete) {
        close();
      }
    } else if (m("socket", tag, "closed")) {
      return exit("closed");
    } else if (is_exit_msg(m)) {
      write(m);
      close();
    } else {
      write(m);
    }
    return ok();
  }

  static auto start(int fd, const handle &owner, const char *tag)
      -> expected<handle, error> {
    return spawn(
        [fd, owner, tag]() {
          link(owner);
          trap(true);
          ::thespian::receive(
              [p{make_shared<connection>(fd, owner, tag)}](auto from, auto m) {
                return p->receive(move(from), move(m));
              });
          return ok();
        },
        tag);
  }

  static void attach(int fd, handle owner, const char *tag) {
    private_call().name_ = tag;
    ::thespian::receive(
        [p{make_shared<connection>(fd, owner, tag)}](auto from, auto m) {
          return p->receive(move(from), move(m));
        });
  }
};

namespace tcp {

struct connector {
  static constexpr string_view tag{"endpoint::tcp::connector"};
  ::thespian::tcp::connector c;
  handle owner;
  size_t connection_count{};
  in6_addr ip;
  port_t port;
  milliseconds retry_time{};
  size_t retry_count{};
  timeout retry_timeout{never()};

  explicit connector(in6_addr ip_, port_t port_, handle o,
                     milliseconds retry_time, size_t retry_count)
      : c{::thespian::tcp::connector::create(tag)}, owner{move(o)}, ip{ip_},
        port{port_}, retry_time(retry_time), retry_count(retry_count) {
    connection_count++;
    c.connect(ip, port);
  }

  auto receive(const handle & /*from*/, const buffer &m) -> result {
    int fd = 0;
    int ec{};
    string data;

    if (m("connector", tag, "connected", extract(fd))) {
      auto ret = owner.send("connected");
      if (not ret)
        return ret;
      connection::attach(fd, owner, "endpoint::tcp::active");
    } else if (m("connector", tag, "cancelled")) {
      return exit("cancelled");
    } else if (m("connector", tag, "error", extract(ec), extract(data))) {
      if (connection_count > retry_count) {
        return exit("connect_error", data);
      }
      connection_count++;
      retry_timeout =
          create_timeout(retry_time, array("connector", tag, "retry"));
      retry_time *= 2;
    } else if (m("connector", tag, "retry")) {
      c.connect(ip, port);
    } else if (is_exit_msg(m)) {
      c.cancel();
    } else {
      return unexpected(m);
    }
    return ok();
  }

  static auto connect(in6_addr ip, port_t port, milliseconds retry_time,
                      size_t retry_count) -> expected<handle, error> {
    const handle owner = self();
    return spawn_link(
        [=]() {
          trap(true);
          ::thespian::receive(
              [p{make_shared<connector>(ip, port, owner, retry_time,
                                        retry_count)}](auto from, auto m) {
                return p->receive(move(from), move(m));
              });
          return ok();
        },
        tag);
  }
};

struct acceptor {
  static constexpr string_view tag{"endpoint::tcp::acceptor"};
  acceptor(const acceptor &) = delete;
  acceptor(acceptor &&) = delete;
  auto operator=(const acceptor &) -> acceptor & = delete;
  auto operator=(acceptor &&) -> acceptor & = delete;

  ::thespian::tcp::acceptor a;
  handle owner;
  port_t listen_port;

  acceptor(in6_addr ip, port_t port, handle o)
      : a{::thespian::tcp::acceptor::create(tag)}, owner{move(o)},
        listen_port{a.listen(ip, port)} {}
  ~acceptor() = default;

  auto receive(const handle &from, const buffer &m) -> result {
    int fd = 0;
    string err;

    if (m("acceptor", tag, "accept", extract(fd))) {
      connection::start(fd, owner, "endpoint::tcp::passive");
    } else if (m("acceptor", tag, "closed")) {
      return exit("closed");
    } else if (m("acceptor", tag, "error", extract(err))) {
      return exit(err);
    } else if (m("ping")) {
      return from.send("pong");
    } else if (m("get", "port")) {
      return from.send("port", listen_port);
    } else if (is_exit_msg(m)) {
      a.close();
    } else {
      return unexpected(m);
    }
    return ok();
  }

  static auto start(in6_addr ip, port_t port) -> expected<handle, error> {
    const handle owner = self();
    return spawn_link(
        [=]() {
          trap(true);
          ::thespian::receive(
              [p{make_shared<acceptor>(ip, port, owner)}](auto from, auto m) {
                return p->receive(move(from), move(m));
              });
          return ok();
        },
        tag);
  }
};

auto listen(in6_addr ip, port_t port) -> expected<handle, error> {
  return acceptor::start(ip, port);
}
auto connect(in6_addr ip, port_t port, milliseconds retry_time,
             size_t retry_count) -> expected<handle, error> {
  return connector::connect(ip, port, retry_time, retry_count);
}

} // namespace tcp

#if !defined(_WIN32)
namespace unx {

struct connector {
  static constexpr string_view tag{"endpoint::unx::connector"};
  ::thespian::unx::connector c;
  handle owner;
  size_t connection_count{};
  string path_;
  mode mode_;
  milliseconds retry_time{};
  size_t retry_count{};
  timeout retry_timeout{never()};

  explicit connector(string_view path, mode m, handle o,
                     milliseconds retry_time, size_t retry_count)
      : c{::thespian::unx::connector::create(tag)}, owner{move(o)}, path_{path},
        mode_{m}, retry_time(retry_time), retry_count(retry_count) {
    connection_count++;
    c.connect(path_, mode_);
  }

  auto receive(const handle & /*from*/, const buffer &m) -> result {
    int fd = 0;
    int ec{0};
    string data;

    if (m("connector", tag, "connected", extract(fd))) {
      retry_timeout.cancel();
      auto ret = owner.send("connected");
      if (not ret) {
        executor::tcp::socket::close(fd);
        return ret;
      }
      connection::attach(fd, owner, "endpoint::unx::active");
    } else if (m("connector", tag, "cancelled")) {
      return exit("cancelled");
    } else if (m("connector", tag, "error", extract(ec), extract(data))) {
      if (connection_count > retry_count) {
        return exit("connect_error", data);
      }
      connection_count++;
      retry_timeout =
          create_timeout(retry_time, array("connector", tag, "retry"));
      retry_time *= 2;
    } else if (m("connector", tag, "retry")) {
      c.connect(path_, mode_);
    } else if (is_exit_msg(m)) {
      c.cancel();
    } else {
      return unexpected(m);
    }
    return ok();
  }

  static auto connect(string_view path, mode m_, milliseconds retry_time,
                      size_t retry_count) -> expected<handle, error> {
    const handle owner = self();
    return spawn_link(
        [path{string(path)}, m_, owner, retry_time, retry_count]() {
          trap(true);
          ::thespian::receive(
              [p{make_shared<connector>(path, m_, owner, retry_time,
                                        retry_count)}](auto from, auto m) {
                return p->receive(move(from), move(m));
              });
          return ok();
        },
        tag);
  }
};

struct acceptor {
  static constexpr string_view tag{"endpoint::unx::acceptor"};
  acceptor(const acceptor &) = delete;
  acceptor(acceptor &&) = delete;
  auto operator=(const acceptor &) -> acceptor & = delete;
  auto operator=(acceptor &&) -> acceptor & = delete;

  ::thespian::unx::acceptor a;
  handle owner;
  string listen_path;

  acceptor(string_view path, mode m, handle o)
      : a{::thespian::unx::acceptor::create(tag)}, owner{move(o)}, listen_path{
                                                                       path} {
    a.listen(path, m);
  }
  ~acceptor() = default;

  auto receive(const handle &from, const buffer &m) -> result {
    int fd = 0;
    string err;

    if (m("acceptor", tag, "accept", extract(fd))) {
      connection::start(fd, owner, "endpoint::unx::passive");
    } else if (m("acceptor", tag, "closed")) {
      return exit("closed");
    } else if (m("acceptor", tag, "error", extract(err))) {
      return exit(err);
    } else if (m("ping")) {
      return from.send("pong");
    } else if (m("get", "path")) {
      return from.send("path", listen_path);
    } else if (is_exit_msg(m)) {
      a.close();
    } else {
      return unexpected(m);
    }
    return ok();
  }

  static auto start(string_view path, mode m_) -> expected<handle, error> {
    const handle owner = self();
    return spawn_link(
        [path{string(path)}, m_, owner]() {
          trap(true);
          ::thespian::receive(
              [p{make_shared<acceptor>(path, m_, owner)}](auto from, auto m) {
                return p->receive(move(from), move(m));
              });
          return ok();
        },
        tag);
  }
};

auto listen(string_view path, mode m) -> expected<handle, error> {
  return acceptor::start(path, m);
}
auto connect(string_view path, mode m, milliseconds retry_time,
             size_t retry_count) -> expected<handle, error> {
  return connector::connect(path, m, retry_time, retry_count);
}

} // namespace unx
#endif
} // namespace endpoint

namespace debug {

void enable(context_impl &ctx) {
  ctx.debug_enabled.fetch_add(1, memory_order_relaxed);
}
void enable(context &ctx) { enable(impl(ctx)); }
auto isenabled(context_impl &ctx) -> bool {
  return ctx.debug_enabled.load(memory_order_relaxed) > 0;
}
auto isenabled(context &ctx) -> bool { return isenabled(impl(ctx)); }
void disable(context_impl &ctx) {
  auto prev = ctx.debug_enabled.fetch_sub(1, memory_order_relaxed);
  if (prev == 1) {
    const lock_guard<mutex> lock(ctx.registry_mux);
    ctx.registry.clear();
  }
}
void disable(context &ctx) { disable(impl(ctx)); }

void register_instance(context_impl &ctx, const handle &h) {
  if (not isenabled(ctx))
    return;
  auto &r = handle_ref(h);
  if (auto p = r.lock()) {
    auto &name = p->name();
    if (name.empty())
      return;
    // if (trace)
    //   trace(array("register", name, ref_m(r)));
    const lock_guard<mutex> lock(ctx.registry_mux);
    ctx.registry[name] = h;
  }
}

void unregister_instance(context_impl &ctx, const string &name) {
  if (not isenabled(ctx))
    return;
  const lock_guard<mutex> lock(ctx.registry_mux);
  // if (trace)
  //   trace(array("unregister", name, ref_m(handle_ref(registry[name]))));
  ctx.registry.erase(name);
}

auto get_name(context_impl &ctx, const string &name) -> handle {
  const lock_guard<mutex> lock(ctx.registry_mux);
  auto r = ctx.registry.find(name);
  return r != ctx.registry.end() ? r->second : handle{};
}

auto get_names(context_impl &ctx) -> buffer {
  vector<string> names;
  {
    const lock_guard<mutex> lock(ctx.registry_mux);
    for (const auto &a : ctx.registry)
      if (not a.second.expired())
        names.push_back(a.first);
  }
  buffer b;
  b.array_header(names.size());
  for (const auto &n : names) {
    b.push(n);
  }
  return b;
}

namespace tcp {

struct connection {
  static constexpr string_view tag{"debug_tcp_connection"};
  context_impl &ctx;
  socket s;
  string prompt;
  string prev_buf;
  bool close_on_write_complete{false};

  connection(context_impl &ctx, int fd, string _prompt)
      : ctx{ctx}, s{socket::create(tag, fd)}, prompt(move(_prompt)) {
    s.write(prompt);
    s.read();
  }

  auto getword(string str, const string &delim = " ") -> pair<string, string> {
    string::size_type pos{};
    pos = str.find_first_of(delim);
    if (pos == string::npos)
      return make_pair(str, "");
    const string word(str.data(), pos);
    str.erase(0, pos + 1);
    return make_pair(word, str);
  }

  auto dispatch(string buf) -> bool {
    if (buf.empty()) {
      vector<string> expired_names;
      {
        const lock_guard<mutex> lock(ctx.registry_mux);
        bool first{true};
        for (const auto &a : ctx.registry) {
          if (not a.second.expired()) {
            if (first)
              first = false;
            else
              s.write(" ");
            s.write(a.first);
          } else {
            expired_names.push_back(a.first);
          }
        }
      }
      s.write("\n");
      for (const auto &a : expired_names)
        debug::unregister_instance(ctx, a);
    } else if (buf == "bye") {
      s.write("bye\n");
      return false;
    } else {
      auto x = getword(buf);
      buf = x.second;
      const handle a = get_name(ctx, x.first);
      if (a.expired()) {
        s.write("error: ");
        s.write(x.first);
        s.write(" not found\n");
      } else {
        try {
          buffer m;
          m.push_json(buf);
          auto ret = a.send_raw(m);
          if (not ret) {
            s.write("error: ");
            s.write(ret.error().to_json());
            s.write("\n");
          }
        } catch (const domain_error &e) {
          s.write("error: ");
          s.write(e.what());
          s.write("\n");
        }
      }
    }
    s.write(prompt);
    return true;
  }

  auto receive(handle from, const buffer &m) -> result {
    string buf;
    int written = 0;
    int err = 0;
    string_view msg;

    if (m("dispatch", extract(buf))) {
      if (not dispatch(buf))
        close_on_write_complete = true;
      return ok();
    }
    if (m("socket", tag, "read_complete", extract(buf))) {
      if (buf.empty()) {
        s.close();
        return ok();
      }
      buf.swap(prev_buf);
      buf.append(prev_buf);
      string::size_type pos{};
      while (not buf.empty() and pos != string::npos) {
        pos = buf.find_first_of('\n');
        if (pos != string::npos) {
          auto ret = self().send("dispatch", string(buf.data(), pos));
          if (not ret)
            return ret;
          buf.erase(0, pos + 1);
        }
      }
      prev_buf = buf;
      s.read();
      return ok();
    }
    if (m("socket", tag, "write_complete", extract(written))) {
      if (close_on_write_complete)
        s.close();
      return ok();
    }
    if (m("socket", tag, "closed")) {
      return exit("closed");
    }
    if (m("socket", tag, "read_error", extract(err), extract(msg))) {
      return exit("read_error", msg);
    }
    if (m("socket", tag, "write_error", extract(err), extract(msg))) {
      return exit("write_error", msg);
    }
    string name;
    if (auto p = handle_ref(from).lock())
      name = p->name();
    else
      name = "expired";
    s.write(name);
    s.write(" ");
    s.write(m.to_json());
    s.write("\n");
    return ok();
  }

  static auto start(context_impl &ctx, int fd, const string &prompt)
      -> expected<handle, error> {
    return spawn(
        [&ctx, fd, prompt]() {
          ::thespian::receive(
              [p{make_shared<connection>(ctx, fd, prompt)}](auto from, auto m) {
                return p->receive(move(from), move(m));
              });
          return ok();
        },
        tag);
  }
};

struct acceptor {
  static constexpr string_view tag{"debug_acceptor_tcp"};
  acceptor(const acceptor &) = delete;
  acceptor(acceptor &&) = delete;
  auto operator=(const acceptor &) -> acceptor & = delete;
  auto operator=(acceptor &&) -> acceptor & = delete;

  context_impl &ctx;
  ::thespian::tcp::acceptor a;
  handle s;
  string prompt;

  acceptor(context_impl &ctx, port_t port, string _prompt)
      : ctx{ctx}, a{::thespian::tcp::acceptor::create(tag)},
        prompt(move(_prompt)) {
    a.listen(in6addr_loopback, port);
  }
  ~acceptor() = default;

  auto receive(const handle &from, const buffer &m) -> result {
    int fd{};
    string err;

    if (m("acceptor", tag, "accept", extract(fd))) {
      auto ret = connection::start(ctx, fd, prompt);
      if (ret)
        s = ret.value();
      else
        return to_error(ret.error());
    } else if (m("socket", connection::tag, "closed")) {
      ;
    } else if (m("acceptor", tag, "closed")) {
      return exit("closed");
    } else if (m("acceptor", tag, "error", extract(err))) {
      return exit(err);
    } else if (m("ping")) {
      return from.send("pong");
    } else {
      a.close();
    }
    return ok();
  }

  static auto start(context_impl &ctx, port_t port, const string &prompt)
      -> expected<handle, error> {
    return spawn(
        [&ctx, port, prompt]() {
          ::thespian::receive(
              [p{make_shared<acceptor>(ctx, port, prompt)}](auto from, auto m) {
                return p->receive(move(from), move(m));
              });
          return ok();
        },
        tag);
  }
};

auto create(context &ctx, port_t port, const string &prompt)
    -> expected<handle, error> {
  return acceptor::start(impl(ctx), port, prompt);
}

} // namespace tcp
} // namespace debug
} // namespace thespian
