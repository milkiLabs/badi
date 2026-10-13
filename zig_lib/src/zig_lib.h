#ifndef ZIG_LIB_H
#define ZIG_LIB_H

/* size_t without pulling in system headers (keeps ffigen/libclang happy). */
typedef __SIZE_TYPE__ size_t;

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque handle owning an app scan result. */
typedef struct BadiAppList BadiAppList;

/* NULL-safe. Only for strings returned by the badi_apps_* getters. */
void badi_free_string(char *s);

/*
 * Scan system + user applications dirs for launchable apps.
 * home_dir locates ~/.local/share/applications, may be NULL to skip it.
 * locale picks localized Name/Icon/Comment, may be NULL for unlocalized.
 * Returns NULL only on OOM. Free with badi_apps_destroy.
 */
BadiAppList *badi_apps_scan(const char *home_dir, const char *locale);

/* Number of apps. NULL-safe (NULL handle = 0). */
size_t badi_apps_count(const BadiAppList *apps);

/* Each getter returns an owned NUL-terminated copy, or NULL when the
 * handle/index is bad, the value is missing, or on OOM. */
char *badi_apps_name(const BadiAppList *apps, size_t index);
char *badi_apps_exec(const BadiAppList *apps, size_t index);
char *badi_apps_icon(const BadiAppList *apps, size_t index);
char *badi_apps_comment(const BadiAppList *apps, size_t index);
char *badi_apps_keywords(const BadiAppList *apps, size_t index);
char *badi_apps_path(const BadiAppList *apps, size_t index);

/* 1 when the app must run in a terminal, 0 when not, -1 when bad. */
int badi_apps_is_terminal(const BadiAppList *apps, size_t index);

/* Number of launch arguments. -1 when handle/index is bad. */
int badi_apps_argc(const BadiAppList *apps, size_t index);

/* One launch argument (0-based). NULL when out of range/bad/OOM.
 * Launch with exactly these arguments; no field codes remain. */
char *badi_apps_argv(const BadiAppList *apps, size_t index, size_t arg);

/* NULL-safe. Frees the handle and every app it owns. */
void badi_apps_destroy(BadiAppList *apps);

#ifdef __cplusplus
}
#endif

#endif
