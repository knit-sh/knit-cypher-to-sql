#!/bin/sh
# transpile.sh -- assert the SQL produced by the schema-on-stdin transpile path
# (one positional argument, no database). The flat schema drives label/column
# resolution, so the generated SQL must match the DB-backed --explain path byte
# for byte, and unknown labels/columns must be reported. Needs no sqlite3 CLI.

: "${KG:?KG must point at the knit-cypher-to-sql binary}"

# The flat schema (§5): one line per table, a tab separating the name from a
# comma-separated column list. "kv" has no "id" column, so it is not a node
# table and must be dropped -- referencing it is an unknown table.
schemafile="transpile_schema.txt"
printf 'ns:f\tid,x,y\nns2:g\tid,z\nkv\tkey,value\n__provenance__\tsource_id,source_name,target_id,target_name,edge_type,start_time,end_time,alias\n' \
	> "$schemafile"

fail=0

# expect QUERY EXPECTED-SQL: the SQL transpiled from QUERY (schema on stdin)
# must match exactly.
expect() {
	got=$("$KG" "$1" < "$schemafile" 2>&1)
	if [ "$got" != "$2" ]; then
		echo "FAIL: $1"
		echo "  expected: $2"
		echo "  got:      $got"
		fail=1
	fi
}

# expectm MAP QUERY EXPECTED-SQL: like expect, with a --names map.
expectm() {
	got=$("$KG" --names "$1" "$2" < "$schemafile" 2>&1)
	if [ "$got" != "$3" ]; then
		echo "FAIL: $2"
		echo "  expected: $3"
		echo "  got:      $got"
		fail=1
	fi
}

# expecth QUERY <<'EOF' ... EOF: like expect, but the expected SQL comes from a
# quoted heredoc (the schema is read from the file, so the heredoc is free to
# use the function's stdin).
expecth() {
	exp=$(cat)
	got=$("$KG" "$1" < "$schemafile" 2>&1)
	if [ "$got" != "$exp" ]; then
		echo "FAIL: $1"
		echo "  expected: $exp"
		echo "  got:      $got"
		fail=1
	fi
}

# reject QUERY: transpilation must fail with a non-zero exit.
reject() {
	if "$KG" "$1" < "$schemafile" >/dev/null 2>&1; then
		echo "FAIL: should have been rejected: $1"
		fail=1
	fi
}

# --- A representative slice of every generated-SQL shape, proving the flat
# schema resolves labels/columns exactly as the DB catalog does. ---

# Single node, property and alias.
expect 'MATCH (a:`ns:f`) RETURN a.x' \
	'SELECT a."x" FROM "ns:f" a'
expect 'MATCH (a:`ns:f`) RETURN a.x AS ex, a.y' \
	'SELECT a."x" AS "ex", a."y" FROM "ns:f" a'

# Relationship, reversed relationship, and a relationship property.
expect 'MATCH (a:`ns:f`)-[r:calls]->(b:`ns2:g`) RETURN b.id' \
	'SELECT b."id" FROM "__provenance__" r JOIN "ns2:g" b ON b."id" = r."target_id" WHERE r."edge_type" = '"'"'calls'"'"' AND r."source_name" = '"'"'ns:f'"'"' AND r."target_name" = '"'"'ns2:g'"'"''
expect 'MATCH (a:`ns:f`)<-[r:calls]-(b:`ns2:g`) RETURN b.id' \
	'SELECT b."id" FROM "__provenance__" r JOIN "ns2:g" b ON b."id" = r."source_id" WHERE r."edge_type" = '"'"'calls'"'"' AND r."source_name" = '"'"'ns2:g'"'"' AND r."target_name" = '"'"'ns:f'"'"''
expect 'MATCH (a:`ns:f`)-[r:calls]->(b:`ns2:g`) RETURN r.alias' \
	'SELECT r."alias" FROM "__provenance__" r WHERE r."edge_type" = '"'"'calls'"'"' AND r."source_name" = '"'"'ns:f'"'"' AND r."target_name" = '"'"'ns2:g'"'"''

# WHERE: comparison + AND, IN, IS NOT NULL, STARTS WITH.
expect 'MATCH (a:`ns:f`) WHERE a.x >= 1 AND a.x < 5 RETURN a.x' \
	'SELECT a."x" FROM "ns:f" a WHERE (a."x" >= 1 AND a."x" < 5)'
expect 'MATCH (a:`ns:f`) WHERE a.x IN [1, 2, 3] RETURN a.x' \
	'SELECT a."x" FROM "ns:f" a WHERE a."x" IN (1, 2, 3)'
expect 'MATCH (a:`ns:f`) WHERE a.y IS NOT NULL RETURN a.y' \
	'SELECT a."y" FROM "ns:f" a WHERE a."y" IS NOT NULL'
expect 'MATCH (a:`ns:f`) WHERE a.y STARTS WITH "a" RETURN a.y' \
	'SELECT a."y" FROM "ns:f" a WHERE a."y" LIKE '"'"'a%'"'"' ESCAPE '"'"'\'"'"''

# Chain, undirected hop, comma-separated patterns.
expect 'MATCH (a:`ns:f`), (b:`ns2:g`) RETURN a.id, b.id' \
	'SELECT a."id", b."id" FROM "ns:f" a JOIN "ns2:g" b ON 1 = 1'
expect 'MATCH (a:`ns2:g`)-[r:calls]-(b:`ns:f`) RETURN a.id, b.id' \
	'SELECT a."id", b."id" FROM "__provenance__" r JOIN "ns2:g" a ON 1 = 1 JOIN "ns:f" b ON 1 = 1 WHERE r."edge_type" = '"'"'calls'"'"' AND (r."source_id" = a."id" AND r."source_name" = '"'"'ns2:g'"'"' AND r."target_id" = b."id" AND r."target_name" = '"'"'ns:f'"'"' OR r."target_id" = a."id" AND r."target_name" = '"'"'ns2:g'"'"' AND r."source_id" = b."id" AND r."source_name" = '"'"'ns:f'"'"')'

# Aggregation (GROUP BY implied), collect, DISTINCT, ORDER BY + SKIP/LIMIT.
expect 'MATCH (a:`ns:f`)-[r:calls]->(b:`ns2:g`) RETURN b.id, count(*) AS n' \
	'SELECT b."id", count(*) AS "n" FROM "__provenance__" r JOIN "ns2:g" b ON b."id" = r."target_id" WHERE r."edge_type" = '"'"'calls'"'"' AND r."source_name" = '"'"'ns:f'"'"' AND r."target_name" = '"'"'ns2:g'"'"' GROUP BY b."id"'
expect 'MATCH (a:`ns:f`) RETURN collect(a.id) AS ids' \
	'SELECT json_group_array(a."id") AS "ids" FROM "ns:f" a'
expect 'MATCH (a:`ns:f`) RETURN DISTINCT a.y' \
	'SELECT DISTINCT a."y" FROM "ns:f" a'
expect 'MATCH (a:`ns:f`) RETURN a.x ORDER BY a.x SKIP 1 LIMIT 2' \
	'SELECT a."x" FROM "ns:f" a ORDER BY a."x" LIMIT 2 OFFSET 1'

# Variable-length path -> recursive CTE.
expecth 'MATCH (a:`ns:f`)-[:calls*1..3]->(b:`ns2:g`) RETURN a.id, b.id' <<'EOF'
WITH RECURSIVE "walk"(source_id, source_name, target_id, target_name, depth, path) AS (SELECT e."source_id", e."source_name", e."target_id", e."target_name", 1, '/' || e.rowid || '/' FROM "__provenance__" e WHERE e."edge_type" = 'calls' UNION ALL SELECT w."source_id", w."source_name", e."target_id", e."target_name", w."depth" + 1, w."path" || e.rowid || '/' FROM "walk" w JOIN "__provenance__" e ON e."source_id" = w."target_id" AND e."source_name" = w."target_name" WHERE e."edge_type" = 'calls' AND w."depth" < 3 AND w."path" NOT LIKE '%/' || e.rowid || '/%') SELECT a."id", b."id" FROM "walk" r JOIN "ns:f" a ON a."id" = r."source_id" JOIN "ns2:g" b ON b."id" = r."target_id" WHERE r."source_name" = 'ns:f' AND r."target_name" = 'ns2:g'
EOF

# Whole-node RETURN expands to a json_object over the schema's columns in order.
expecth 'MATCH (a:`ns:f`) RETURN a' <<'EOF'
SELECT json_object('id', a."id", 'x', a."x", 'y', a."y") AS "a" FROM "ns:f" a
EOF

# --- Name map: both the command-name and table-name spellings resolve. ---
expectm 'ns:f=fnode' 'MATCH (a:fnode)-[:calls]->(b:`ns2:g`) RETURN b.id' \
	'SELECT b."id" FROM "__provenance__" r JOIN "ns2:g" b ON b."id" = r."target_id" WHERE r."edge_type" = '"'"'calls'"'"' AND r."source_name" = '"'"'fnode'"'"' AND r."target_name" = '"'"'ns2:g'"'"''
expectm 'ns:f=fnode' 'MATCH (a:`ns:f`)-[:calls]->(b:`ns2:g`) RETURN b.id' \
	'SELECT b."id" FROM "__provenance__" r JOIN "ns2:g" b ON b."id" = r."target_id" WHERE r."edge_type" = '"'"'calls'"'"' AND r."source_name" = '"'"'fnode'"'"' AND r."target_name" = '"'"'ns2:g'"'"''

# --- Validation against the flat schema: unknown label/column and parse error
# are all reported (non-zero exit). "kv" has no id column, so it was dropped. ---
reject 'MATCH (a:`ns:f`) RETURN a.nope'      # unknown column
reject 'MATCH (a:`nope:x`) RETURN a.id'      # unknown table
reject 'MATCH (a:kv) RETURN a.key'           # non-node table (no id) => unknown
reject 'MATCH (a) RETURN a.x'                # node has no label
reject 'MATCH (a:`ns:f`) RETRUN a.x'         # parse error

rm -f "$schemafile"
exit $fail
