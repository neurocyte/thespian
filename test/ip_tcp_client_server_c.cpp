#include "tests.hpp"
#include <cbor/c/cbor.h>
#include <cbor/cbor.hpp>
#include <thespian/c/context.h>
#include <thespian/c/handle.h>
#include <thespian/c/instance.h>
#include <thespian/c/socket.h>
#include <thespian/c/tcp.h>

#include <netinet/in.h>
#include <stdio.h>
#include <string.h>

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static thread_local char msg_json[256]; // NOLINT

static void capture_json(c_string_view s) {
  snprintf(msg_json, sizeof(msg_json), "%.*s", (int)s.len, s.base);
}

static bool msg_is(cbor_buffer m, const char *pat) {
  cbor_to_json(m, capture_json);
  return strcmp(msg_json, pat) == 0;
}

static bool msg_extract_int(cbor_buffer m, const char *pat, int *out) {
  cbor_to_json(m, capture_json);
  return sscanf(msg_json, pat, out) == 1; // NOLINT
}

static thespian_result send(thespian_handle h, cbor::buffer msg) {
  cbor_buffer m{msg.data(), msg.size()};
  return thespian_handle_send_raw(h, m);
}

#define LOG(...) fprintf(stderr, "[c_api] " __VA_ARGS__)

// ---------------------------------------------------------------------------
// client_connection
// ---------------------------------------------------------------------------

struct cc_state {
  thespian_socket_handle *sock;
  thespian_handle client;
};

static void cc_dtor(thespian_behaviour_state s) {
  auto *st = static_cast<cc_state *>(s);
  LOG("cc_dtor: client_connection destroyed\n");
  thespian_socket_destroy(st->sock);
  thespian_handle_destroy(st->client);
  delete st;
}

static thespian_result cc_receive(thespian_behaviour_state s, thespian_handle,
                                  cbor_buffer m) {
  cbor_to_json(m, capture_json);
  LOG("cc_receive msg=%s\n", msg_json);
  auto *st = static_cast<cc_state *>(s);
  int written = 0;
  if (msg_is(m,
             "[\"socket\",\"client_connection\",\"read_complete\",\"ping\"]")) {
    LOG("cc_receive: read_complete buf=ping, writing pong\n");
    thespian_socket_write(st->sock, "pong", 4);
  } else if (msg_extract_int(
                 m, "[\"socket\",\"client_connection\",\"write_complete\",%d]",
                 &written)) {
    LOG("cc_receive: write_complete written=%d\n", written);
    thespian_socket_read(st->sock);
  } else if (msg_is(m, "[\"socket\",\"client_connection\",\"closed\"]")) {
    LOG("cc_receive: closed, sending done\n");
    send(st->client, cbor::array("client_connection", "done"));
    return thespian_exit("success");
  } else {
    LOG("cc_receive: UNEXPECTED msg=%s\n", msg_json);
  }
  return nullptr;
}

static thespian_result cc_start(thespian_behaviour_state s) {
  LOG("cc_start entered\n");
  auto *st = static_cast<cc_state *>(s);
  thespian_socket_read(st->sock);
  thespian_receive(cc_receive, s, cc_dtor);
  LOG("cc_start returning\n");
  return nullptr;
}

// ---------------------------------------------------------------------------
// client
// ---------------------------------------------------------------------------

struct client_state {
  thespian_tcp_connector_handle *connector;
  thespian_handle server;
  uint16_t port;
};

static void client_dtor(thespian_behaviour_state s) {
  auto *st = static_cast<client_state *>(s);
  LOG("client_dtor: client destroyed\n");
  thespian_tcp_connector_destroy(st->connector);
  thespian_handle_destroy(st->server);
  delete st;
}

static thespian_result client_receive(thespian_behaviour_state s,
                                      thespian_handle, cbor_buffer m) {
  cbor_to_json(m, capture_json);
  LOG("client_receive msg=%s\n", msg_json);
  auto *st = static_cast<client_state *>(s);
  int fd = 0;
  if (msg_extract_int(m, "[\"connector\",\"client\",\"connected\",%d]", &fd)) {
    LOG("client_receive: connected fd=%d, spawning cc\n", fd);
    auto *cc = new cc_state{thespian_socket_create("client_connection", fd),
                            thespian_handle_clone(thespian_self())};
    thespian_handle out{};
    thespian_spawn_link(cc_start, cc, "client_connection", nullptr, &out);
    thespian_handle_destroy(out);
    LOG("client_receive: cc spawned\n");
  } else if (msg_is(m, "[\"client_connection\",\"done\"]")) {
    LOG("client_receive: cc done, sending client done\n");
    send(st->server, cbor::array("client", "done"));
    return thespian_exit("normal");
  } else {
    LOG("client_receive: UNEXPECTED msg=%s\n", msg_json);
  }
  return nullptr;
}

static thespian_result client_start(thespian_behaviour_state s) {
  auto *st = static_cast<client_state *>(s);
  LOG("client_start entered port=%d\n", st->port);
  thespian_tcp_connector_connect(st->connector, in6addr_loopback, st->port);
  thespian_receive(client_receive, s, client_dtor);
  LOG("client_start returning\n");
  return nullptr;
}

// ---------------------------------------------------------------------------
// server_connection
// ---------------------------------------------------------------------------

struct sc_state {
  thespian_socket_handle *sock;
  thespian_handle server;
};

static void sc_dtor(thespian_behaviour_state s) {
  auto *st = static_cast<sc_state *>(s);
  LOG("sc_dtor: server_connection destroyed\n");
  thespian_socket_destroy(st->sock);
  thespian_handle_destroy(st->server);
  delete st;
}

static thespian_result sc_receive(thespian_behaviour_state s, thespian_handle,
                                  cbor_buffer m) {
  cbor_to_json(m, capture_json);
  LOG("sc_receive msg=%s\n", msg_json);
  auto *st = static_cast<sc_state *>(s);
  int written = 0;
  if (msg_extract_int(
          m, "[\"socket\",\"server_connection\",\"write_complete\",%d]",
          &written)) {
    LOG("sc_receive: write_complete written=%d, reading\n", written);
    thespian_socket_read(st->sock);
  } else if (msg_is(m, "[\"socket\",\"server_connection\",\"read_complete\","
                       "\"pong\"]")) {
    LOG("sc_receive: read_complete buf=pong, closing\n");
    thespian_socket_close(st->sock);
  } else if (msg_is(m, "[\"socket\",\"server_connection\",\"closed\"]")) {
    LOG("sc_receive: closed, sending done\n");
    send(st->server, cbor::array("server_connection", "done"));
    return thespian_exit("success");
  } else {
    LOG("sc_receive: UNEXPECTED msg=%s\n", msg_json);
  }
  return nullptr;
}

static thespian_result sc_start(thespian_behaviour_state s) {
  LOG("sc_start entered\n");
  auto *st = static_cast<sc_state *>(s);
  thespian_socket_write(st->sock, "ping", 4);
  thespian_receive(sc_receive, s, sc_dtor);
  LOG("sc_start returning\n");
  return nullptr;
}

// ---------------------------------------------------------------------------
// server
// ---------------------------------------------------------------------------

struct server_state {
  thespian_tcp_acceptor_handle *acceptor{};
  bool acceptor_closed{false};
  bool client_done{false};
  bool server_conn_done{false};
};

static void server_dtor(thespian_behaviour_state s) {
  auto *st = static_cast<server_state *>(s);
  LOG("server_dtor: server destroyed\n");
  thespian_tcp_acceptor_destroy(st->acceptor);
  delete st;
}

static thespian_result server_receive(thespian_behaviour_state s,
                                      thespian_handle, cbor_buffer m) {
  cbor_to_json(m, capture_json);
  LOG("server_receive msg=%s\n", msg_json);
  auto *st = static_cast<server_state *>(s);
  int fd = 0;
  if (msg_extract_int(m, "[\"acceptor\",\"server\",\"accept\",%d]", &fd)) {
    LOG("server_receive: accept fd=%d, spawning sc\n", fd);
    auto *sc = new sc_state{thespian_socket_create("server_connection", fd),
                            thespian_handle_clone(thespian_self())};
    thespian_handle out{};
    thespian_spawn_link(sc_start, sc, "server_connection", nullptr, &out);
    thespian_handle_destroy(out);
    thespian_tcp_acceptor_close(st->acceptor);
    LOG("server_receive: sc spawned, acceptor closing\n");
  } else if (msg_is(m, "[\"acceptor\",\"server\",\"closed\"]")) {
    LOG("server_receive: acceptor closed (client=%d conn=%d)\n",
        st->client_done, st->server_conn_done);
    st->acceptor_closed = true;
  } else if (msg_is(m, "[\"client\",\"done\"]")) {
    LOG("server_receive: client done (acceptor=%d conn=%d)\n",
        st->acceptor_closed, st->server_conn_done);
    st->client_done = true;
  } else if (msg_is(m, "[\"server_connection\",\"done\"]")) {
    LOG("server_receive: sc done (acceptor=%d client=%d)\n",
        st->acceptor_closed, st->client_done);
    st->server_conn_done = true;
  } else {
    LOG("server_receive: UNEXPECTED msg=%s\n", msg_json);
  }
  if (st->acceptor_closed && st->client_done && st->server_conn_done) {
    LOG("server_receive: all done, exiting success\n");
    return thespian_exit("success");
  }
  return nullptr;
}

static thespian_result server_start(thespian_behaviour_state s) {
  LOG("server_start entered\n");
  auto *st = static_cast<server_state *>(s);
  st->acceptor = thespian_tcp_acceptor_create("server");
  uint16_t port =
      thespian_tcp_acceptor_listen(st->acceptor, in6addr_loopback, 0);
  LOG("server_start: listening on port=%d\n", port);

  auto *cl = new client_state{thespian_tcp_connector_create("client"),
                              thespian_handle_clone(thespian_self()), port};
  thespian_handle out{};
  thespian_spawn_link(client_start, cl, "client", nullptr, &out);
  thespian_handle_destroy(out);
  LOG("server_start: client spawned, calling receive\n");

  thespian_receive(server_receive, s, server_dtor);
  LOG("server_start returning\n");
  return nullptr;
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

auto ip_tcp_client_server_c(thespian::context &ctx, bool &result,
                            thespian::env_t /*env*/) -> thespian::result {
  auto *st = new server_state{};
  thespian_handle out{};
  thespian_context_spawn_link(
      reinterpret_cast<thespian_context>(&ctx), // NOLINT
      server_start, st,
      [](thespian_exit_handler_state r, const char *msg, size_t len) {
        LOG("exit_handler: status=%.*s\n", (int)len, msg);
        if (strncmp(msg, "success", len) == 0)
          *static_cast<bool *>(r) = true;
      },
      &result, "ip_tcp_client_server_c", nullptr, &out);
  thespian_handle_destroy(out);
  return thespian::ok();
}
