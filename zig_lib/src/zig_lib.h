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
 * substring). Returns 0, -1 on bad handle or OOM (previous view is kept
 * on OOM). The frontend owns the selection cursor and resets it after
 * calling this.
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

/*
 * Append piped lines to a lines-mode session (copied). Newcomers matching
 * the active query join the view in arrival order; existing rows never
 * move, so a frontend-owned cursor stays valid.
 * Returns 0, -1 on bad handle, wrong mode (apps sessions), or OOM.
 * Empty appends are a no-op.
 */
int badi_session_append(BadiSession *session, const char *const *lines, size_t n);

/* Launch argv length for shown row `index`. 0 when bad or not launchable. */
size_t badi_session_arg_count(const BadiSession *session, size_t index);

/*
 * One launch argument as an owned copy. NULL when handle/row/arg is bad,
 * the row is not launchable (lines mode), or on OOM. The frontend spawns
 * it (wrapping in $TERMINAL -e when badi_session_is_terminal is 1,
 * launching in badi_session_cwd when non-NULL).
 */
char *badi_session_arg(const BadiSession *session, size_t index, size_t arg);

/*
 * Whether shown row `index` wants a terminal wrapper: 1 when terminal,
 * 0 when not, -1 when handle/row is bad or not launchable (lines mode).
 */
int badi_session_is_terminal(const BadiSession *session, size_t index);

/*
 * Working directory to launch shown row `index` in, as an owned copy.
 * NULL when unset, bad, not launchable (lines mode), or on OOM.
 * NULL means inherit.
 */
char *badi_session_cwd(const BadiSession *session, size_t index);

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
