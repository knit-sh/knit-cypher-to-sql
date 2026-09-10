#!/bin/sh
# memcheck.sh -- run the parse and transpile paths under valgrind.
#
# A definite/indirect leak or any memory error makes valgrind exit with the
# distinctive code 99, which we treat as a failure. Ordinary non-zero exits
# from knit-cypher-to-sql itself (e.g. exit 1 on a rejected query) pass straight
# through valgrind, so the error path is checked for leaks without its exit
# code being mistaken for one. Skipped if valgrind is not installed.

: "${KG:?KG must point at the knit-cypher-to-sql binary}"

if ! command -v valgrind >/dev/null 2>&1; then
	echo "valgrind unavailable; skipping memory check"
	exit 77
fi

VG="valgrind -q --leak-check=full --errors-for-leak-kinds=definite,indirect --error-exitcode=99"

fail=0
run() {
	"$@"
	if [ $? -eq 99 ]; then
		echo "FAIL: valgrind reported a leak/error: $*"
		fail=1
	fi
}

# --ast: successful parses.
run $VG "$KG" --ast "MATCH (a:Foo) RETURN a"
run $VG "$KG" --ast "MATCH (a:\`ns:f\`)-[r:calls]->(b:\`ns2:g\`) RETURN b.id, count(*) AS n ORDER BY n DESC LIMIT 5"
run $VG "$KG" --ast "MATCH (a)-[:calls*1..3]-(b) WHERE a.x > 1 AND b.name STARTS WITH 'abc' RETURN DISTINCT a"

# --ast: rejected parses -- these exercise the error-path cleanup.
run $VG "$KG" --ast ""
run $VG "$KG" --ast "MATCH (a"
run $VG "$KG" --ast "CREATE (a) RETURN a"
run $VG "$KG" --ast "MATCH (a) RETURN"
run $VG "$KG" --ast "MATCH (a)-[r:calls]-> RETURN a"

# Transpile path (schema on stdin, no database): success and error cleanup, so
# read_all_stdin, catalog_from_schema, the transformer and names.c are all
# leak-checked. A redirection on the `run` call feeds stdin without a pipe
# subshell, so a valgrind failure still propagates to $fail. The schema's "kv"
# has no id column, so it is dropped (its own cleanup path).
printf 'ns:f\tid,x,y\nns2:g\tid,z\nkv\tkey,value\n__provenance__\tsource_id,source_name,target_id,target_name,edge_type,start_time,end_time,alias\n' > vg_schema.txt

# Successful translations across the SQL shapes.
run $VG "$KG" "MATCH (a:\`ns:f\`) RETURN a.x AS ex, a.y" < vg_schema.txt
run $VG "$KG" "MATCH (a:\`ns:f\`)-[r:calls]->(b:\`ns2:g\`) RETURN r.alias, b.id" < vg_schema.txt
run $VG "$KG" "MATCH (a:\`ns:f\`)<-[r:calls]-(b:\`ns2:g\`) RETURN b.id" < vg_schema.txt
run $VG "$KG" "MATCH (a:\`ns:f\`) WHERE a.x >= 1 AND a.y <> 'z' OR NOT a.x IN [3] RETURN a.x" < vg_schema.txt
run $VG "$KG" "MATCH (a:\`ns:f\`)-[r:calls]->(b:\`ns2:g\`) WHERE b.z > 1.0 AND r.alias IS NULL RETURN a.id" < vg_schema.txt
run $VG "$KG" "MATCH (a:\`ns:f\`)-[:calls]->(b:\`ns2:g\`)-[:wraps]->(c:\`ns:f\`) RETURN a.id, c.id" < vg_schema.txt
run $VG "$KG" "MATCH (a:\`ns2:g\`)-[r:calls]-(b:\`ns:f\`) RETURN a.id, b.id" < vg_schema.txt
run $VG "$KG" "MATCH (a:\`ns:f\`)-[:calls*1..3]->(b:\`ns2:g\`) RETURN a.id, b.id" < vg_schema.txt
run $VG "$KG" "MATCH (a:\`ns:f\`)-[:calls*]->(b:\`ns2:g\`) RETURN b.id" < vg_schema.txt
run $VG "$KG" "MATCH (a:\`ns:f\`) RETURN a.y, count(a.x) AS n ORDER BY n DESC LIMIT 5" < vg_schema.txt
run $VG "$KG" "MATCH (a:\`ns:f\`) RETURN collect(a.id) AS ids" < vg_schema.txt
run $VG "$KG" "MATCH (a:\`ns:f\`) RETURN a" < vg_schema.txt
run $VG "$KG" "MATCH (a:\`ns:f\`)-[r:calls]->(b:\`ns2:g\`) RETURN a.id, b" < vg_schema.txt
run $VG "$KG" "MATCH (a:\`ns:f\`)-[:calls {alias:'fast'}]->(b:\`ns2:g\`) RETURN b.id" < vg_schema.txt

# Error/cleanup paths.
run $VG "$KG" "MATCH (a:\`ns:f\`) RETURN a.nope" < vg_schema.txt
run $VG "$KG" "MATCH (a:kv) RETURN a.key" < vg_schema.txt
run $VG "$KG" "MATCH (a:\`ns:f\`) RETRUN a.x" < vg_schema.txt
run $VG "$KG" "MATCH (a:\`ns:f\`) WHERE a.y STARTS WITH a.x RETURN a.y" < vg_schema.txt
run $VG "$KG" "MATCH (a:\`ns:f\`)-[{nope:'x'}]->(b:\`ns2:g\`) RETURN b.id" < vg_schema.txt

# Name map: --names/--names-file on success and error paths (ambiguous label,
# invalid spec, missing file), so names.c's allocations are leak-checked.
printf 'ns:f=fnode\n' > vg_map.txt
run $VG "$KG" --names 'ns:f=fnode' "MATCH (a:fnode) RETURN a.x" < vg_schema.txt
run $VG "$KG" --names-file vg_map.txt "MATCH (a:\`ns:f\`) RETURN a.x" < vg_schema.txt
run $VG "$KG" --names 'ns:f=fnode
x=ns:f' "MATCH (a:\`ns:f\`) RETURN a.x" < vg_schema.txt
run $VG "$KG" --names 'no-equals' "MATCH (a:\`ns:f\`) RETURN a.x" < vg_schema.txt
run $VG "$KG" --names-file no_such_file "MATCH (a:\`ns:f\`) RETURN a.x" < vg_schema.txt
rm -f vg_map.txt vg_schema.txt

exit $fail
