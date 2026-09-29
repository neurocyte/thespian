#include "tests.hpp"

#include <thespian/debug.hpp>
#include <thespian/instance.hpp>
#include <thespian/socket.hpp>
#include <thespian/timeout.hpp>
#include <thespian/unx.hpp>

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <filesystem>
#include <memory>
#include <string>

#if !defined(_WIN32)
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>
#else
#include <winsock2.h>
#include <afunix.h>
#include <process.h>
#include <windows.h>
#endif

using cbor::buffer;
using cbor::extract;
using std::make_shared;
using std::make_unique;
using std::move;
using std::string;
using std::string_view;
using std::unique_ptr;
using thespian::context;
using thespian::create_timeout;
using thespian::env;
using thespian::env_t;
using thespian::error;
using thespian::exit;
using thespian::expected;
using thespian::handle;
using thespian::link;
using thespian::ok;
using thespian::receive;
using thespian::result;
using thespian::spawn_link;
using thespian::timeout;
using thespian::trap;
using thespian::unexpected;
using thespian::unx::connector;
using thespian::unx::mode;

namespace {

const string call_request{
    R"({"id":1,"cmd":"call","to":"debuggee","msg":["ping"]})"};
const string call_response{
    R"({"id":1,"ok":true,"from":"debuggee","result":["pong"]})"};
const string bye_request{R"({"id":2,"cmd":"bye"})"};
const string bye_response{R"({"id":2,"ok":true})"};

// std::filesystem cannot stat or remove AF_UNIX socket files on windows
#if !defined(_WIN32)
auto process_id() -> int { return ::getpid(); }
using native_socket = int;
void close_socket(native_socket fd) { ::close(fd); }
constexpr native_socket invalid_socket{-1};
void remove_file(const string &path) { ::unlink(path.c_str()); }
auto file_exists(const string &path) -> bool {
  struct stat st{};
  return ::lstat(path.c_str(), &st) == 0;
}

// the console restricts its socket file to the owner
auto socket_ok(const string &path) -> bool {
  struct stat st{};
  return ::lstat(path.c_str(), &st) == 0 and S_ISSOCK(st.st_mode) and
         (st.st_mode & 0777) == 0600;
}
#else
auto process_id() -> int { return ::_getpid(); }
using native_socket = SOCKET;
void close_socket(native_socket fd) { ::closesocket(fd); }
const native_socket invalid_socket{INVALID_SOCKET};

void remove_file(const string &path) { ::DeleteFileA(path.c_str()); }
auto file_exists(const string &path) -> bool {
  return ::GetFileAttributesA(path.c_str()) != INVALID_FILE_ATTRIBUTES;
}

// windows socket files are governed by the ACLs of their directory
auto socket_ok(const string &path) -> bool { return file_exists(path); }
#endif

auto socket_path() -> string {
  return (std::filesystem::temp_directory_path() /
          ("thespian_debug_unx_test_" + std::to_string(process_id()) +
           ".sock"))
      .string();
}

// leaves a socket file behind with nothing listening on it, like a crashed
// previous run would
auto make_stale_socket(const string &path) -> bool {
  remove_file(path);
  sockaddr_un addr{};
  addr.sun_family = AF_UNIX;
  std::copy(path.begin(), path.end(), addr.sun_path); // NOLINT
  const native_socket fd = ::socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd == invalid_socket)
    return false;
  const bool bound = ::bind(fd, reinterpret_cast<sockaddr *>(&addr), // NOLINT
                            sizeof(addr)) == 0;
  close_socket(fd);
  return bound;
}

struct debuggee {
  static auto start() -> expected<handle, error> {
    return spawn_link(
        []() {
          receive([](const handle &from, const buffer &m) -> result {
            if (m("ping"))
              return from.send("pong");
            return unexpected(m);
          });
          return ok();
        },
        "debuggee");
  }
};

struct controller {
  static constexpr string_view tag{"debug_unx_test_client"};
  context &ctx;
  string path;
  handle console;
  handle debuggee_;
  connector c{connector::create(tag)};
  unique_ptr<thespian::socket> s;
  string lines;
  bool got_bye{false};
  timeout t{thespian::never()};
  int removal_checks{0};

  controller(context &ctx, string path, handle console, handle debuggee)
      : ctx{ctx}, path{move(path)}, console{move(console)},
        debuggee_{move(debuggee)} {}

  auto on_line(const string &line) -> result {
    if (line == call_response) {
      s->write(bye_request + "\n");
      return ok();
    }
    if (line == bye_response) {
      got_bye = true;
      return ok();
    }
    return exit("unexpected_line: " + line);
  }

  auto receive(const handle & /*from*/, const buffer &m) -> result {
    int fd{};
    string buf;
    string err;
    int code{};
    int written{};

    if (m("pong")) {
      if (not socket_ok(path))
        return exit("bad_socket_file");
      // a second console must not take over the path of a live one
      auto ret = thespian::debug::unx::create(ctx, path, mode::file, "");
      if (not ret)
        return to_result(ret);
      link(ret.value());
      return ok();
    }
    if (m("exit", "listen_error", extract(err))) {
      if (not socket_ok(path))
        return exit("live_socket_removed");
      c.connect(path, mode::file);
    } else if (m("connector", tag, "connected", extract(fd))) {
      s = make_unique<thespian::socket>(thespian::socket::create(tag, fd));
      s->read();
      s->write(call_request + "\n");
    } else if (m("connector", tag, "error", extract(code), extract(err))) {
      return exit("connect_error: " + err);
    } else if (m("socket", tag, "read_complete", extract(buf))) {
      if (buf.empty()) {
        s->close();
        return ok();
      }
      s->read();
      lines.append(buf);
      string::size_type pos{};
      while ((pos = lines.find('\n')) != string::npos) {
        auto ret = on_line(lines.substr(0, pos));
        if (not ret)
          return ret;
        lines.erase(0, pos + 1);
      }
    } else if (m("socket", tag, "write_complete", extract(written))) {
      ;
    } else if (m("socket", tag, "closed")) {
      if (not got_bye)
        return exit("closed_early");
      return console.send("shutdown");
    } else if (m("exit", "closed")) {
      return check_removed();
    } else if (m("check_removed")) {
      return check_removed();
    } else {
      return unexpected(m);
    }
    return ok();
  }

  // the console removes its socket file as its state is destroyed, which
  // races with its exit notification
  auto check_removed() -> result {
    if (not file_exists(path)) {
      thespian::debug::disable(ctx);
      return exit("success");
    }
    if (++removal_checks > 100)
      return exit("socket_not_removed");
    t = create_timeout(std::chrono::milliseconds(10),
                       cbor::array("check_removed"));
    return ok();
  }
};

} // namespace

auto debug_unx(context &ctx, bool &result, env_t env_) -> ::result {
  thespian::debug::enable(ctx);
  return to_result(ctx.spawn_link(
      [&ctx]() {
        trap(true);
        link(env().proc("log"));
        auto path = socket_path();
        if (not make_stale_socket(path))
          return exit("make_stale_socket_failed");
        auto ret = thespian::debug::unx::create(ctx, path, mode::file, "");
        if (not ret)
          return to_result(ret);
        auto console = ret.value();
        link(console);
        ret = debuggee::start();
        if (not ret)
          return to_result(ret);
        auto p = make_shared<controller>(ctx, path, console, ret.value());
        auto sret = console.send("ping");
        if (not sret)
          return sret;
        receive([p](const auto &from, const auto &m) {
          return p->receive(from, m);
        });
        return ok();
      },
      [&](auto s) {
        if (s == "success")
          result = true;
        else
          fprintf(stderr, "debug_unx: %.*s\n", static_cast<int>(s.size()),
                  s.data());
      },
      "debug_unx", move(env_)));
}

