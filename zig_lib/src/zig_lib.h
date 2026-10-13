#ifndef ZIG_LIB_H
#define ZIG_LIB_H

/* size_t without pulling in system headers (keeps ffigen/libclang happy). */
typedef __SIZE_TYPE__ size_t;

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque handle owning an app scan result. */
typedef struct BadiAppList BadiAppList;

/* Opaque handle owning search result indices. */
typedef struct BadiFound BadiFound;

/* NULL-safe. Only for strings returned by the getters below. */
void badi_free_string(char *s);

/*
 * Scan system + user applications dirs for launchable apps, sorted by name.
 * $HOME locates ~/.local/share/applications (read inside the scan).
 * locale picks localized Name/Icon/Comment, may be NULL for unlocalized.
 * Returns NULL only on OOM. Free with badi_apps_destroy.
 */
BadiAppList *badi_apps_scan(const char *locale);

/* Number of apps. NULL-safe (NULL handle = 0). */
size_t badi_apps_count(const BadiAppList *apps);

/*
 * Each getter returns an owned NUL-terminated copy, or NULL when the
 * handle/index is bad, the value is missing, or on OOM.
 */
char *badi_apps_name(const BadiAppList *apps, size_t index);
char *badi_apps_comment(const BadiAppList *apps, size_t index);
char *badi_apps_icon_path(const BadiAppList *apps, size_t index);

/*
 * Indices of apps matching query (case-insensitive substring, NULL/blank
 * matches all), in sort order. NULL only on OOM. Free with badi_found_destroy.
 */
BadiFound *badi_apps_search(const BadiAppList *apps, const char *query);

/* Number of matches. NULL-safe (NULL handle = 0). */
size_t badi_found_count(const BadiFound *found);

/* App index of match n. -1 when handle/n is bad. */
long badi_found_at(const BadiFound *found, size_t n);

/* NULL-safe. Frees a search handle. */
void badi_found_destroy(BadiFound *found);

/*
 * Spawn the app and return immediately (no waiting). Terminal apps are
 * wrapped in $TERMINAL -e. Returns 0 on spawn, -1 on bad handle/index or
 * empty argv, -2 when the spawn itself fails.
 */
int badi_apps_launch(const BadiAppList *apps, size_t index);

/* NULL-safe. Frees the handle and every app it owns. */
void badi_apps_destroy(BadiAppList *apps);

#ifdef __cplusplus
}
#endif

#endif
