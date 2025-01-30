#include <cbor/c/cbor.h>
#include <cbor/cbor.hpp>

#include <array>
#include <iomanip>
#include <limits>
#include <sstream>
#include <string>
#include <string_view>
#include <tuple>

using std::back_inserter;
using std::copy;
using std::domain_error;
using std::hex;
using std::make_tuple;
using std::numeric_limits;
using std::ostream;
using std::setfill;
using std::setw;
using std::string;
using std::string_view;
using std::stringstream;
using std::tuple;

namespace cbor {

const buffer buffer::null_value = buffer{0xF6};

auto buffer::push_typed_val(int type, uint64_t value) -> void {
  type <<= 5;
  if (value < 24ULL) {
    push_back(type | value);
  } else if (value < 256ULL) {
    push_back(type | 24);
    push_back(value);
  } else if (value < 65536ULL) {
    push_back(type | 25);
    push_back(value >> 8);
    push_back(value);
  } else if (value < 4294967296ULL) {
    push_back(type | 26);
    push_back(value >> 24);
    push_back(value >> 16);
    push_back(value >> 8);
    push_back(value);
  } else {
    push_back(type | 27);
    push_back(value >> 56);
    push_back(value >> 48);
    push_back(value >> 40);
    push_back(value >> 32);
    push_back(value >> 24);
    push_back(value >> 16);
    push_back(value >> 8);
    push_back(value);
  }
}

auto buffer::push_string(const string &s) -> buffer & {
  push_typed_val(3, s.size());
  copy(s.begin(), s.end(), back_inserter(*this));
  return *this;
}

auto buffer::push_string(const string_view &s) -> buffer & {
  push_typed_val(3, s.size());
  copy(s.begin(), s.end(), back_inserter(*this));
  return *this;
}

using json_iter = string::const_iterator;

namespace {
static auto match_wsp_char(json_iter &b, const json_iter &e) -> bool {
  if (b == e)
    return false;
  char c = *b;
  switch (c) {
  case ' ':
  case '\t':
  case '\r':
  case '\n':
    ++b;
    return true;
  default:
    return false;
  }
}

static auto skip_wsp(json_iter &b, const json_iter &e) -> void {
  while (match_wsp_char(b, e))
    ;
}

static auto match_char(int c, json_iter &b, const json_iter &e) -> bool {
  if (b == e || *b != c)
    return false;
  ++b;
  return true;
}

// NOLINTBEGIN(*-pointer-arithmetic)
static auto match_literal(const char *str, json_iter &b, const json_iter &e)
    -> bool {
  json_iter i = b;
  while (*str && match_char(*str, i, e))
    ++str;
  if (!*str) {
    b = i;
    return true;
  }
  return false;
}

constexpr auto int_str_max = 3 * sizeof(uint64_t) + 1;

static auto push_json_number(buffer &buf, json_iter &b, const json_iter &e)
    -> bool {
  const bool neg = match_char('-', b, e);
  std::array<char, int_str_max> s{};
  char *p = s.data();
  char *se = s.data() + int_str_max;
  if (b == e)
    return false;
  char c = *b;
  if (c >= '0' && c <= '9') {
    ++b;
    *p = c;
    ++p;
    if (p == se)
      return false;
  } else
    return false;
  while (true) {
    if (b == e)
      break;
    c = *b;
    if (c >= '0' && c <= '9') {
      ++b;
      *p = c;
      ++p;
      if (p == se)
        return false;
    } else {
      break;
    }
  }
  *p = 0;
  char *ep = s.data();
  int64_t i = strtoll(s.data(), &ep, 10);
  if (ep != p)
    return false;
  if (neg)
    i = -i;
  buf.push_int(i);
  return true;
}
// NOLINTEND(*-pointer-arithmetic)

static auto push_json_qstring_slow(buffer &buf, json_iter &b,
                                   const json_iter &e) -> bool {
  if (!match_char('"', b, e))
    return false;
  string s;
  while (true) {
    if (b == e)
      return false;
    char c = *b;
    ++b;
    if (c == '\\') {
      if (b == e)
        return false;
      c = *b;
      ++b;
      switch (c) {
      case 'b':
        c = '\b';
        break;
      case 'f':
        c = '\f';
        break;
      case 'n':
        c = '\n';
        break;
      case 'r':
        c = '\r';
        break;
      case 't':
        c = '\t';
        break;
      case '\\':
        c = '\\';
        break;
      default:
        break;
      }
    } else if (c == '"') {
      buf.push_string(s);
      return true;
    }
    s.push_back(c);
  }
}

static auto scan_json_qstring(json_iter &b, json_iter &e, bool &is_escaped)
    -> bool {
  if (!match_char('"', b, e))
    return false;
  json_iter i = b;
  is_escaped = false;
  while (true) {
    if (i == e)
      return false;
    char c = *i;
    if (c == '\\') {
      is_escaped = true;
      return true;
    }
    if (c == '"') {
      e = i;
      return true;
    }
    ++i;
  }
}

static auto push_json_qstring(buffer &buf, json_iter &b, const json_iter &e)
    -> bool {
  json_iter sb = b;
  json_iter se = e;
  bool is_escaped{false};
  if (!scan_json_qstring(sb, se, is_escaped))
    return false;
  if (is_escaped)
    return push_json_qstring_slow(buf, b, e);
  b = se;
  ++b;
  buf.push_string(string_view(&*sb, (&*se - &*sb)));
  return true;
}

static auto push_json_keyword(buffer &buf, json_iter &b, const json_iter &e)
    -> bool {
  if (match_literal("false", b, e))
    buf.push_bool(false);
  else if (match_literal("true", b, e))
    buf.push_bool(true);
  else if (match_literal("null", b, e))
    buf.push_null();
  else
    return false;
  return true;
}

static auto push_json_value(buffer &buf, json_iter &b, const json_iter &e)
    -> bool;

static auto push_json_array(buffer &buf, json_iter &b, const json_iter &e)
    -> bool {
  if (!match_char('[', b, e))
    return false;
  skip_wsp(b, e);
  buffer inner;
  size_t count{0};
  if (!push_json_value(inner, b, e))
    return false;
  ++count;
  while (true) {
    skip_wsp(b, e);
    if (b == e)
      return false;
    char c = *b;
    switch (c) {
    case ',':
      ++b;
      skip_wsp(b, e);
      continue;
    case ']':
      ++b;
      inner.to_cbor(buf.array_header(count));
      return true;
    default:
      if (!push_json_value(inner, b, e))
        return false;
      ++count;
    }
  }
}

static auto push_json_map(buffer &buf, json_iter &b, const json_iter &e)
    -> bool {
  if (!match_char('{', b, e))
    return false;
  skip_wsp(b, e);
  buffer inner;
  size_t count{0};
  if (!push_json_value(inner, b, e))
    return false;
  ++count;
  while (true) {
    skip_wsp(b, e);
    if (b == e)
      return false;
    char c = *b;
    switch (c) {
    case ':':
    case ',':
      ++b;
      skip_wsp(b, e);
      continue;
    case '}':
      ++b;
      if (count % 2)
        return false;
      inner.to_cbor(buf.map_header(count / 2));
      return true;
    default:
      if (!push_json_value(inner, b, e))
        return false;
      ++count;
    }
  }
}

static auto push_json_value(buffer &buf, json_iter &b, const json_iter &e)
    -> bool {
  skip_wsp(b, e);
  if (b == e)
    return false;
  char c = *b;
  if ((c >= '0' && c <= '9') || c == '-') { // integer
    return push_json_number(buf, b, e);
  }
  if ((c >= 'A' && c <= 'Z') || (c >= 'z' && c <= 'z')) { // keyword
    return push_json_keyword(buf, b, e);
  }
  switch (c) {
  case '"': // string
    return push_json_qstring(buf, b, e);
  case '[': // array
    return push_json_array(buf, b, e);
  case '{': // map
    return push_json_map(buf, b, e);
  default:
    break;
  }

  return false;
}
} // namespace

auto buffer::push_json(const string &s) -> void {
  json_iter b = s.cbegin();
  if (!push_json_value(*this, b, s.cend())) {
    stringstream ss;
    ss << "invalid json value at pos " << std::distance(s.cbegin(), b)
       << " in: " << s;
    throw domain_error{ss.str()};
  }
}

using iter = buffer::const_iterator;

namespace {
static auto decode_int_length_recurse(size_t length, iter &b, const iter &e,
                                      int64_t i) -> int64_t {
  if (b == e)
    throw domain_error{"cbor message too short"};
  i |= *b;
  ++b;
  if (length == 1)
    return i;
  i <<= 8;
  return decode_int_length_recurse(length - 1, b, e, i);
};

static auto decode_int_length(size_t length, iter &b, const iter &e)
    -> int64_t {
  return decode_int_length_recurse(length, b, e, 0);
}

static auto decode_pint(uint8_t type, iter &b, const iter &e) -> uint64_t {
  if (type < 24)
    return type;
  switch (type) {
  case 24: // 1 byte
    return decode_int_length(1, b, e);
  case 25: // 2 byte
    return decode_int_length(2, b, e);
  case 26: // 4 byte
    return decode_int_length(4, b, e);
  case 27: // 8 byte
    return decode_int_length(8, b, e);
  default:
    throw domain_error{"cbor invalid integer type"};
  }
}

static auto decode_nint(uint8_t type, iter &b, const iter &e) -> int64_t {
  return -(decode_pint(type, b, e) + 1); // NOLINT(*-narrowing-conversions)
}

static auto decode_string(uint8_t type, iter &b, const iter &e) -> string_view {
  auto len = decode_pint(type, b, e);
  const uint8_t *s = &*b;
  const auto sz = len;
  while (len) {
    if (b == e)
      throw domain_error{"cbor message too short"};
    ++b;
    --len;
  }
  return {
      reinterpret_cast< // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast)
          const char *>(s),
      static_cast<size_t>(sz)};
}

static auto decode_bytes(uint8_t type, iter &b, const iter &e) -> string_view {
  return decode_string(type, b, e);
}

static auto decode_type(iter &b, const iter &e)
    -> tuple<uint8_t, uint8_t, uint8_t> {
  if (b == e)
    throw domain_error{"cbor message too short"};
  uint8_t type = *b;
  ++b;
  return make_tuple(uint8_t(type >> 5), uint8_t(type & 31), type);
}
} // namespace

auto buffer::decode_range_header(iter &b, const iter &e) -> size_t {
  const auto [major, minor, type] = decode_type(b, e);
  if (type == 0xf6)
    return 0;
  auto sz = decode_pint(minor, b, e);
  switch (major) {
  case 4: // array
    return sz;
  case 5: // map
    return sz * 2;
  default:
    throw domain_error{"cbor unexpected type (expected array or map)"};
  }
}

auto buffer::decode_array_header(iter &b, const iter &e) -> size_t {
  const auto [major, minor, type] = decode_type(b, e);
  if (type == 0xf6)
    return 0;
  if (major != 4)
    throw domain_error{"cbor unexpected type (expected array)"};
  return decode_pint(minor, b, e);
}

auto buffer::decode_map_header(iter &b, const iter &e) -> size_t {
  const auto [major, minor, type] = decode_type(b, e);
  if (type == 0xf6)
    return 0;
  if (major != 5)
    throw domain_error{"cbor unexpected type (expected map)"};
  return decode_pint(minor, b, e);
}

namespace {
static auto skip_string(uint8_t type, iter &b, const iter &e) -> void {
  auto len = decode_pint(type, b, e);
  while (len) {
    if (b == e)
      throw domain_error{"cbor message too short"};
    ++b;
    --len;
  }
}

static auto skip_bytes(uint8_t type, iter &b, const iter &e) -> void {
  return skip_string(type, b, e);
}

static auto skip_array(uint8_t type, iter &b, const iter &e) -> void;
static auto skip_map(uint8_t type, iter &b, const iter &e) -> void;

static auto skip_value_type(uint8_t major, uint8_t minor, iter &b,
                            const iter &e) -> void {
  switch (major) {
  case 0: // positive integer
    decode_pint(minor, b, e);
    break;
  case 1: // negative integer
    decode_nint(minor, b, e);
    break;
  case 2: // bytes
    skip_bytes(minor, b, e);
    break;
  case 3: // string
    skip_string(minor, b, e);
    break;
  case 4: // array
    skip_array(minor, b, e);
    break;
  case 5: // map
    skip_map(minor, b, e);
    break;
  case 6: // tag
    throw domain_error{"cbor unsupported type tag"};
  case 7: // special
    break;
  default:
    throw domain_error{"cbor unsupported type unknown"};
  }
}
static auto skip_value(iter &b, const iter &e) -> void {
  const auto [major, minor, type] = decode_type(b, e);
  skip_value_type(major, minor, b, e);
}

static auto skip_array(uint8_t type, iter &b, const iter &e) -> void {
  auto len = decode_pint(type, b, e);
  while (len) {
    skip_value(b, e);
    --len;
  }
}

static auto skip_map(uint8_t type, iter &b, const iter &e) -> void {
  auto len = decode_pint(type, b, e);
  len = len * 2;
  while (len) {
    skip_value(b, e);
    --len;
  }
}

static auto match_type(iter &b, const iter &e, type &v) -> bool {
  const auto [major, minor, type] = decode_type(b, e);
  skip_value_type(major, minor, b, e);
  switch (major) {
  case 0: // positive integer
  case 1: // negative integer
    v = type::number;
    break;
  case 2: // bytes
    v = type::bytes;
    break;
  case 3: // string
    v = type::string;
    break;
  case 4: // array
    v = type::array;
    break;
  case 5: // map
    v = type::map;
    break;
  case 7: // special
    if (type == 0xf6)
      v = type::null;
    else if (type == 0xf4 || type == 0xf5)
      v = type::boolean;
    break;
  default:
    return false;
  }
  return true;
}
} // namespace

auto buffer::match_value(iter &b, const iter &e, type t) -> bool {
  type v{type::any};
  if (match_type(b, e, v)) {
    if (t == type::any)
      return true;
    return t == v;
  }
  return false;
}

namespace {
static auto match_uint(iter &b, const iter &e, unsigned long long int &val)
    -> bool {
  const auto [major, minor, type] = decode_type(b, e);
  if (major != 0)
    return false;
  val = decode_pint(minor, b, e);
  return true;
}

static auto match_int(iter &b, const iter &e, signed long long int &val)
    -> bool {
  const auto [major, minor, type] = decode_type(b, e);
  switch (major) {
  case 0:                           // positive integer
    val = decode_pint(minor, b, e); // NOLINT(*-narrowing-conversions)
    if (val < 0)
      return false;
    break;
  case 1: // negative integer
    val = decode_nint(minor, b, e);
    break;
  default:
    return false;
  }
  return true;
}
} // namespace

auto buffer::match_value(iter &b, const iter &e, unsigned long long int lit)
    -> bool {
  unsigned long long int val{0};
  if (match_uint(b, e, val))
    return val == lit;
  return false;
}

auto buffer::match_value(iter &b, const iter &e, signed long long int lit)
    -> bool {
  signed long long int val{0};
  if (match_int(b, e, val))
    return val == lit;
  return false;
}

namespace {
static auto match_bool(iter &b, const iter &e, bool &v) -> bool {
  const auto [major, minor, type] = decode_type(b, e);
  if (major == 7) { // special
    if (type == 0xf4) {
      v = false;
      return true;
    }
    if (type == 0xf5) {
      v = true;
      return true;
    }
  }
  return false;
}
} // namespace

auto buffer::match_value(iter &b, const iter &e, bool lit) -> bool {
  bool val{};
  if (match_bool(b, e, val))
    return val == lit;
  return false;
}

namespace {
static auto match_string(iter &b, const iter &e, string_view &val) -> bool {
  const auto [major, minor, type] = decode_type(b, e);
  switch (major) {
  case 2: // bytes
    val = decode_bytes(minor, b, e);
    break;
  case 3: // string
    val = decode_string(minor, b, e);
    break;
  default:
    return false;
  }
  return true;
}
} // namespace

auto buffer::match_value(iter &b, const iter &e, const string_view lit)
    -> bool {
  string_view val;
  if (match_string(b, e, val))
    return val == lit;
  return false;
}

auto buffer::match_value(iter &b, const iter &e, const string &lit) -> bool {
  string_view val;
  if (match_string(b, e, val))
    return val == lit;
  return false;
}

auto extract(type &t) -> buffer::extractor {
  return [&t](iter &b, const iter &e) { return match_type(b, e, t); };
}

namespace {
template <typename T> static auto extract_int(T &i) -> buffer::extractor {
  return [&i](iter &b, const iter &e) {
    signed long long int i_{};
    if (match_int(b, e, i_)) {
      if (i_ < numeric_limits<T>::min() or i_ > numeric_limits<T>::max())
        return false;
      i = i_;
      return true;
    }
    return false;
  };
}
} // namespace

// clang-format off
auto extract(signed long long int &i) -> buffer::extractor { return extract_int(i); }
auto extract(signed long int &i) -> buffer::extractor { return extract_int(i); }
auto extract(signed int &i) -> buffer::extractor { return extract_int(i); }
auto extract(signed short int &i) -> buffer::extractor { return extract_int(i); }
auto extract(signed char &i) -> buffer::extractor { return extract_int(i); }
// clang-format on

auto extract(unsigned long long int &i) -> buffer::extractor {
  return [&i](iter &b, const iter &e) { return match_uint(b, e, i); };
}
namespace {
template <typename T> static auto extract_uint(T &i) -> buffer::extractor {
  return [&i](iter &b, const iter &e) {
    unsigned long long int i_{};
    if (match_uint(b, e, i_)) {
      if (i_ > numeric_limits<T>::max())
        return false;
      i = i_;
      return true;
    }
    return false;
  };
}
} // namespace
// clang-format off
auto extract(unsigned long int &i) -> buffer::extractor { return extract_uint(i); }
auto extract(unsigned int &i) -> buffer::extractor { return extract_uint(i); }
auto extract(unsigned short int &i) -> buffer::extractor { return extract_uint(i); }
auto extract(unsigned char &i) -> buffer::extractor { return extract_uint(i); }
// clang-format on

auto extract(bool &val) -> buffer::extractor {
  return [&val](iter &b, const iter &e) { return match_bool(b, e, val); };
}

auto extract(std::string &s) -> buffer::extractor {
  return [&s](iter &b, const iter &e) {
    string_view val;
    if (match_string(b, e, val)) {
      s.assign(val.data(), val.size());
      return true;
    }
    return false;
  };
}

auto extract(string_view &s) -> buffer::extractor {
  return [&s](iter &b, const iter &e) { return match_string(b, e, s); };
}

auto extract(buffer::range &r) -> buffer::extractor {
  return [&r](iter &b, const iter &e) {
    auto r_b = b;
    type v{type::any};
    if (match_type(b, e, v) &&
        (v == type::null || v == type::array || v == type::map)) {
      r.b_ = r_b;
      r.e_ = b;
      return true;
    }
    return false;
  };
}

auto buffer::match_value(iter &b, const iter &e, const extractor &ex) -> bool {
  return ex(b, e);
}

namespace {
static auto tohex(ostream &os, uint8_t v) -> ostream & {
  return os << hex << setfill('0') << setw(2) << static_cast<unsigned>(v);
}

static auto to_json(ostream &os, string_view s) -> ostream & {
  os << '"';
  for (auto c : s) {
    switch (c) {
    case '\b':
      os << "\\b";
      break;
    case '\f':
      os << "\\f";
      break;
    case '\n':
      os << "\\n";
      break;
    case '\r':
      os << "\\r";
      break;
    case '\t':
      os << "\\t";
      break;
    case '\\':
      os << "\\\\";
      break;
    case '"':
      os << "\\\"";
      break;
    default:
      if (c >= 0 && c <= 0x1f) {
        os << "\\u00";
        tohex(os, c);
      } else {
        os << c;
      }
    }
  }
  os << '"';
  return os;
}

static auto to_json_stream(ostream &ss, iter &b, const iter &e) -> void {
  const auto [major, minor, type] = decode_type(b, e);
  switch (major) {
  case 0: // positive integer
  {
    const auto i = decode_pint(minor, b, e);
    ss << i;
  } break;
  case 1: // negative integer
  {
    const auto i = decode_nint(minor, b, e);
    ss << i;
  } break;
  case 2: // bytes
  {
    const string_view v = decode_bytes(minor, b, e);
    to_json(ss, v);
  } break;
  case 3: // string
  {
    const string_view v = decode_string(minor, b, e);
    to_json(ss, v);
  } break;
  case 4: // array
  {
    auto i = decode_pint(minor, b, e);
    ss << '[';
    while (i) {
      to_json_stream(ss, b, e);
      --i;
      if (i)
        ss << ',';
    }
    ss << ']';
  } break;
  case 5: // map
  {
    auto i = decode_pint(minor, b, e);
    ss << '{';
    while (i) {
      to_json_stream(ss, b, e);
      ss << ':';
      to_json_stream(ss, b, e);
      --i;
      if (i)
        ss << ',';
    }
    ss << '}';
  } break;
  case 6: // tag
    throw domain_error{"cbor unsupported type tag"};
  case 7: // special
  {
    if (type == 0xf4)
      ss << "false";
    else if (type == 0xf5)
      ss << "true";
    else if (type == 0xf6)
      ss << "null";
  } break;
  default:
    throw domain_error{"cbor unsupported type unknown"};
  }
}

static auto to_json_(const iter &b_, const iter &e) -> string {
  stringstream ss;
  iter b = b_;
  try {
    to_json_stream(ss, b, e);
  } catch (const domain_error &e) {
    throw domain_error{string("cbor to json failed: ") + e.what() +
                       "\nafter:\n" + ss.str()};
  }
  return ss.str();
}
} // namespace

auto buffer::to_json() const -> string {
  return to_json_(raw_cbegin(), raw_cend());
}
auto buffer::range::to_json() const -> string {
  return to_json_(raw_cbegin(), raw_cend());
}
auto buffer::to_json(ostream &os) const -> void {
  auto b = raw_cbegin();
  return to_json_stream(os, b, raw_cend());
}
auto buffer::range::to_json(ostream &os) const -> void {
  auto b = raw_cbegin();
  return to_json_stream(os, b, raw_cend());
}

extern "C" void cbor_to_json(cbor_buffer buf, cbor_to_json_callback cb) {
  auto cbor = cbor::buffer();
  const uint8_t *data = buf.base;
  std::copy(data, data + buf.len, // NOLINT(*-pointer-arithmetic)
            back_inserter(cbor));
  auto json = cbor.to_json();
  cb({json.data(), json.size()});
}

auto buffer::hexdump() const -> string {
  stringstream ss;
  ss << size() << ':';
  for (auto c : static_cast<const buffer_base &>(*this)) {
    ss << ' ';
    tohex(ss, c);
  }
  return ss.str();
}

auto buffer::value_accessor::type_() const -> type {
  type t{};
  iter b_ = b;
  if (not match_value(b_, e, extract(t)))
    return type::unknown;
  return t;
}

namespace {
template <typename T> static auto get(iter b, const iter &e) -> T {
  T val;
  extract(val)(b, e);
  return val;
}
} // namespace

// clang-format off
buffer::value_accessor::operator type() const { return get<type>(b, e); }
buffer::value_accessor::operator unsigned long long int() const { return get<unsigned long long int>(b, e); }
buffer::value_accessor::operator unsigned long int() const { return get<unsigned long int>(b, e); }
buffer::value_accessor::operator unsigned int() const { return get<unsigned int>(b, e); }
buffer::value_accessor::operator unsigned short int() const { return get<unsigned short int>(b, e); }
buffer::value_accessor::operator unsigned char() const { return get<unsigned char>(b, e); }
buffer::value_accessor::operator signed long long int() const { return get<signed long long int>(b, e); }
buffer::value_accessor::operator signed long int() const { return get<signed long int>(b, e); }
buffer::value_accessor::operator signed int() const { return get<signed int>(b, e); } // NOLINT(*-narrowing-conversions)
buffer::value_accessor::operator signed short int() const { return get<signed short int>(b, e); } // NOLINT(*-narrowing-conversions)
buffer::value_accessor::operator signed char() const { return get<signed char>(b, e); } // NOLINT(*-narrowing-conversions)
buffer::value_accessor::operator bool() const { return get<bool>(b, e); }
buffer::value_accessor::operator string_view() const { return get<string_view>(b, e); }
buffer::value_accessor::operator buffer::range() const { return get<buffer::range>(b, e); }
// clang-format on

} // namespace cbor
