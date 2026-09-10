# knit-cypher-to-sql

[![CI](https://github.com/knit-sh/knit-cypher-to-sql/actions/workflows/ci.yml/badge.svg)](https://github.com/knit-sh/knit-cypher-to-sql/actions/workflows/ci.yml)
[![Code coverage](https://github.com/knit-sh/knit-cypher-to-sql/actions/workflows/coverage.yml/badge.svg)](https://github.com/knit-sh/knit-cypher-to-sql/actions/workflows/coverage.yml)
[![codecov](https://codecov.io/gh/knit-sh/knit-cypher-to-sql/branch/main/graph/badge.svg)](https://codecov.io/gh/knit-sh/knit-cypher-to-sql)

A standalone C program that translates a read-only [Cypher](https://opencypher.org/) statement into
SQL for a Knit **provenance** database — so graph-shaped questions can be asked in graph syntax while
all storage and execution stay in SQLite.

knit-cypher-to-sql is a **pure transpiler**: it never opens a database and never runs a query. It
reads a compact text description of the schema on stdin, validates the statement's labels and columns
against it, and prints the SQL. The Knit framework runs the returned SQL itself. This keeps the
program dependency-free — it links nothing beyond the C library.

It is inspired by [graphqlite](https://github.com/dpapathanasiou/graphqlite): it reuses the ideas — a
Cypher→SQL transpiler pipeline and backtick-quoted labels — but is an independent implementation with
its own compact parser and a transformer specialised to the fixed provenance schema below.

## The provenance schema

knit-cypher-to-sql targets one specific shape of database:

- **Node tables** — one per function, named e.g. `` `ns:f` `` (namespaces separated by colons). The
  columns are the function's arguments and return values, plus an `id` column holding a uuid7 that
  identifies a single call.
- **Edge table** — a single `__provenance__` table with columns `source_id, source_name, target_id,
  target_name, edge_type, start_time, end_time, alias`. One row per relationship (e.g. `f` *calls*
  `g`): `*_name` is the peer's table name, `*_id` its uuid, and `alias` disambiguates repeated calls
  (`NULL` by default).

Only read queries are translated; write Cypher clauses are rejected.

### Schema input

The transpiler learns the schema from stdin: one line per table, a tab separating the table name from
a comma-separated column list. The form is type-free — a table is a **node** table if it has a column
named `id`, and the **edge** table is the one named `__provenance__`:

```
ns:f<TAB>id,x,y
ns2:g<TAB>id,z
__provenance__<TAB>source_id,source_name,target_id,target_name,edge_type,start_time,end_time,alias
```

## Building

### Building from git

```sh
autoreconf -i
mkdir build && cd build
../configure
make
```

Build dependencies: a C compiler, autoconf, automake, bison, and flex. No libtool and **no SQLite
development files** — the transpiler links nothing from SQLite. These apply to the **git checkout**,
where the parser/scanner are regenerated from `cypher_parser.y` / `cypher_scanner.l`.

### Building from a release tarball

A `make dist` tarball already contains the generated parser and scanner (`cypher_parser.c`,
`cypher_parser.h`, `cypher_scanner.c`), so building it needs **only a C compiler** — autotools,
bison, and flex are *not* required:

```sh
tar xzf knit-cypher-to-sql-0.1.0.tar.gz && cd knit-cypher-to-sql-0.1.0
mkdir build && cd build
../configure
make
make install
```

## Usage

```
knit-cypher-to-sql [--names SPEC | --names-file FILE] 'CYPHER'   # schema on stdin -> SQL
knit-cypher-to-sql --ast 'CYPHER'                                # print the syntax tree
```

Modes:

| Mode           | Effect                                                          |
|----------------|----------------------------------------------------------------|
| (default)      | translate `CYPHER` to SQL against the schema on stdin, print it |
| `--ast`        | parse only and print the syntax tree (no schema)               |
| `-h`, `--help` | show usage                                                      |

### Label resolution (name map)

A Cypher node label serves two purposes against the provenance schema: it names the table to JOIN
and it supplies the value a `source_name`/`target_name` edge filter matches. knit-cypher-to-sql assumes both
equal the label, which holds for a plain function table. But a Knit *override* command records its
command name in `*_name` while its rows live in a differently named table (e.g. the `submit` command
writes `jobs`). A **name map** bridges the two — each entry pairs a table name with the recorded name
its edges carry — and is read both ways, so a label may be written as either spelling:

```
--names SPEC         map entries `table=name`, separated by newlines or `;`
--names-file FILE     read the same map from FILE
```

With a map of `jobs=submit`, both `(:jobs)` and `(:submit)` resolve to a JOIN on `jobs` filtered by
`*_name = 'submit'`. A label that is a table name for one command and a command name for a *different*
command is genuinely ambiguous and is reported as an error rather than guessed. A label absent from
the map (or when no map is given) resolves to itself, so the default behaviour is unchanged. `knit
query` in Knit builds this map live from the experiment's registered commands and passes it on every
invocation.

### Examples

```sh
# The five most-called ns2:g targets. The schema is piped on stdin.
schema='ns:f	id,x,y
ns2:g	id,z
__provenance__	source_id,source_name,target_id,target_name,edge_type,start_time,end_time,alias'

printf '%s' "$schema" | knit-cypher-to-sql \
  "MATCH (a:\`ns:f\`)-[:calls]->(b:\`ns2:g\`) RETURN b.id, count(*) AS n ORDER BY n DESC LIMIT 5"

# A whole node expands to a JSON object over its columns.
printf '%s' "$schema" | knit-cypher-to-sql "MATCH (a:\`ns:f\`) RETURN a"

# --ast needs no schema.
knit-cypher-to-sql --ast "MATCH (a:\`ns:f\`)-[:calls*1..3]->(b:\`ns2:g\`) RETURN b.id"
```

## Supported Cypher (read subset)

knit-cypher-to-sql is specifically designed for the needs of the Knit framework, hence it only implements a subset of Cypher that it needs (namely, read operations).

- `MATCH` / `WHERE` / `RETURN`, `ORDER BY`, `SKIP`, `LIMIT`, `DISTINCT`
- Patterns: single node, relationship with direction (`->`, `<-`) or undirected (`--`), multi-hop
  chains, comma-separated patterns, and variable-length paths (`-[:calls*1..3]->`, `*`, `*m..`),
  compiled to a recursive CTE. The relationship type is optional — `-->` (or `-[r]->`) matches an
  edge of any type, dropping the `edge_type` filter from the generated SQL
- `WHERE`: `= <> < > <= >=`, `AND` / `OR` / `NOT`, `IN […]`, `IS [NOT] NULL`,
  `STARTS WITH` / `ENDS WITH` / `CONTAINS` (→ `LIKE`)
- Aggregation: `count`, `collect` (→ `json_group_array`), `sum`, `avg`, `min`, `max`, with implicit
  `GROUP BY` on the non-aggregated `RETURN` items
- `RETURN a` / `RETURN r` expand a whole node/relationship to a `json_object(...)` of its columns
- Inline relationship property maps: `-[{alias:'fast'}]->` lowers to the same `edge.alias = 'fast'`
  predicate as the `WHERE` form (each key must be an edge column and each value a literal). Supported
  on directed and undirected single hops; not on variable-length relationships

Write clauses (`CREATE`, `MERGE`, `SET`, `DELETE`, `REMOVE`, `FOREACH`, `LOAD CSV`, …) are rejected
with a clear error and a nonzero exit.

## Testing

```sh
make check        # from the build directory; runs the automake TESTS
```

The suite (in `tests/`) covers parsing (valid/invalid batteries, AST golden files), golden
Cypher→SQL pairs driven by a schema on stdin (including label/column validation and error cases), the
name map, and a `valgrind` leak check. The tests need no database — only the `valgrind` check is
skipped gracefully when that tool is absent.

## Coverage

Configure with `--enable-coverage` to build instrumented objects:

```sh
mkdir build && cd build && ../configure --enable-coverage && make && make check
```

In CI, the [Code coverage workflow](.github/workflows/coverage.yml) runs `coverage.sh` to produce an
`lcov` report and uploads that `.info` file to [Codecov](https://codecov.io) (rather than relying on
Codecov's own gcov discovery, which does not handle this out-of-tree autotools build). The generated
bison/flex sources are excluded from the report; [`codecov.yml`](codecov.yml) keeps a redundant
exclusion and enforces the project/patch targets there.

The same `coverage.sh` gives a quick local report without Codecov: it captures line coverage with
`lcov`, applies those exclusions, prints a summary, writes a browsable report to
`BUILDDIR/coverage-html/` (when `genhtml` is present), and fails below a threshold:

```sh
./coverage.sh build 80                 # BUILDDIR THRESHOLD%
```

## License

MIT — see [LICENSE](LICENSE).
