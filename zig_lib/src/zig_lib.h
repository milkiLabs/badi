#ifndef ZIG_LIB_H
#define ZIG_LIB_H

/* size_t without pulling in system headers (keeps ffigen/libclang happy). */
typedef __SIZE_TYPE__ size_t;

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque handle owning a badi_scan result (array of parsed documents). */
typedef struct BadiAppList BadiAppList;

/* NULL-safe. Only for strings returned by badi_scan_get_value. */
void badi_free_string(char *s);

/*
 * Scan system + user applications dirs, parse every *.desktop file.
 * home_dir locates ~/.local/share/applications, may be NULL to skip it.
 * Returns NULL only on OOM. Free with badi_scan_destroy.
 */
BadiAppList *badi_scan(const char *home_dir);

/* Number of parsed docs. NULL-safe (NULL list = 0). */
size_t badi_scan_count(const BadiAppList *list);

/*
 * Indexed lookup on a scanned doc, localized for locale (may be NULL).
 * Returns an owned NUL-terminated copy, or NULL when list/index/group/key
 * is missing. Free with badi_free_string, never with free().
 */
char *badi_scan_get_value(const BadiAppList *list, size_t index,
                          const char *group, const char *key,
                          const char *locale);

/* NULL-safe. Frees the list and every doc it owns. */
void badi_scan_destroy(BadiAppList *list);

#ifdef __cplusplus
}
#endif

#endif
