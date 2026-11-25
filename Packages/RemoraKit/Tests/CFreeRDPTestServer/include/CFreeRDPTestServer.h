#ifndef CFREERDP_TEST_SERVER_H
#define CFREERDP_TEST_SERVER_H
#include <stdbool.h>
#include <stdint.h>

/* An RDP server in the test process, built on FreeRDP's peer API. It serves one connection on 127.0.0.1 with TLS
 * security, accepts any credentials, sends no pictures, and supports Refresh Rect. A pausable server also supports
 * Suppress Output, so the client pauses it, and answers nothing. */
typedef struct RMTestRDPServer RMTestRDPServer;

/* PEM files for the server's TLS identity. NULL when the socket or thread cannot start. */
RMTestRDPServer *rm_test_rdp_server_start(const char *certificate_path, const char *key_path, bool pausable);
uint16_t rm_test_rdp_server_port(const RMTestRDPServer *);
/* The client finished the connection sequence, so it may send requests. */
bool rm_test_rdp_server_activated(const RMTestRDPServer *);
/* Refresh Rect requests received from the client. */
uint32_t rm_test_rdp_server_refreshes(const RMTestRDPServer *);
/* Those requests with an area that covers the whole desktop. */
uint32_t rm_test_rdp_server_whole_refreshes(const RMTestRDPServer *);
/* Suppress Output requests that pause updates. */
uint32_t rm_test_rdp_server_pauses(const RMTestRDPServer *);
/* The connection ended, from either side, or never arrived before stop. */
bool rm_test_rdp_server_ended(const RMTestRDPServer *);
/* Closes the connection, joins the server thread and frees the server. */
void rm_test_rdp_server_stop(RMTestRDPServer *);
#endif
