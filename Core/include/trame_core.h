#ifndef TRAME_CORE_H
#define TRAME_CORE_H
#include <stddef.h>
#include <stdint.h>

// Inputs are borrowed during the call. Strings are NUL-terminated UTF-8.
// URL classification for older libraries: unknown (0), live (1), movies (2), series (3).
uint8_t trame_media_kind(const char *address);
// String results contain JSON and must be released using trame_free.
char *trame_parse_playlist(const uint8_t *source, size_t len, const char *origin, const char *name);
char *trame_xtream_login(const char *server, const char *username, const char *password, const char *kind);
char *trame_xtream_endpoints(const char *login);
char *trame_xtream_catalog(const char *login,
                          const uint8_t *streams, size_t stream_len,
                          const uint8_t *categories, size_t category_len);
char *trame_xtream_episodes(const char *endpoint, const uint8_t *data, size_t len);
void trame_free(char *result);
#endif
