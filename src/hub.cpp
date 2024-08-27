#include <thespian/debug.hpp>
#include <thespian/endpoint.hpp>
#include <thespian/hub.hpp>
#include <thespian/instance.hpp>

#include <deque>
#include <mutex>
#include <set>
#include <vector>

using cbor::buffer;
using cbor::extract;
using cbor::more;
using cbor::type;
using std::deque;
using std::lock_guard;
using std::make_shared;
using std::move;
using std::mutex;
using std::pair;
using std::set;
using std::shared_ptr;
using std::string;
using std::string_view;
using std::vector;

namespace thespian {

using filter = hub::filter;

hub::pipe::pipe() = default;
hub::pipe::~pipe() = default;

struct subscribe_queue : public hub::pipe {
  [[nodiscard]] auto push(const handle &from, filter f) {
    const lock_guard<mutex> lock(m_);
    q_.push_back(move(f));
    return from.send("subscribe_filtered");
  }
  auto pop() -> filter {
    const lock_guard<mutex> lock(m_);
    filter f = move(q_.front());
    q_.pop_front();
    return f;
  }

private:
  deque<filter> q_;
  mutex m_;
};

struct hub_impl {
  hub_impl(const hub_impl &) = delete;
  hub_impl(hub_impl &&) = delete;
  auto operator=(const hub_impl &) -> hub_impl & = delete;
  auto operator=(hub_impl &&) -> hub_impl & = delete;

  explicit hub_impl(shared_ptr<subscribe_queue> q) : q_(move(q)) {}
  ~hub_impl() = default;

  auto receive(handle from, buffer msg) {
    if (msg("broadcast", type::array)) {
      msg.erase(msg.raw_cbegin(), msg.raw_cbegin() + 11);
      for (auto const &s : subscribers_) {
        result ret = ok();
        if (s.second) {
          if (s.second(msg)) {
            ret = s.first.send_raw(msg);
          }
        } else {
          ret = s.first.send_raw(msg);
        }
        // if (not ret)
        //   FIXME: remove dead subscriptions from subscribers_
      }
      return ok();
    }

    if (msg("subscribe")) {
      subscribers_.emplace_back(move(from), filter{});
      return ok();
    }

    if (msg("subscribe_filtered")) {
      subscribers_.emplace_back(move(from), q_->pop());
      return ok();
    }

    buffer::range r;
    if (msg("subscribe_messages", extract(r))) {
      set<string> msgs;
      for (const auto val : r)
        msgs.insert(string(val));
      subscribers_.emplace_back(move(from), [msgs](auto m) {
        string tag;
        return m(extract(tag), more) && (msgs.find(tag) != msgs.end());
      });
      return ok();
    }

    string_view desc;
    if (msg("listen", extract(desc))) {
#if !defined(_WIN32)
      thespian::endpoint::unx::listen(desc);
#endif
    }

    if (msg("shutdown"))
      return exit("shutdown");

    return unexpected(msg);
  }

  using subscriber_list_t = vector<pair<handle, filter>>;
  subscriber_list_t subscribers_;
  shared_ptr<subscribe_queue> q_;
};

hub::hub(const handle &h, shared_ptr<pipe> p) : handle(h), pipe_(move(p)) {}

auto hub::subscribe() const -> result {
  link(*this);
  return send("subscribe");
}

auto hub::subscribe(filter f) const -> result {
  link(*this);
  return dynamic_cast<subscribe_queue &>(*pipe_).push(
      static_cast<const handle &>(*this), move(f));
}

auto hub::listen(string_view desc) const -> result {
  return send("listen", desc);
}

auto hub::create(string_view name) -> expected<hub, error> {
  auto q = make_shared<subscribe_queue>();
  auto ret = spawn_link(
      [=]() {
        receive([p{make_shared<hub_impl>(q)}](auto from, auto m) {
          return p->receive(move(from), move(m));
        });
        return ok();
      },
      name);
  if (not ret)
    return to_error(ret.error());
  return hub{ret.value(), q};
}

auto operator==(const handle &a, const hub &b) -> bool {
  return a == static_cast<const handle &>(b);
}

auto operator==(const hub &a, const handle &b) -> bool {
  return static_cast<const handle &>(a) == b;
}

} // namespace thespian
