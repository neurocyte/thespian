#pragma once

#include <functional>
#include <ostream>
#include <string>
#include <string_view>
#include <vector>

namespace cbor {

constexpr auto buffer_reserve = 128;

constexpr auto cbor_magic_null = 0xf6;
constexpr auto cbor_magic_true = 0xf5;
constexpr auto cbor_magic_false = 0xf4;

constexpr auto cbor_magic_type_array = 4;
constexpr auto cbor_magic_type_map = 5;

enum class type : uint8_t {
  number,
  bytes,
  string,
  array,
  map,
  tag,
  boolean,
  null,
  any,
  more,
  unknown,
};
const auto any = type::any;
const auto more = type::more;

template <typename T> inline auto is_more(const T & /*unused*/) -> bool {
  return false;
}
template <> inline auto is_more<type>(const type &t) -> bool {
  return t == type::more;
}

using buffer_base = std::vector<uint8_t>;

class buffer : public buffer_base {
private:
  using iter = const_iterator;

public:
  using extractor = std::function<bool(iter &, const iter &)>;

private:
  static auto decode_range_header(iter &, const iter &) -> size_t;
  static auto decode_array_header(iter &, const iter &) -> size_t;
  static auto decode_map_header(iter &, const iter &) -> size_t;

  // clang-format off
  [[nodiscard]] static auto match_value(iter &, const iter &, const extractor &) -> bool;
  [[nodiscard]] static auto match_value(iter &, const iter &, type) -> bool;
  [[nodiscard]] static auto match_value(iter &, const iter &, signed long long int) -> bool;
  [[nodiscard]] static auto match_value(iter &, const iter &, unsigned long long int) -> bool;
  [[nodiscard]] static auto match_value(iter &, const iter &, bool) -> bool;
  [[nodiscard]] static auto match_value(iter &, const iter &, const std::string &) -> bool;
  [[nodiscard]] static auto match_value(iter &, const iter &, const std::string_view) -> bool;
  [[nodiscard]] static auto match_value(iter &b, const iter &e, const char *s) -> bool {
    return match_value(b, e, std::string(s));
  }

  [[nodiscard]] static auto match_value(iter &b, const iter &e, unsigned long int v) -> bool { return match_value(b, e, static_cast<unsigned long long int>(v)); }
  [[nodiscard]] static auto match_value(iter &b, const iter &e, unsigned int v) -> bool { return match_value(b, e, static_cast<unsigned long long int>(v)); }
  [[nodiscard]] static auto match_value(iter &b, const iter &e, unsigned short int v) -> bool { return match_value(b, e, static_cast<unsigned long long int>(v)); }
  [[nodiscard]] static auto match_value(iter &b, const iter &e, unsigned char v) -> bool { return match_value(b, e, static_cast<unsigned long long int>(v)); }
  [[nodiscard]] static auto match_value(iter &b, const iter &e, signed long int v) -> bool { return match_value(b, e, static_cast<signed long long int>(v)); }
  [[nodiscard]] static auto match_value(iter &b, const iter &e, signed int v) -> bool { return match_value(b, e, static_cast<signed long long int>(v)); }
  [[nodiscard]] static auto match_value(iter &b, const iter &e, signed short int v) -> bool { return match_value(b, e, static_cast<signed long long int>(v)); }
  [[nodiscard]] static auto match_value(iter &b, const iter &e, signed char v) -> bool { return match_value(b, e, static_cast<signed long long int>(v)); }
  // clang-format on

  template <typename T>
  [[nodiscard]] static auto match_next(size_t n, iter &b, const iter &e, T &&p)
      -> bool {
    if (is_more(p)) {
      while (n) {
        if (!match_value(b, e, any))
          return false;
        --n;
      }
      return true;
    }
    if (!n)
      return false;
    if (!match_value(b, e, p))
      return false;
    return n == 1;
  }

  template <typename T, typename... Ts>
  [[nodiscard]] static auto match_next(size_t n, iter &b, const iter &e, T &&p,
                                       Ts &&...parms) -> bool {
    if (!n)
      return false;
    if (!match_value(b, e, p))
      return false;
    return match_next(--n, b, e, std::forward<Ts>(parms)...);
  }

  auto push_typed_val(int type, uint64_t value) -> void;

  auto push_parms() -> buffer & { return *this; }
  template <typename T, typename... Ts>
  auto push_parms(const T &p, Ts &&...parms) -> buffer & {
    push(p);
    return push_parms(std::forward<Ts>(parms)...);
  }

  template <typename... Ts>
  [[nodiscard]] static auto match_array(iter &b, const iter &e, Ts &&...parms)
      -> bool {
    auto n = decode_array_header(b, e);
    return match_next(n, b, e, std::forward<Ts>(parms)...);
  }

  template <typename... Ts>
  [[nodiscard]] static auto match_map(iter &b, const iter &e, Ts &&...parms)
      -> bool {
    auto n = decode_map_header(b, e);
    n *= 2;
    return match_next(n, b, e, std::forward<Ts>(parms)...);
  }

public:
  using buffer_base::buffer_base;
  auto operator[](size_t) -> value_type & = delete;

  static const buffer null_value;

  [[nodiscard]] auto raw_cbegin() const -> iter {
    return buffer_base::cbegin();
  }
  [[nodiscard]] auto raw_cend() const -> iter { return buffer_base::cend(); }

  template <typename... Ts>
  [[nodiscard]] auto operator()(Ts &&...parms) const -> bool {
    auto b = raw_cbegin();
    auto e = raw_cend();
    return match_array(b, e, std::forward<Ts>(parms)...);
  }

  [[nodiscard]] auto is_null() const -> bool { return *this == null_value; }

  auto push_null() -> buffer & {
    push_back(cbor_magic_null);
    return *this;
  }

  auto push_bool(bool v) -> buffer & {
    if (v)
      push_back(cbor_magic_true);
    else
      push_back(cbor_magic_false);
    return *this;
  }

  auto push_string(const std::string &) -> buffer &;
  auto push_string(const std::string_view &s) -> buffer &;

  auto push_int(signed long long int value) -> buffer & {
    if (value < 0) {
      push_typed_val(1, -(value + 1));
    } else {
      push_typed_val(0, value);
    }
    return *this;
  }

  auto push_uint(unsigned long long int value) -> buffer & {
    push_typed_val(0, value);
    return *this;
  }

  // clang-format off
  auto push(const unsigned long long int &i) -> buffer & { return push_uint(i); }
  auto push(const unsigned long int &i) -> buffer & { return push_uint(i); }
  auto push(const unsigned int &i) -> buffer & { return push_uint(i); }
  auto push(const unsigned short int &i) -> buffer & { return push_uint(i); }
  auto push(const unsigned char &i) -> buffer & { return push_uint(i); }
  auto push(const signed long long int &i) -> buffer & { return push_int(i); }
  auto push(const signed long int &i) -> buffer & { return push_int(i); }
  auto push(const signed int &i) -> buffer & { return push_int(i); }
  auto push(const signed short int &i) -> buffer & { return push_int(i); }
  auto push(const signed char &i) -> buffer & { return push_int(i); }
  auto push(const bool &v) -> buffer & { return push_bool(v); }
  auto push(const std::string &s) -> buffer & { return push_string(s); }
  auto push(const std::string_view &s) -> buffer & { return push_string(s); }
  auto push(char *s) -> buffer & { return push_string(std::string_view(s)); }
  auto push(const char *s) -> buffer & { return push_string(std::string_view(s)); }
  // clang-format on

  template <typename T> auto push(const T &a) -> buffer & {
    a.to_cbor(*this);
    return *this;
  }

  auto array_header(size_t sz) -> buffer & {
    push_typed_val(cbor_magic_type_array, sz);
    return *this;
  }

  auto map_header(size_t sz) -> buffer & {
    push_typed_val(cbor_magic_type_map, sz);
    return *this;
  }

  template <typename T> auto push_array(const T &a) -> buffer & {
    if (a.empty())
      push_null();
    else {
      array_header(a.size());
      for (auto v : a)
        push(v);
    }
    return *this;
  }

  auto push_json(const std::string &) -> void;

  auto array() -> buffer & { return push_null(); }

  template <typename... Ts> auto array(Ts &&...parms) -> buffer & {
    array_header(sizeof...(parms));
    return push_parms(std::forward<Ts>(parms)...);
  }

  auto map() -> buffer & { return push_null(); }

  template <typename... Ts> auto map(Ts &&...parms) -> buffer & {
    constexpr size_t sz = sizeof...(parms);
    static_assert(sz % 2 == 0,
                  "cbor maps must contain an even number of values");
    map_header(sz / 2);
    return push_parms(std::forward<Ts>(parms)...);
  }

  auto to_cbor(buffer &b) const -> buffer & {
    b.insert(b.raw_cend(), raw_cbegin(), raw_cend());
    return b;
  }

  [[nodiscard]] auto to_json() const -> std::string;
  auto to_json(std::ostream &) const -> void;
  [[nodiscard]] auto hexdump() const -> std::string;

  class range;

  struct value_accessor {
    iter b;
    iter e;

    [[nodiscard]] auto type_() const -> type;

    operator type() const;                   // NOLINT
    operator unsigned long long int() const; // NOLINT
    operator unsigned long int() const;      // NOLINT
    operator unsigned int() const;           // NOLINT
    operator unsigned short int() const;     // NOLINT
    operator unsigned char() const;          // NOLINT
    operator signed long long int() const;   // NOLINT
    operator signed long int() const;        // NOLINT
    operator signed int() const;             // NOLINT
    operator signed short int() const;       // NOLINT
    operator signed char() const;            // NOLINT
    operator bool() const;                   // NOLINT
    operator std::string_view() const;       // NOLINT
    operator buffer::range() const;          // NOLINT

    struct unvisitable_type {
      cbor::type t;
    };

    template <typename F> auto visit(F f) const -> decltype(f(true)) {
      type t{type_()};
      switch (t) {
      case type::string:
        return f(static_cast<std::string_view>(*this));
      case type::number:
        return f(static_cast<int64_t>(*this));
      case type::boolean:
        return f(static_cast<bool>(*this));
      case type::array:
      case type::map:
        return f(static_cast<range>(*this));
      case type::null:
      case type::bytes:
      case type::tag:
      case type::any:
      case type::more:
      case type::unknown:
        return f(unvisitable_type{t});
      }
      return f(unvisitable_type{t});
    }

    auto to_cbor(buffer &buf) const -> buffer & {
      buf.insert(buf.raw_cend(), b, e);
      return buf;
    }
  };

  auto push(const value_accessor::unvisitable_type & /*unused*/) -> buffer & {
    return push("cbor::value_accessor::unvisitable_type");
  }

  struct value_iterator {
    iter b;
    iter e;
    size_t n = 0;

    auto operator!=(const value_iterator &other) const -> bool {
      return b != other.b;
    }
    auto operator++() -> void {
      if (n) {
        --n;
        [[maybe_unused]] bool _ = match_value(b, e, type::any);
      }
    }
    auto operator*() -> value_accessor {
      if (n)
        return {.b = b, .e = e};
      throw std::out_of_range("cbor iterator out of range");
    }
  };

  [[nodiscard]] auto cbegin() const -> value_iterator = delete;
  [[nodiscard]] auto cend() const -> value_iterator = delete;
  [[nodiscard]] auto begin() const -> value_iterator {
    auto b = raw_cbegin();
    auto e = raw_cend();
    auto n = decode_range_header(b, e);
    return {.b = b, .e = e, .n = n};
  }
  [[nodiscard]] auto end() const -> value_iterator {
    return {.b = raw_cend(), .e = raw_cend()};
  }

  class range {
    iter b_;
    iter e_;
    friend auto extract(range &) -> extractor;
    [[nodiscard]] auto raw_cbegin() const -> iter { return b_; }
    [[nodiscard]] auto raw_cend() const -> iter { return e_; }

  public:
    [[nodiscard]] auto begin() const -> value_iterator {
      auto b = raw_cbegin();
      auto e = raw_cend();
      auto n = decode_range_header(b, e);
      return {.b = b, .e = e, .n = n};
    }
    [[nodiscard]] auto end() const -> value_iterator {
      return {.b = raw_cend(), .e = raw_cend()};
    }

    auto is_null() -> bool {
      auto b = raw_cbegin();
      return decode_range_header(b, raw_cend()) == 0;
    }

    template <typename... Ts>
    [[nodiscard]] auto operator()(Ts &&...parms) const -> bool {
      auto b = raw_cbegin();
      return match_array(b, raw_cend(), std::forward<Ts>(parms)...);
    }
    [[nodiscard]] auto to_json() const -> std::string;
    auto to_json(std::ostream &) const -> void;
    auto to_cbor(buffer &b) const -> buffer & {
      b.insert(b.raw_cend(), raw_cbegin(), raw_cend());
      return b;
    }
    auto operator==(const range &b) const -> bool {
      using std::equal;
      return equal(b.raw_cbegin(), b.raw_cend(), raw_cbegin(), raw_cend());
    }
  };
  friend class range;
  friend struct value_accessor;
  friend auto extract(range &) -> extractor;
  template <typename... Ts> friend auto A(Ts &&...parms) -> buffer::extractor;
  template <typename... Ts> friend auto M(Ts &&...parms) -> buffer::extractor;
};

template <typename... Ts> auto array(Ts &&...parms) -> buffer {
  buffer b;
  b.reserve(buffer_reserve);
  b.array(std::forward<Ts>(parms)...);
  return b;
}

template <typename... Ts> auto map(Ts &&...parms) -> buffer {
  buffer b;
  b.reserve(buffer_reserve);
  b.map(std::forward<Ts>(parms)...);
  return b;
}

auto extract(type &) -> buffer::extractor;

auto extract(signed long long int &) -> buffer::extractor;
auto extract(signed long int &) -> buffer::extractor;
auto extract(signed int &) -> buffer::extractor;
auto extract(signed short int &) -> buffer::extractor;
auto extract(signed char &) -> buffer::extractor;

auto extract(unsigned long long int &) -> buffer::extractor;
auto extract(unsigned long int &) -> buffer::extractor;
auto extract(unsigned int &) -> buffer::extractor;
auto extract(unsigned short int &) -> buffer::extractor;
auto extract(unsigned char &) -> buffer::extractor;

auto extract(bool &) -> buffer::extractor;
auto extract(std::string &) -> buffer::extractor;
auto extract(std::string_view &) -> buffer::extractor;
auto extract(buffer::range &) -> buffer::extractor;

template <typename... Ts> auto A(Ts &&...parms) -> buffer::extractor {
  return [=](buffer::iter &b, const buffer::iter &e) mutable {
    return buffer::match_array(b, e, std::forward<Ts>(parms)...);
  };
}

template <typename... Ts> auto M(Ts &&...parms) -> buffer::extractor {
  return [=](buffer::iter &b, const buffer::iter &e) mutable {
    return buffer::match_map(b, e, std::forward<Ts>(parms)...);
  };
}

inline auto operator<<(std::ostream &s, const buffer &b) -> std::ostream & {
  b.to_json(s);
  return s;
}

inline auto operator<<(std::ostream &s, const buffer::range &b)
    -> std::ostream & {
  b.to_json(s);
  return s;
}

} // namespace cbor
