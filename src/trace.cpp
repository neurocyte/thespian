#include <thespian/trace.hpp>

#include <atomic>
#include <fstream>
#include <memory>
#include <mutex>
#include <sstream>

using cbor::any;
using cbor::array;
using cbor::buffer;
using cbor::extract;
using cbor::more;
using std::atomic;
using std::fstream;
using std::ios_base;
using std::lock_guard;
using std::make_shared;
using std::ostream;
using std::recursive_mutex;
using std::string;
using std::string_view;
using std::stringstream;

namespace thespian {
constexpr auto trace_file_flags =
    ios_base::binary | ios_base::out | ios_base::ate;
const auto trace_buf_size = 64U * 1024U;

template <typename T, typename Q> struct trace_file {
  trace_file(const trace_file &) = delete;
  trace_file(const trace_file &&) = delete;
  auto operator=(const trace_file &) -> trace_file & = delete;
  auto operator=(trace_file &&) -> trace_file & = delete;

  struct node {
    Q data{};
    node *next{};
  };
  atomic<node *> head{nullptr};
  recursive_mutex m;
  fstream s;
  char buf[trace_buf_size]{}; // NOLINT

  explicit trace_file(const string &file_name)
      : s(file_name, trace_file_flags) {
    s.rdbuf()->pubsetbuf(buf, trace_buf_size);
  }
  ~trace_file() {
    while (do_work())
      ;
  }

  auto reverse(node *p) -> node * {
    node *prev{nullptr};
    node *next{nullptr};
    while (p) {
      next = p->next;
      p->next = prev;
      prev = p;
      p = next;
    }
    return prev;
  }
  auto push(Q data) -> void {
    auto p = new node{move(data), head};
    while (!head.compare_exchange_weak(p->next, p))
      ;
    while (do_work())
      ;
  }
  auto do_work() -> bool {
    if (!m.try_lock())
      return false;
    lock_guard<recursive_mutex> lock(m);
    m.unlock();
    auto p = head.load();
    while (p && !head.compare_exchange_weak(p, nullptr)) {
      ;
    }
    if (!p)
      return false;
    p = reverse(p);
    while (p) {
      static_cast<T *>(this)->on_trace(move(p->data));
      auto p_ = p;
      p = p->next;
      delete p_;
    }
    return true;
  }
};

auto to_mermaid(ostream &s, const buffer &m) -> void {
  string_view from;
  string_view typ;
  if (not m(A(any, any, extract(from)), extract(typ), more))
    return;
  if (from.empty())
    from = "UNKNOWN";
  if (typ == "spawn") {
    s << "    Note right of " << from << ": SPAWN\n";
  } else if (typ == "receive") {
    // ignore
  } else if (typ == "run") {
    s << "    activate " << from << '\n';
  } else if (typ == "sleep") {
    s << "    deactivate " << from << '\n';
  } else if (typ == "send") {
    string_view to;
    buffer::range msg;
    if (m(any, any, A(any, any, extract(to)), extract(msg))) {
      s << "    " << from << "->>" << to << ": send ";
      msg.to_json(s);
      s << '\n';
    }
  } else if (typ == "link") {
    string_view to;
    if (m(any, any, A(any, any, extract(to))))
      s << "    " << from << "-->>" << to << ": create link\n";
  } else if (typ == "exit") {
    string_view msg;
    if (m(any, any, A(any, extract(msg), more)))
      s << "    Note right of " << from << ": EXIT " << msg << '\n';
  }
}

static const auto cbor_cr = array("\n");

auto trace_to_cbor_file(const string &file_name) -> void {
  struct cbor_file : trace_file<cbor_file, buffer> {
    using trace_file::trace_file;
    auto on_trace(const buffer &msg) -> void {
      s.write(reinterpret_cast<const char *>(msg.data()), msg.size()); // NOLINT
      s.write(reinterpret_cast<const char *>(cbor_cr.data()),          // NOLINT
              cbor_cr.size());                                         // NOLINT
    }
  };
  auto f = make_shared<cbor_file>(file_name);
  on_trace([f](auto m) { f->push(move(m)); });
}

auto trace_to_json_file(const string &file_name) -> void {
  struct json_file : trace_file<json_file, buffer> {
    using trace_file::trace_file;
    auto on_trace(const buffer &msg) -> void {
      msg.to_json(s);
      s << '\n';
    }
  };
  auto f = make_shared<json_file>(file_name);
  on_trace([f](auto m) { f->push(move(m)); });
}

auto trace_to_mermaid_file(const string &file_name) -> void {
  struct mermaid_file : trace_file<mermaid_file, buffer> {
    explicit mermaid_file(const string &_file_name) : trace_file(_file_name) {
      s << "sequenceDiagram\n";
    }
    auto on_trace(const buffer &msg) -> void { to_mermaid(s, msg); }
  };
  auto f = make_shared<mermaid_file>(file_name);
  on_trace([f](auto m) { f->push(move(m)); });
}

} // namespace thespian
