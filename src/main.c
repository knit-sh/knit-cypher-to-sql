/*
 * knit-cypher-to-sql -- translate a read-only Cypher statement into SQL.
 *
 * The program is a pure transpiler: it never opens a database or runs a query.
 * The default path reads the flat provenance schema on stdin (one line per
 * table, "name<TAB>col,col,..."), validates the statement's labels and columns
 * against it, and prints the SQL. `--ast` parses a statement and prints its
 * syntax tree, needing no schema.
 */

#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ast.h"
#include "catalog.h"
#include "names.h"
#include "transform.h"

static const char *PROG = "knit-cypher-to-sql";

static void usage(FILE *out)
{
	fprintf(out,
		"Usage: %s [--names SPEC | --names-file FILE] 'CYPHER'\n"
		"       %s --ast 'CYPHER'\n"
		"\n"
		"Translate a read-only Cypher statement into SQL. The flat provenance\n"
		"schema is read on stdin (one line per table, 'name<TAB>col,col,...');\n"
		"labels and columns are validated against it and the SQL is printed.\n"
		"\n"
		"Modes:\n"
		"  --ast         parse only and print the syntax tree (no schema)\n"
		"  -h, --help    show this help and exit\n"
		"\n"
		"Label resolution:\n"
		"  --names SPEC          map entries 'table=name', separated by newlines\n"
		"                        or ';', so a label may be a table or command name\n"
		"  --names-file FILE     read the same map from FILE\n",
		PROG, PROG);
}

/*
 * Read all of stdin into a NUL-terminated malloc'd buffer (the flat schema).
 * Returns NULL on a read or allocation error; the caller frees the result.
 */
static char *read_all_stdin(void)
{
	size_t cap = 4096, len = 0;
	char *buf = malloc(cap);
	if (!buf)
		return NULL;

	size_t n;
	while ((n = fread(buf + len, 1, cap - len, stdin)) > 0) {
		len += n;
		if (len == cap) {
			char *grown = realloc(buf, cap * 2);
			if (!grown) {
				free(buf);
				return NULL;
			}
			buf = grown;
			cap *= 2;
		}
	}
	if (ferror(stdin)) {
		free(buf);
		return NULL;
	}

	if (len == cap) {
		char *grown = realloc(buf, cap + 1);
		if (!grown) {
			free(buf);
			return NULL;
		}
		buf = grown;
	}
	buf[len] = '\0';
	return buf;
}

/* Parse the query, reporting any error to stderr. Returns the tree or NULL. */
static Query *parse_or_report(const char *query)
{
	Query *q = NULL;
	char *err = NULL;

	if (cypher_parse(query, &q, &err) != 0) {
		fprintf(stderr, "%s: %s\n", PROG, err ? err : "parse error");
		free(err);
		return NULL;
	}
	return q;
}

/*
 * Build the explicit name map from the --names / --names-file options (at most
 * one may be given). Returns 0 with *out set (possibly NULL when neither option
 * was used), or a nonzero process exit code after reporting the error.
 */
static int build_explicit_map(const char *spec, const char *file, NameMap **out)
{
	*out = NULL;
	char *err = NULL;
	if (spec && file) {
		fprintf(stderr,
			"%s: specify at most one of --names / --names-file\n", PROG);
		return 2;
	}
	if (spec) {
		if (names_parse(spec, out, &err) != 0) {
			fprintf(stderr, "%s: %s\n", PROG,
				err ? err : "invalid name map");
			free(err);
			return 1;
		}
	} else if (file) {
		if (names_parse_file(file, out, &err) != 0) {
			fprintf(stderr, "%s: %s\n", PROG,
				err ? err : "invalid name map file");
			free(err);
			return 1;
		}
	}
	return 0;
}

/*
 * Read the flat schema from stdin, parse QUERY, translate it to SQL against
 * that schema (resolving labels through map), and print the SQL. Returns a
 * process exit code.
 */
static int run_transpile(const char *query, const NameMap *map)
{
	char *schema = read_all_stdin();
	if (!schema) {
		fprintf(stderr, "%s: cannot read schema from stdin\n", PROG);
		return 1;
	}

	Catalog *cat = NULL;
	char *err = NULL;
	if (catalog_from_schema(schema, &cat, &err) != 0) {
		fprintf(stderr, "%s: %s\n", PROG, err ? err : "cannot read schema");
		free(err);
		free(schema);
		return 1;
	}
	free(schema);

	Query *q = parse_or_report(query);
	if (!q) {
		catalog_free(cat);
		return 1;
	}

	char *sql = NULL;
	int status = 0;
	if (transform_query(q, cat, map, &sql, &err) != 0) {
		fprintf(stderr, "%s: %s\n", PROG, err ? err : "cannot translate query");
		status = 1;
	} else {
		printf("%s\n", sql);
	}

	free(sql);
	free(err);
	ast_free_query(q);
	catalog_free(cat);
	return status;
}

int main(int argc, char **argv)
{
	int ast_mode = 0;
	const char *names_spec = NULL;
	const char *names_file = NULL;
	const char *query = NULL;
	int have_query = 0;

	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
			usage(stdout);
			return 0;
		} else if (strcmp(argv[i], "--ast") == 0) {
			ast_mode = 1;
		} else if (strcmp(argv[i], "--names") == 0
				|| strcmp(argv[i], "--names-file") == 0) {
			if (i + 1 >= argc) {
				fprintf(stderr, "%s: %s expects an argument\n",
					PROG, argv[i]);
				usage(stderr);
				return 2;
			}
			if (argv[i][7] == '\0') /* --names */
				names_spec = argv[++i];
			else                    /* --names-file */
				names_file = argv[++i];
		} else if (!have_query) {
			query = argv[i];
			have_query = 1;
		} else {
			fprintf(stderr, "%s: unexpected extra argument: %s\n",
				PROG, argv[i]);
			usage(stderr);
			return 2;
		}
	}

	if (!have_query) {
		fprintf(stderr, "%s: expected a Cypher statement\n", PROG);
		usage(stderr);
		return 2;
	}

	/* --ast: parse a single statement and dump the tree; no schema, no map. */
	if (ast_mode) {
		Query *q = parse_or_report(query);
		if (!q)
			return 1;
		ast_dump(stdout, q);
		ast_free_query(q);
		return 0;
	}

	/* Default: transpile QUERY against the flat schema on stdin. */
	NameMap *map = NULL;
	int mrc = build_explicit_map(names_spec, names_file, &map);
	if (mrc)
		return mrc;
	int rc = run_transpile(query, map);
	names_free(map);
	return rc;
}
