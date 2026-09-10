/*
 * names.c -- the command-name <-> table-name map (see names.h).
 */

#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include "names.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* One (table, name) pairing. */
typedef struct {
	char *table;
	char *name;
} NameEntry;

struct NameMap {
	NameEntry *entries;
	int        n;
};

/* Duplicate a C string or abort; nothing sensible to do on OOM here. */
static char *xstrdup(const char *s)
{
	char *p = strdup(s ? s : "");
	if (!p) {
		fprintf(stderr, "knit-cypher-to-sql: out of memory\n");
		exit(1);
	}
	return p;
}

static int fail(char **errmsg, const char *fmt, ...)
{
	if (errmsg) {
		char buf[256];
		va_list ap;
		va_start(ap, fmt);
		vsnprintf(buf, sizeof buf, fmt, ap);
		va_end(ap);
		*errmsg = strdup(buf);
	}
	return 1;
}

static NameMap *map_new(void)
{
	NameMap *m = calloc(1, sizeof *m);
	if (!m) {
		fprintf(stderr, "knit-cypher-to-sql: out of memory\n");
		exit(1);
	}
	return m;
}

/* Append a (table, name) entry, taking copies of both strings. */
static void map_add(NameMap *m, const char *table, const char *name)
{
	NameEntry *grown =
		realloc(m->entries, (m->n + 1) * sizeof *grown);
	if (!grown) {
		fprintf(stderr, "knit-cypher-to-sql: out of memory\n");
		exit(1);
	}
	m->entries = grown;
	m->entries[m->n].table = xstrdup(table);
	m->entries[m->n].name = xstrdup(name);
	m->n++;
}

/* Trim leading and trailing ASCII spaces/tabs in place; returns s. */
static char *trim(char *s)
{
	while (*s == ' ' || *s == '\t')
		s++;
	char *end = s + strlen(s);
	while (end > s && (end[-1] == ' ' || end[-1] == '\t'
			|| end[-1] == '\r' || end[-1] == '\n'))
		*--end = '\0';
	return s;
}

/*
 * Parse one `table=name` entry (already isolated between separators) into the
 * map. Blank entries are ignored. A missing '=' or an empty side is an error.
 */
static int parse_entry(NameMap *m, char *entry, char **errmsg)
{
	entry = trim(entry);
	if (*entry == '\0')
		return 0;

	char *eq = strchr(entry, '=');
	if (!eq)
		return fail(errmsg, "invalid name map entry (expected "
			"table=name): %s", entry);
	*eq = '\0';
	char *table = trim(entry);
	char *name = trim(eq + 1);
	if (*table == '\0' || *name == '\0')
		return fail(errmsg, "invalid name map entry (empty table or "
			"name): %s=%s", table, name);
	map_add(m, table, name);
	return 0;
}

int names_parse(const char *spec, NameMap **out, char **errmsg)
{
	*out = NULL;
	if (errmsg)
		*errmsg = NULL;

	NameMap *m = map_new();
	if (!spec) {
		*out = m;
		return 0;
	}

	/* Split on newlines and ';' into individual entries; parse each. */
	char *buf = xstrdup(spec);
	char *p = buf;
	int rc = 0;
	while (*p) {
		char *sep = p + strcspn(p, "\n;");
		int done = (*sep == '\0');
		*sep = '\0';
		if (parse_entry(m, p, errmsg)) {
			rc = 1;
			break;
		}
		if (done)
			break;
		p = sep + 1;
	}
	free(buf);

	if (rc) {
		names_free(m);
		return 1;
	}
	*out = m;
	return 0;
}

int names_parse_file(const char *path, NameMap **out, char **errmsg)
{
	*out = NULL;
	if (errmsg)
		*errmsg = NULL;

	FILE *f = fopen(path, "rb");
	if (!f)
		return fail(errmsg, "cannot open name map file: %s", path);

	/* Slurp the whole file. */
	size_t cap = 4096, len = 0;
	char *buf = malloc(cap);
	if (!buf) {
		fprintf(stderr, "knit-cypher-to-sql: out of memory\n");
		exit(1);
	}
	size_t got;
	while ((got = fread(buf + len, 1, cap - len, f)) > 0) {
		len += got;
		if (len == cap) {
			cap *= 2;
			char *grown = realloc(buf, cap);
			if (!grown) {
				fprintf(stderr, "knit-cypher-to-sql: out of memory\n");
				exit(1);
			}
			buf = grown;
		}
	}
	int ferr = ferror(f);
	fclose(f);
	if (ferr) {
		free(buf);
		return fail(errmsg, "cannot read name map file: %s", path);
	}
	buf[len] = '\0';

	int rc = names_parse(buf, out, errmsg);
	free(buf);
	return rc;
}

int names_resolve(const NameMap *map, const char *label,
                  const char **table, const char **name, char **errmsg)
{
	*table = NULL;
	*name = NULL;
	if (!label)
		return 0;

	/* Match LABEL as a table name and (separately) as a recorded name. */
	const char *as_table_t = NULL, *as_table_n = NULL;
	const char *as_name_t = NULL, *as_name_n = NULL;
	if (map) {
		for (int i = 0; i < map->n; i++) {
			if (strcmp(map->entries[i].table, label) == 0) {
				as_table_t = map->entries[i].table;
				as_table_n = map->entries[i].name;
			}
			if (strcmp(map->entries[i].name, label) == 0) {
				as_name_t = map->entries[i].table;
				as_name_n = map->entries[i].name;
			}
		}
	}

	if (as_table_t && as_name_t) {
		/* Ambiguous only if the two readings disagree. */
		if (strcmp(as_table_t, as_name_t) != 0
				|| strcmp(as_table_n, as_name_n) != 0)
			return fail(errmsg,
				"ambiguous label '%s': it is both a table name "
				"and a command name", label);
		*table = as_table_t;
		*name = as_table_n;
	} else if (as_table_t) {
		*table = as_table_t;
		*name = as_table_n;
	} else if (as_name_t) {
		*table = as_name_t;
		*name = as_name_n;
	} else {
		*table = label;
		*name = label;
	}
	return 0;
}

void names_free(NameMap *map)
{
	if (!map)
		return;
	for (int i = 0; i < map->n; i++) {
		free(map->entries[i].table);
		free(map->entries[i].name);
	}
	free(map->entries);
	free(map);
}
