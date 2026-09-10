#!/bin/sh
# names.sh -- the command-name <-> table-name map and the inline relationship
# property maps that fill the `alias` column, asserted on the generated SQL
# (schema on stdin, no database).
#
# The schema deliberately gives each override command a table whose name differs
# from the `*_name` its edges record (table `jobs` / name `submit`, table
# `montecarlo` / name `submit:montecarlo`), so the map's two readings are
# actually exercised. Needs no sqlite3 CLI.

: "${KG:?KG must point at the knit-cypher-to-sql binary}"

schemafile="names_schema.txt"
printf 'jobs\tid,procs\nmontecarlo\tid,result\nsetup:libs\tid\n__provenance__\tsource_id,source_name,target_id,target_name,edge_type,start_time,end_time,alias\n' \
	> "$schemafile"

# The live map knit query would build for this experiment.
MAP='jobs=submit
montecarlo=submit:montecarlo
setup:libs=setup:libs'

fail=0

# expect QUERY EXPECTED-SQL: translate QUERY with $MAP; the SQL must match.
expect() {
	got=$("$KG" --names "$MAP" "$1" < "$schemafile" 2>&1)
	if [ "$got" != "$2" ]; then
		echo "FAIL: $1"
		echo "  expected: $2"
		echo "  got:      $got"
		fail=1
	fi
}

# reject ARGS...: the invocation must fail with a non-zero exit.
reject() {
	if "$KG" "$@" < "$schemafile" >/dev/null 2>&1; then
		echo "FAIL: should have been rejected: $*"
		fail=1
	fi
}

# A label written as the command name joins the table and filters on the name.
expect 'MATCH (j:submit) RETURN j.procs' \
	'SELECT j."procs" FROM "jobs" j'
# The table-name spelling resolves to the very same SQL.
expect 'MATCH (j:jobs) RETURN j.procs' \
	'SELECT j."procs" FROM "jobs" j'

# Inline alias singles out one of two otherwise-identical calls.
expect "MATCH (j:submit)-[{alias:'fast'}]->(m:montecarlo) RETURN m.result" \
	'SELECT m."result" FROM "__provenance__" r JOIN "montecarlo" m ON m."id" = r."target_id" WHERE r."source_name" = '"'"'submit'"'"' AND r."target_name" = '"'"'submit:montecarlo'"'"' AND r."alias" = '"'"'fast'"'"''
expect "MATCH (j:submit)-[{alias:'slow'}]->(m:montecarlo) RETURN m.result" \
	'SELECT m."result" FROM "__provenance__" r JOIN "montecarlo" m ON m."id" = r."target_id" WHERE r."source_name" = '"'"'submit'"'"' AND r."target_name" = '"'"'submit:montecarlo'"'"' AND r."alias" = '"'"'slow'"'"''
# The equivalent WHERE form lowers to the same predicate (edge variable `e`).
expect "MATCH (j:submit)-[e]->(m:montecarlo) WHERE e.alias = 'fast' RETURN m.result" \
	'SELECT m."result" FROM "__provenance__" e JOIN "montecarlo" m ON m."id" = e."target_id" WHERE e."source_name" = '"'"'submit'"'"' AND e."target_name" = '"'"'submit:montecarlo'"'"' AND e."alias" = '"'"'fast'"'"''

# used_by hop from the setup (source) to the job it is used by (target). The
# dispatcher command name `submit` reads better than the table name `jobs`.
expect 'MATCH (s:`setup:libs`)-[:used_by]->(j:submit) RETURN j.procs' \
	'SELECT j."procs" FROM "__provenance__" r JOIN "jobs" j ON j."id" = r."target_id" WHERE r."edge_type" = '"'"'used_by'"'"' AND r."source_name" = '"'"'setup:libs'"'"' AND r."target_name" = '"'"'submit'"'"''

# --names-file supplies the same map from a file.
printf '%s\n' "$MAP" > names_map.txt
got=$("$KG" --names-file names_map.txt 'MATCH (j:submit) RETURN j.procs' < "$schemafile" 2>&1)
if [ "$got" != 'SELECT j."procs" FROM "jobs" j' ]; then
	echo "FAIL: --names-file"
	echo "  got: $got"
	fail=1
fi

# Errors.
reject --names 'jobs=submit
x=jobs' 'MATCH (j:jobs) RETURN j.procs'                          # ambiguous label
reject --names 'no-equals-sign' 'MATCH (j:jobs) RETURN j.procs' # bad spec
reject --names '=submit' 'MATCH (j:jobs) RETURN j.procs'        # empty table
reject --names-file no_such_file 'MATCH (j:jobs) RETURN j.procs' # missing file
reject --names 'both=one' --names-file names_map.txt \
	'MATCH (j:jobs) RETURN j.procs'                              # both map sources
reject --names 'ghost=phantom' 'MATCH (a:phantom) RETURN a.id'  # maps to no table
reject --names "$MAP" \
	"MATCH (j:submit)-[{nope:'x'}]->(m:montecarlo) RETURN m.result" # bad edge column

rm -f "$schemafile" names_map.txt
exit $fail
