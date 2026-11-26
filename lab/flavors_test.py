"""The managed flavors on a PostgreSQL design (decision schema-per-engine): the every-object sample of PostgreSQL 18 loaded,
then what cortex.misfits says each flavor would not take, and the guard refusing, as the row is written, what the design's
flavor lacks: a kind (CockroachDB's aggregates), a value of a cortex column (its deferrable constraints).

  python3 lab/flavors_test.py
"""
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True
import common as C  # noqa: E402
import pg_store as P  # noqa: E402
import repo_pg_store as RP  # noqa: E402
import repo_store as R  # noqa: E402

DB = "lab_flavors"


def run(sql):
    r = subprocess.run(["docker", "exec", "-i", C.SERVER, "psql", "-U", "postgres", "-d", DB, "-At", "-v", "ON_ERROR_STOP=1", "-q"],
                       input=f"BEGIN;\nSET LOCAL ROLE sf_service;\n{sql}\nROLLBACK;", capture_output=True, text=True)
    return r.returncode == 0, next((line for line in r.stderr.splitlines() if line.startswith("ERROR")), "")


def main():
    snap = json.load(open(os.path.join(HERE, "out", "postgresql-18.json")))
    rows, design = RP.to_locked(P.rows_of(snap), "18", snap["parts"])
    R.build(DB)
    rows = RP.jsonish(R.OL.to_options(rows))
    C.psql("BEGIN;\nSET ROLE sf_service;\n" + "".join(R.copy_sql(k, rows[k]) for k in RP.ORDER if rows.get(k)) + "COMMIT;\n", DB)
    d = rows["cortex.designs"][0]["id"]
    print(f"== a PostgreSQL 18 design of every kind: {C.psql('SELECT count(*) FROM cortex.objects', DB)} objects; what each flavor would not take")
    for flavor in ("postgresql/rds", "postgresql/cloudsql", "postgresql/alloydb", "postgresql/cockroachdb", "postgresql/spanner"):
        got = C.psql(f"SELECT count(*) || ' refused, ' || count(*) FILTER (WHERE severity = 'warned') || ' warned: ' || coalesce(string_agg(DISTINCT what || ' ' || "
                     f"split_part(name, ' = ', 1), ', '), 'nothing') FROM cortex.misfits('{d}', '18', '{flavor}') WHERE severity = 'refused' OR severity = 'warned'", DB)
        print(f"  {flavor}: {got[:230]}")
    cases = [
        ("a deferrable constraint on CockroachDB", f"UPDATE cortex.designs SET flavor = 'postgresql/cockroachdb' WHERE id = '{d}'; "
                                                    f"UPDATE cortex.constraints SET \"deferrable\" = true WHERE id = (SELECT id FROM cortex.constraints WHERE design = '{d}' AND kind = 'foreign' LIMIT 1);", False),
        ("a deferrable constraint on PostgreSQL", f"UPDATE cortex.constraints SET \"deferrable\" = true WHERE id = (SELECT id FROM cortex.constraints WHERE design = '{d}' AND kind = 'foreign' LIMIT 1);", True),
        ("an aggregate on CockroachDB", f"UPDATE cortex.designs SET flavor = 'postgresql/cockroachdb' WHERE id = '{d}'; "
                                         f"UPDATE cortex.objects SET name = name WHERE kind = 'aggregate' AND design = '{d}';", False),
        ("a tablespace on Cloud SQL", f"UPDATE cortex.designs SET flavor = 'postgresql/cloudsql' WHERE id = '{d}'; "
                                       f"UPDATE cortex.objects SET name = name WHERE kind = 'tablespace' AND design = '{d}';", False),
        ("a change stream on PostgreSQL itself", f"INSERT INTO cortex.objects (design, namespace, kind, name, position) VALUES ('{d}', NULL, 'change_stream', 'cs', 999999);", False),
        ("a change stream on Spanner", f"UPDATE cortex.designs SET flavor = 'postgresql/spanner' WHERE id = '{d}'; "
                                        f"INSERT INTO cortex.objects (design, namespace, kind, name, position) VALUES ('{d}', NULL, 'change_stream', 'cs', 999999);", True),
    ]
    bad = 0
    for what, sql, want in cases:
        ok, err = run(sql)
        # a refusal counts only when it is the guard's, never a mistake in the statement
        right = ok == want and (want or 'syntax error' not in err)
        bad += not right
        print(f"  {'pass' if right else 'FAIL'}  {what}: {'taken' if ok else 'refused (' + err[7:120] + ')'}")
    print(f"{'pass' if not bad else 'FAIL'}  flavors: {bad} failures")
    C.psql(f"DROP DATABASE {DB} WITH (FORCE);", "postgres")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
