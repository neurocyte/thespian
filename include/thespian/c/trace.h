#pragma once

#include <cbor/c/cbor.h>

// NOLINTBEGIN(modernize-*, hicpp-*)
#include <limits.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef int thespian_trace_channel_set;

typedef int thespian_trace_channel;

static const thespian_trace_channel thespian_trace_channel_send = 1;
static const thespian_trace_channel thespian_trace_channel_receive = 2;
static const thespian_trace_channel thespian_trace_channel_lifetime = 4;
static const thespian_trace_channel thespian_trace_channel_link = 8;
static const thespian_trace_channel thespian_trace_channel_execute = 16;
static const thespian_trace_channel thespian_trace_channel_udp = 32;
static const thespian_trace_channel thespian_trace_channel_tcp = 64;
static const thespian_trace_channel thespian_trace_channel_timer = 128;
static const thespian_trace_channel thespian_trace_channel_metronome = 256;
static const thespian_trace_channel thespian_trace_channel_endpoint = 512;
static const thespian_trace_channel thespian_trace_channel_signal = 1024;
static const thespian_trace_channel thespian_trace_channel_all = INT_MAX;

typedef void (*thespian_trace_handler)(cbor_buffer);

void thespian_on_trace(thespian_trace_handler);
void thespian_trace_to_json_file(const char *file_name);
void thespian_trace_to_cbor_file(const char *file_name);
void thespian_trace_to_mermaid_file(const char *file_name);
void thespian_trace_to_trace(thespian_trace_channel default_channel);

#ifdef __cplusplus
}
#endif
// NOLINTEND(modernize-*, hicpp-*)
