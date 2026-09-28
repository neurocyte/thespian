#pragma once

#include "context.hpp"
#include "handle.hpp"

#include <string>

using port_t = unsigned short;

namespace thespian::debug {

// While enabled, named actors spawned in the context are registered so the
// debug console can address them by name.
auto enable(context &) -> void;
auto disable(context &) -> void;
auto isenabled(context &) -> bool;

namespace tcp {

// Start the debug console on [::1]:port. Must be called from within an actor.
// Sending the returned handle any message other than "ping" stops listening.
// There is no authentication: enable it in development builds only.
//
// Each line received is one command. Trailing "\r" is ignored. A connection
// starts in text mode and switches to JSON mode for good at the first line
// that begins with "{".
//
// Text mode (for humans):
//   <empty line>         list the names of registered actors
//   NAME JSON            send JSON (converted to cbor) to NAME
//   tap NAME             stream messages sent to and by actors named NAME,
//                        and their exit, as
//                          tap NAME recv|send PEER JSON
//                          tap NAME exit JSON
//   untap NAME           stop tapping NAME
//   bye                  close the connection
// Any other message sent to the console connection is printed as
//   SENDER JSON
//
// JSON mode (for tools and agents; one JSON object per line):
//   {"id":ID,"cmd":"list"}
//   {"id":ID,"cmd":"send","to":NAME,"msg":MSG}
//   {"id":ID,"cmd":"call","to":NAME,"msg":MSG,"timeout_ms":5000}
//   {"id":ID,"cmd":"tap","name":NAME}
//   {"id":ID,"cmd":"untap","name":NAME}
//   {"id":ID,"cmd":"bye"}
// ID is optional and may be any JSON value; it is echoed back in the
// response. Every command gets exactly one response:
//   {"id":ID,"ok":true}                       send, tap, untap, bye
//   {"id":ID,"ok":true,"result":[NAMES...]}   list
//   {"id":ID,"ok":true,"from":NAME,"result":REPLY}   call
//   {"id":ID,"ok":false,"error":TEXT}
// "call" sends MSG from a temporary actor and responds with the first
// message sent back to it, or an error of "timeout". "send" responses only
// report that the message was queued; replies to it arrive as events.
// Events are unsolicited lines without an id:
//   {"event":"message","from":NAME,"msg":MSG}
//   {"event":"tap","actor":NAME,"dir":"recv"|"send","peer":NAME,"msg":MSG}
//   {"event":"tap","actor":NAME,"dir":"exit","msg":EXIT_MSG}
//
// Taps match actor names rather than registered handles, so they cover every
// actor with that name, including ones spawned later or before enable().
// Actors named "debug_*" (the console itself) cannot be tapped.
auto create(context &, port_t port, const std::string &prompt)
    -> expected<handle, error>;

} // namespace tcp
} // namespace thespian::debug
