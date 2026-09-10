#!/bin/sh
# transpile.sh -- assert the SQL the transpiler generates for every supported
# Cypher shape, driven by the flat schema on stdin (one positional argument, no
# database). The schema resolves labels and validates columns, so the generated
# SQL must match exactly and unknown labels/columns must be reported. Needs no
# sqlite3 CLI -- the transpiler opens no database.

: "${KG:?KG must point at the knit-cypher-to-sql binary}"

# The flat schema (§5): one line per table, a tab separating the name from a
# comma-separated column list. "kv" has no "id" column, so it is not a node
# table and must be dropped -- referencing it is an unknown table.
schemafile="transpile_schema.txt"
printf 'ns:f\tid,x,y\nns2:g\tid,z\nkv\tkey,value\n__provenance__\tsource_id,source_name,target_id,target_name,edge_type,start_time,end_time,alias\n' \
	> "$schemafile"

fail=0

# expect QUERY EXPECTED-SQL: the generated SQL must match exactly.
expect() {
	got=$("$KG" "$1" < "$schemafile" 2>&1)
	if [ "$got" != "$2" ]; then
		echo "FAIL: $1"
		echo "  expected: $2"
		echo "  got:      $got"
		fail=1
	fi
}

# reject QUERY: translation must fail with a non-zero exit.
reject() {
	if "$KG" "$1" < "$schemafile" >/dev/null 2>&1; then
		echo "FAIL: should have been rejected: $1"
		fail=1
	fi
}

# expectm MAP QUERY EXPECTED-SQL: like expect, but the query is translated with
# the name map MAP (--names). rejectm MAP QUERY: like reject, with a map.
expectm() {
	got=$("$KG" --names "$1" "$2" < "$schemafile" 2>&1)
	if [ "$got" != "$3" ]; then
		echo "FAIL: $2"
		echo "  expected: $3"
		echo "  got:      $got"
		fail=1
	fi
}
rejectm() {
	if "$KG" --names "$1" "$2" < "$schemafile" >/dev/null 2>&1; then
		echo "FAIL: should have been rejected: $2"
		fail=1
	fi
}

# expecth QUERY <<'EOF' ... EOF : like expect, but the expected SQL is read from
# a quoted heredoc (the schema is read from the file, so the function's stdin is
# free for the heredoc). Command substitution trims the heredoc's trailing
# newline, matching the trim applied to the captured output.
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

# Single node.
expect 'MATCH (a:`ns:f`) RETURN a.x' \
	'SELECT a."x" FROM "ns:f" a'
expect 'MATCH (a:`ns:f`) RETURN a.x AS ex, a.y' \
	'SELECT a."x" AS "ex", a."y" FROM "ns:f" a'

# Single relationship: the edge table drives the FROM; the returned node joins
# back; both endpoints contribute source_name/target_name predicates.
expect 'MATCH (a:`ns:f`)-[r:calls]->(b:`ns2:g`) RETURN b.id' \
	'SELECT b."id" FROM "__provenance__" r JOIN "ns2:g" b ON b."id" = r."target_id" WHERE r."edge_type" = '"'"'calls'"'"' AND r."source_name" = '"'"'ns:f'"'"' AND r."target_name" = '"'"'ns2:g'"'"''

# Reversed relationship: '<-' swaps the source and target roles.
expect 'MATCH (a:`ns:f`)<-[r:calls]-(b:`ns2:g`) RETURN b.id' \
	'SELECT b."id" FROM "__provenance__" r JOIN "ns2:g" b ON b."id" = r."source_id" WHERE r."edge_type" = '"'"'calls'"'"' AND r."source_name" = '"'"'ns2:g'"'"' AND r."target_name" = '"'"'ns:f'"'"''

# A relationship property resolves to the edge table; no join is needed for it.
expect 'MATCH (a:`ns:f`)-[r:calls]->(b:`ns2:g`) RETURN r.alias' \
	'SELECT r."alias" FROM "__provenance__" r WHERE r."edge_type" = '"'"'calls'"'"' AND r."source_name" = '"'"'ns:f'"'"' AND r."target_name" = '"'"'ns2:g'"'"''

# WHERE: boolean expressions ANDed onto the pattern predicates.
expect 'MATCH (a:`ns:f`) WHERE a.x >= 1 AND a.x < 5 RETURN a.x' \
	'SELECT a."x" FROM "ns:f" a WHERE (a."x" >= 1 AND a."x" < 5)'
expect 'MATCH (a:`ns:f`) WHERE a.x = 1 OR a.x = 2 RETURN a.x' \
	'SELECT a."x" FROM "ns:f" a WHERE (a."x" = 1 OR a."x" = 2)'
expect 'MATCH (a:`ns:f`) WHERE NOT a.x = 2 RETURN a.x' \
	'SELECT a."x" FROM "ns:f" a WHERE (NOT a."x" = 2)'
expect 'MATCH (a:`ns:f`) WHERE a.x IN [1, 2, 3] RETURN a.x' \
	'SELECT a."x" FROM "ns:f" a WHERE a."x" IN (1, 2, 3)'
expect 'MATCH (a:`ns:f`) WHERE a.y IS NOT NULL RETURN a.y' \
	'SELECT a."y" FROM "ns:f" a WHERE a."y" IS NOT NULL'
expect 'MATCH (a:`ns:f`) WHERE a.y STARTS WITH "a" RETURN a.y' \
	'SELECT a."y" FROM "ns:f" a WHERE a."y" LIKE '"'"'a%'"'"' ESCAPE '"'"'\'"'"''
expect 'MATCH (a:`ns:f`) WHERE a.y CONTAINS "a_b" RETURN a.y' \
	'SELECT a."y" FROM "ns:f" a WHERE a."y" LIKE '"'"'%a\_b%'"'"' ESCAPE '"'"'\'"'"''
expect 'MATCH (a:`ns:f`)-[r:calls]->(b:`ns2:g`) WHERE r.alias IS NULL RETURN a.id' \
	'SELECT a."id" FROM "__provenance__" r JOIN "ns:f" a ON a."id" = r."source_id" WHERE r."edge_type" = '"'"'calls'"'"' AND r."source_name" = '"'"'ns:f'"'"' AND r."target_name" = '"'"'ns2:g'"'"' AND r."alias" IS NULL'
expect 'MATCH (a:`ns:f`)-[r:calls]->(b:`ns2:g`) WHERE b.z > 1 RETURN a.id' \
	'SELECT a."id" FROM "__provenance__" r JOIN "ns:f" a ON a."id" = r."source_id" JOIN "ns2:g" b ON b."id" = r."target_id" WHERE r."edge_type" = '"'"'calls'"'"' AND r."source_name" = '"'"'ns:f'"'"' AND r."target_name" = '"'"'ns2:g'"'"' AND b."z" > 1'

# Chains, undirected & multi-pattern MATCH.
expect 'MATCH (a:`ns:f`)-[r1:calls]->(b:`ns2:g`)-[r2:wraps]->(c:`ns:f`) RETURN a.id, c.id' \
	'SELECT a."id", c."id" FROM "__provenance__" r1 JOIN "__provenance__" r2 ON r2."source_id" = r1."target_id" AND r2."source_name" = r1."target_name" JOIN "ns:f" a ON a."id" = r1."source_id" JOIN "ns:f" c ON c."id" = r2."target_id" WHERE r1."edge_type" = '"'"'calls'"'"' AND r1."source_name" = '"'"'ns:f'"'"' AND r1."target_name" = '"'"'ns2:g'"'"' AND r2."edge_type" = '"'"'wraps'"'"' AND r2."source_name" = '"'"'ns2:g'"'"' AND r2."target_name" = '"'"'ns:f'"'"''
expect 'MATCH (a:`ns2:g`)-[r:calls]-(b:`ns:f`) RETURN a.id, b.id' \
	'SELECT a."id", b."id" FROM "__provenance__" r JOIN "ns2:g" a ON 1 = 1 JOIN "ns:f" b ON 1 = 1 WHERE r."edge_type" = '"'"'calls'"'"' AND (r."source_id" = a."id" AND r."source_name" = '"'"'ns2:g'"'"' AND r."target_id" = b."id" AND r."target_name" = '"'"'ns:f'"'"' OR r."target_id" = a."id" AND r."target_name" = '"'"'ns2:g'"'"' AND r."source_id" = b."id" AND r."source_name" = '"'"'ns:f'"'"')'
expect 'MATCH (a:`ns:f`), (b:`ns2:g`) RETURN a.id, b.id' \
	'SELECT a."id", b."id" FROM "ns:f" a JOIN "ns2:g" b ON 1 = 1'
expect 'MATCH (a:`ns:f`)--(b:`ns2:g`) RETURN a.id' \
	'SELECT a."id" FROM "__provenance__" r JOIN "ns:f" a ON 1 = 1 WHERE (r."source_id" = a."id" AND r."source_name" = '"'"'ns:f'"'"' AND r."target_name" = '"'"'ns2:g'"'"' OR r."target_id" = a."id" AND r."target_name" = '"'"'ns:f'"'"' AND r."source_name" = '"'"'ns2:g'"'"')'

# Aggregation, DISTINCT, ORDER BY, SKIP, LIMIT.
expect 'MATCH (a:`ns:f`)-[r:calls]->(b:`ns2:g`) RETURN b.id, count(*) AS n' \
	'SELECT b."id", count(*) AS "n" FROM "__provenance__" r JOIN "ns2:g" b ON b."id" = r."target_id" WHERE r."edge_type" = '"'"'calls'"'"' AND r."source_name" = '"'"'ns:f'"'"' AND r."target_name" = '"'"'ns2:g'"'"' GROUP BY b."id"'
expect 'MATCH (a:`ns:f`) RETURN a.y, count(a.x) AS n ORDER BY n DESC LIMIT 5' \
	'SELECT a."y", count(a."x") AS "n" FROM "ns:f" a GROUP BY a."y" ORDER BY "n" DESC LIMIT 5'
expect 'MATCH (a:`ns:f`) RETURN DISTINCT a.y' \
	'SELECT DISTINCT a."y" FROM "ns:f" a'
expect 'MATCH (a:`ns:f`) RETURN collect(a.id) AS ids' \
	'SELECT json_group_array(a."id") AS "ids" FROM "ns:f" a'
expect 'MATCH (a:`ns:f`) RETURN count(DISTINCT a.y) AS n' \
	'SELECT count(DISTINCT a."y") AS "n" FROM "ns:f" a'
expect 'MATCH (a:`ns:f`) RETURN a.x ORDER BY a.x SKIP 1 LIMIT 2' \
	'SELECT a."x" FROM "ns:f" a ORDER BY a."x" LIMIT 2 OFFSET 1'
expect 'MATCH (a:`ns:f`) RETURN a.x SKIP 1' \
	'SELECT a."x" FROM "ns:f" a LIMIT -1 OFFSET 1'

# Variable-length paths -> recursive CTE.
expecth 'MATCH (a:`ns:f`)-[:calls*1..3]->(b:`ns2:g`) RETURN a.id, b.id' <<'EOF'
WITH RECURSIVE "walk"(source_id, source_name, target_id, target_name, depth, path) AS (SELECT e."source_id", e."source_name", e."target_id", e."target_name", 1, '/' || e.rowid || '/' FROM "__provenance__" e WHERE e."edge_type" = 'calls' UNION ALL SELECT w."source_id", w."source_name", e."target_id", e."target_name", w."depth" + 1, w."path" || e.rowid || '/' FROM "walk" w JOIN "__provenance__" e ON e."source_id" = w."target_id" AND e."source_name" = w."target_name" WHERE e."edge_type" = 'calls' AND w."depth" < 3 AND w."path" NOT LIKE '%/' || e.rowid || '/%') SELECT a."id", b."id" FROM "walk" r JOIN "ns:f" a ON a."id" = r."source_id" JOIN "ns2:g" b ON b."id" = r."target_id" WHERE r."source_name" = 'ns:f' AND r."target_name" = 'ns2:g'
EOF
expecth 'MATCH (a:`ns:f`)-[:calls*]->(b:`ns2:g`) RETURN b.id' <<'EOF'
WITH RECURSIVE "walk"(source_id, source_name, target_id, target_name, depth, path) AS (SELECT e."source_id", e."source_name", e."target_id", e."target_name", 1, '/' || e.rowid || '/' FROM "__provenance__" e WHERE e."edge_type" = 'calls' UNION ALL SELECT w."source_id", w."source_name", e."target_id", e."target_name", w."depth" + 1, w."path" || e.rowid || '/' FROM "walk" w JOIN "__provenance__" e ON e."source_id" = w."target_id" AND e."source_name" = w."target_name" WHERE e."edge_type" = 'calls' AND w."path" NOT LIKE '%/' || e.rowid || '/%') SELECT b."id" FROM "walk" r JOIN "ns2:g" b ON b."id" = r."target_id" WHERE r."source_name" = 'ns:f' AND r."target_name" = 'ns2:g'
EOF
expecth 'MATCH (a:`ns:f`)<-[:calls*2..4]-(b:`ns2:g`) RETURN a.id' <<'EOF'
WITH RECURSIVE "walk"(source_id, source_name, target_id, target_name, depth, path) AS (SELECT e."source_id", e."source_name", e."target_id", e."target_name", 1, '/' || e.rowid || '/' FROM "__provenance__" e WHERE e."edge_type" = 'calls' UNION ALL SELECT w."source_id", w."source_name", e."target_id", e."target_name", w."depth" + 1, w."path" || e.rowid || '/' FROM "walk" w JOIN "__provenance__" e ON e."source_id" = w."target_id" AND e."source_name" = w."target_name" WHERE e."edge_type" = 'calls' AND w."depth" < 4 AND w."path" NOT LIKE '%/' || e.rowid || '/%') SELECT a."id" FROM "walk" r JOIN "ns:f" a ON a."id" = r."target_id" WHERE r."source_name" = 'ns2:g' AND r."target_name" = 'ns:f' AND r."depth" >= 2
EOF
expecth 'MATCH (a:`ns:f`)-[:chain*..2]->(b:`ns:f`) WHERE a.id = "f1" RETURN b.id ORDER BY b.id' <<'EOF'
WITH RECURSIVE "walk"(source_id, source_name, target_id, target_name, depth, path) AS (SELECT e."source_id", e."source_name", e."target_id", e."target_name", 1, '/' || e.rowid || '/' FROM "__provenance__" e WHERE e."edge_type" = 'chain' UNION ALL SELECT w."source_id", w."source_name", e."target_id", e."target_name", w."depth" + 1, w."path" || e.rowid || '/' FROM "walk" w JOIN "__provenance__" e ON e."source_id" = w."target_id" AND e."source_name" = w."target_name" WHERE e."edge_type" = 'chain' AND w."depth" < 2 AND w."path" NOT LIKE '%/' || e.rowid || '/%') SELECT b."id" FROM "walk" r JOIN "ns:f" a ON a."id" = r."source_id" JOIN "ns:f" b ON b."id" = r."target_id" WHERE r."source_name" = 'ns:f' AND r."target_name" = 'ns:f' AND a."id" = 'f1' ORDER BY b."id"
EOF

# Whole node / relationship in RETURN: a bare variable expands to a json_object
# over the entity's columns in schema order, aliased to the variable name.
expecth 'MATCH (a:`ns:f`) RETURN a' <<'EOF'
SELECT json_object('id', a."id", 'x', a."x", 'y', a."y") AS "a" FROM "ns:f" a
EOF
expecth 'MATCH (a:`ns:f`)-[r:calls]->(b:`ns2:g`) RETURN r' <<'EOF'
SELECT json_object('source_id', r."source_id", 'source_name', r."source_name", 'target_id', r."target_id", 'target_name', r."target_name", 'edge_type', r."edge_type", 'start_time', r."start_time", 'end_time', r."end_time", 'alias', r."alias") AS "r" FROM "__provenance__" r WHERE r."edge_type" = 'calls' AND r."source_name" = 'ns:f' AND r."target_name" = 'ns2:g'
EOF
expecth 'MATCH (a:`ns:f`)-[r:calls]->(b:`ns2:g`) RETURN a.id, b' <<'EOF'
SELECT a."id", json_object('id', b."id", 'z', b."z") AS "b" FROM "__provenance__" r JOIN "ns:f" a ON a."id" = r."source_id" JOIN "ns2:g" b ON b."id" = r."target_id" WHERE r."edge_type" = 'calls' AND r."source_name" = 'ns:f' AND r."target_name" = 'ns2:g'
EOF
expecth 'MATCH (a:`ns:f`) RETURN a AS node' <<'EOF'
SELECT json_object('id', a."id", 'x', a."x", 'y', a."y") AS "node" FROM "ns:f" a
EOF

# Whole node / relationship errors.
reject 'MATCH (a) RETURN a'                    # whole node without a label
reject 'MATCH (a:`ns:f`) RETURN b'             # unknown variable

# Variable-length errors.
reject 'MATCH (a:`ns:f`)-[:calls*0..2]->(b:`ns:f`) RETURN b.id'          # lower bound < 1
reject 'MATCH (a:`ns:f`)-[:calls*3..2]->(b:`ns:f`) RETURN b.id'          # lower > upper
reject 'MATCH (a:`ns:f`)-[r:calls*1..2]->(b:`ns:f`) RETURN b.id'         # bound rel variable
reject 'MATCH (a:`ns:f`)-[:calls*1..2]-(b:`ns:f`) RETURN b.id'           # undirected var-length
reject 'MATCH (a:`ns:f`)-[:calls*1..2]->(b:`ns2:g`)-[:wraps]->(c) RETURN b.id'  # not sole hop

# Aggregation errors.
reject 'MATCH (a:`ns:f`) RETURN foo(a.x)'          # unknown aggregate
reject 'MATCH (a:`ns:f`) RETURN sum(a.x, a.y)'     # aggregate arity
reject 'MATCH (a:`ns:f`) RETURN a.x LIMIT a.x'     # non-integer LIMIT
reject 'MATCH (a:`ns:f`) RETURN a.x ORDER BY zzz'  # ORDER BY unknown name

# Undirected is only supported as a single, sole hop for now.
reject 'MATCH (a:`ns:f`)-[:calls]->(b:`ns2:g`)-[:wraps]-(c:`ns:f`) RETURN a.id'

# WHERE resolution/scope errors.
reject 'MATCH (a:`ns:f`) WHERE a.nope = 1 RETURN a.id'         # unknown column
reject 'MATCH (a:`ns:f`) WHERE a.y STARTS WITH a.x RETURN a.y' # needs a literal
reject 'MATCH (a:`ns:f`) WHERE count(a.x) > 1 RETURN a.x'      # aggregate not valid in WHERE

# Resolution errors -- validated against the flat schema.
reject 'MATCH (a:`ns:f`) RETURN a.nope'      # unknown column
reject 'MATCH (a:`nope:x`) RETURN a.id'      # unknown table
reject 'MATCH (a:kv) RETURN a.key'           # non-node table (no id) => dropped, unknown
reject 'MATCH (a) RETURN a.x'                # node has no label
reject 'MATCH (a:`ns:f`) RETRUN a.x'         # parse error

# Name map: a label may be written as either a table name or the command name
# its edges record. The map here gives table "ns:f" the recorded name "fnode".
expectm 'ns:f=fnode' 'MATCH (a:fnode)-[:calls]->(b:`ns2:g`) RETURN b.id' \
	'SELECT b."id" FROM "__provenance__" r JOIN "ns2:g" b ON b."id" = r."target_id" WHERE r."edge_type" = '"'"'calls'"'"' AND r."source_name" = '"'"'fnode'"'"' AND r."target_name" = '"'"'ns2:g'"'"''
expectm 'ns:f=fnode' 'MATCH (a:`ns:f`)-[:calls]->(b:`ns2:g`) RETURN b.id' \
	'SELECT b."id" FROM "__provenance__" r JOIN "ns2:g" b ON b."id" = r."target_id" WHERE r."edge_type" = '"'"'calls'"'"' AND r."source_name" = '"'"'fnode'"'"' AND r."target_name" = '"'"'ns2:g'"'"''
expectm 'ns:f=fnode' 'MATCH (a:`ns2:g`) RETURN a.z' \
	'SELECT a."z" FROM "ns2:g" a'
rejectm 'ns:f=fnode
x=ns:f' 'MATCH (a:`ns:f`) RETURN a.x'

# Inline relationship property maps lower to the same edge predicate the WHERE
# form (e.alias = 'fast') produces -- ANDed onto the pattern predicates.
expect 'MATCH (a:`ns:f`)-[{alias:"fast"}]->(b:`ns2:g`) RETURN b.id' \
	'SELECT b."id" FROM "__provenance__" r JOIN "ns2:g" b ON b."id" = r."target_id" WHERE r."source_name" = '"'"'ns:f'"'"' AND r."target_name" = '"'"'ns2:g'"'"' AND r."alias" = '"'"'fast'"'"''
expect 'MATCH (a:`ns:f`)-[:calls {alias:"fast"}]->(b:`ns2:g`) RETURN b.id' \
	'SELECT b."id" FROM "__provenance__" r JOIN "ns2:g" b ON b."id" = r."target_id" WHERE r."edge_type" = '"'"'calls'"'"' AND r."source_name" = '"'"'ns:f'"'"' AND r."target_name" = '"'"'ns2:g'"'"' AND r."alias" = '"'"'fast'"'"''
expect 'MATCH (a:`ns:f`)-[{alias:"fast"}]-(b:`ns2:g`) RETURN b.id' \
	'SELECT b."id" FROM "__provenance__" r JOIN "ns2:g" b ON 1 = 1 WHERE (r."source_name" = '"'"'ns:f'"'"' AND r."target_id" = b."id" AND r."target_name" = '"'"'ns2:g'"'"' OR r."target_name" = '"'"'ns:f'"'"' AND r."source_id" = b."id" AND r."source_name" = '"'"'ns2:g'"'"') AND r."alias" = '"'"'fast'"'"''

# Inline property errors.
reject 'MATCH (a:`ns:f`)-[{nope:"x"}]->(b:`ns2:g`) RETURN b.id'       # unknown edge column
reject 'MATCH (a:`ns:f`)-[{alias:a.x}]->(b:`ns2:g`) RETURN b.id'      # non-literal value
reject 'MATCH (a:`ns:f`)-[:chain*1..2 {alias:"x"}]->(b:`ns:f`) RETURN b.id'  # inline on var-length

rm -f "$schemafile"
exit $fail
