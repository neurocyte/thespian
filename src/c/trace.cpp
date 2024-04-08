#include <thespian/c/trace.h>
#include <thespian/trace.hpp>

extern "C" {

void thespian_on_trace(thespian_trace_handler h) {
  thespian::on_trace([h](const cbor::buffer &m) { h({m.data(), m.size()}); });
}

void thespian_trace_to_json_file(const char *file_name) {
  thespian::trace_to_json_file(file_name);
}

void thespian_trace_to_cbor_file(const char *file_name) {
  thespian::trace_to_cbor_file(file_name);
}

void thespian_trace_to_mermaid_file(const char *file_name) {
  thespian::trace_to_mermaid_file(file_name);
}

}
