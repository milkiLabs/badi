#ifndef ZIG_LIB_H
#define ZIG_LIB_H

/* size_t without pulling in system headers (keeps ffigen/libclang happy). */
typedef __SIZE_TYPE__ size_t;

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque handle owning a picker session (apps or piped lines). */
typedef struct BadiSession BadiSession;

/* NULL-safe. Only for strings returned by the getters below. */
void badi_free_string(char *s);

/*
 * Open an apps-mode session: scan system + user applications dirs,
 * sorted by name. locale picks localized Name/Icon/Comment, may be
 * NULL for unlocalized. Returns NULL only on OOM.
 * Free with badi_session_destroy.
 */
BadiSession *badi_session_apps(const char *locale);

/*
 * Open a lines-mode session over `lines` (copied; caller keeps ownership).
 * NULL lines or 0 count opens an empty session. Returns NULL only on OOM.
 * Free with badi_session_destroy.
 */
BadiSession *badi_session_lines(const char *const *lines, size_t n);

/*
 * Re-filter on query (NULL/blank shows all, ASCII case-insensitive
 * substring) and reset selection to the top. Returns 0, -1 on bad
 * handle or OOM (previous view is kept on OOM).
 */
int badi_session_query(BadiSession *session, const char *query);

/* Shown row count. NULL-safe (NULL handle = 0). */
size_t badi_session_count(const BadiSession *session);

/*
 * Each getter returns an owned NUL-terminated copy, or NULL when the
 * handle/row is bad, the value is missing, or on OOM. subtitle/icon are
 * always NULL in lines mode.
 */
char *badi_session_title(const BadiSession *session, size_t index);
char *badi_session_subtitle(const BadiSession *session, size_t index);
char *badi_session_icon(const BadiSession *session, size_t index);

/* Move selection by delta rows, clamped. No-op on bad handle/empty view. */
void badi_session_move(BadiSession *session, long delta);

/*
 * Append piped lines to a lines-mode session (copied). Newcomers matching
 * the active query join the view in arrival order; selection is untouched.
 * Returns 0, -1 on bad handle, wrong mode (apps sessions), or OOM.
 * Empty appends are a no-op.
 */
int badi_session_append(BadiSession *session, const char *const *lines, size_t n);

/* Selected shown-row index, or -1 when handle is bad or view is empty. */
long badi_session_selected(const BadiSession *session);

/*
 * Spawn shown row index and return immediately (no waiting). Terminal apps
 * are wrapped in $TERMINAL -e. Returns 0 on spawn, -1 on bad handle/row
 * or when the row is not launchable (lines mode), -2 when the spawn
 * itself fails.
 */
int badi_session_launch(BadiSession *session, size_t index);

/*
 * Selected line in lines mode, as an owned copy: print it to stdout.
 * NULL in apps mode or when handle/row is bad, or on OOM.
 */
char *badi_session_result(const BadiSession *session, size_t index);

/* NULL-safe. Frees the handle and every row it owns. */
void badi_session_destroy(BadiSession *session);

#ifdef __cplusplus
}
#endif

#endif
