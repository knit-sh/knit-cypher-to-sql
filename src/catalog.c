/*
 * catalog.c -- read a provenance database's schema into a Catalog.
 */

#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include "catalog.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>   /* strcasecmp */

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

static void set_err(char **errmsg, const char *msg)
{
	if (errmsg && *errmsg == NULL)
		*errmsg = xstrdup(msg);
}

/* Append one column name to a table's growable column array. */
static void table_add_column(CatalogTable *t, const char *col)
{
	char **grown = realloc(t->columns, (t->ncolumns + 1) * sizeof(*grown));
	if (!grown) {
		fprintf(stderr, "knit-cypher-to-sql: out of memory\n");
		exit(1);
	}
	t->columns = grown;
	t->columns[t->ncolumns++] = xstrdup(col);
}

/* Free the strings a CatalogTable owns (not the struct itself). */
static void free_table_contents(CatalogTable *t)
{
	for (int j = 0; j < t->ncolumns; j++)
		free(t->columns[j]);
	free(t->columns);
	free(t->name);
}

/* Append a table (name only; columns filled in by the caller). */
static CatalogTable *catalog_add_table(Catalog *cat, const char *name)
{
	CatalogTable *grown =
		realloc(cat->tables, (cat->ntables + 1) * sizeof(*grown));
	if (!grown) {
		fprintf(stderr, "knit-cypher-to-sql: out of memory\n");
		exit(1);
	}
	cat->tables = grown;
	CatalogTable *t = &cat->tables[cat->ntables++];
	t->name = xstrdup(name);
	t->columns = NULL;
	t->ncolumns = 0;
	return t;
}

/* Non-zero if the table has a column named "id" (case-insensitive). */
static int table_has_id(const CatalogTable *t)
{
	for (int j = 0; j < t->ncolumns; j++) {
		if (strcasecmp(t->columns[j], "id") == 0)
			return 1;
	}
	return 0;
}

int catalog_from_schema(const char *schema, Catalog **out, char **errmsg)
{
	*out = NULL;
	if (errmsg)
		*errmsg = NULL;

	Catalog *cat = calloc(1, sizeof(*cat));
	if (!cat) {
		set_err(errmsg, "out of memory");
		return 1;
	}

	/* Parse a mutable copy line by line, splitting each at the first tab into
	 * a table name and its comma-separated column list. */
	char *copy = xstrdup(schema ? schema : "");
	char *line = copy;
	while (*line) {
		char *nl = strchr(line, '\n');
		if (nl)
			*nl = '\0';

		if (line[0] != '\0') {          /* skip blank lines */
			char *tab = strchr(line, '\t');
			char *cols = NULL;
			if (tab) {
				*tab = '\0';
				cols = tab + 1;
			}
			CatalogTable *t = catalog_add_table(cat, line);
			for (char *c = cols; c && *c; ) {
				char *comma = strchr(c, ',');
				if (comma)
					*comma = '\0';
				if (*c != '\0')
					table_add_column(t, c);
				if (!comma)
					break;
				c = comma + 1;
			}
		}

		if (!nl)
			break;
		line = nl + 1;
	}
	free(copy);

	/* Keep only graph tables: the edge table, or a table with an "id" column.
	 * The kept tables are compacted to the front of the array in place. */
	int nkept = 0;
	for (int i = 0; i < cat->ntables; i++) {
		CatalogTable *t = &cat->tables[i];
		if (table_has_id(t) || strcmp(t->name, KG_EDGE_TABLE) == 0) {
			if (nkept != i)
				cat->tables[nkept] = *t;
			nkept++;
		} else {
			free_table_contents(t);
		}
	}
	cat->ntables = nkept;

	*out = cat;
	return 0;
}

void catalog_free(Catalog *cat)
{
	if (!cat)
		return;
	for (int i = 0; i < cat->ntables; i++)
		free_table_contents(&cat->tables[i]);
	free(cat->tables);
	free(cat);
}

const CatalogTable *catalog_find_table(const Catalog *cat, const char *name)
{
	if (!cat || !name)
		return NULL;
	for (int i = 0; i < cat->ntables; i++) {
		if (strcmp(cat->tables[i].name, name) == 0)
			return &cat->tables[i];
	}
	return NULL;
}

int catalog_table_has_column(const CatalogTable *t, const char *column)
{
	if (!t || !column)
		return 0;
	for (int j = 0; j < t->ncolumns; j++) {
		if (strcmp(t->columns[j], column) == 0)
			return 1;
	}
	return 0;
}
