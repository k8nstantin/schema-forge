"""The guard of declared options (schema/cortex/check_options.sql, decision declared-options): with a MySQL design loaded, the database refuses, as the row is written, an
option not declared for the design's engine and part, one of another engine, a value of the wrong type, one not among
its declared values, a null where it may not be null, and one the design's version does not have; and takes a right one.

  python3 lab/options_test.py [snapshot.json]      default: lab/out/mysql-8.4.json
"""
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True
import common as C  # noqa: E402
import repo_store as R  # noqa: E402

DB = "lab_options"


def run(sql):
    r = subprocess.run(["docker", "exec", "-i", C.SERVER, "psql", "-U", "postgres", "-d", DB, "-At", "-v", "ON_ERROR_STOP=1", "-q"],
                       input=f"BEGIN;\nSET LOCAL ROLE sf_service;\n{sql}\nCOMMIT;", capture_output=True, text=True)
    return r.returncode == 0, next((l for l in r.stderr.splitlines() if l.startswith("ERROR")), "")


def main():
    snap = json.load(open(sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "out", "mysql-8.4.json")))
    rows, _ = R.rows_of(snap)
    R.build(DB)
    R.load(DB, rows)
    n = C.psql("SELECT count(*) || ' declared options, ' || count(DISTINCT part) || ' parts' FROM cortex.option_declarations", DB)
    print(f"== declared options: {n}; a MySQL {snap['version']} design loaded through the guard")
    tab = C.psql("SELECT id FROM cortex.objects WHERE kind = 'table' ORDER BY position LIMIT 1", DB)
    view = C.psql("SELECT v.id FROM cortex.views v JOIN cortex.objects o ON o.id = v.id ORDER BY o.position LIMIT 1", DB)
    # one option only a later version has, to prove the guard by version
    C.psql("INSERT INTO cortex.engine_versions (id, engine, version, name, position) VALUES ('mysql/99.0', 'mysql', '99.0', 'MySQL 99.0', 99);"
           "INSERT INTO cortex.option_declarations (id, engine, part, name, value_type, since, about) "
           "VALUES ('mysql/objects/future_option', 'mysql', 'objects', 'future_option', 'boolean', 'mysql/99.0', 'a later release''s option');", DB)
    cases = [
        ("an option nobody declared", f"""UPDATE cortex.objects SET options = options || '{{"colour": "red"}}' WHERE id = '{tab}';""", False),
        ("PostgreSQL's option on a MySQL design", f"""UPDATE cortex.objects SET options = options || '{{"persistence": "unlogged"}}' WHERE id = '{tab}';""", False),
        ("a number where text is declared", f"""UPDATE cortex.objects SET options = options || '{{"row_format": 7}}' WHERE id = '{tab}';""", False),
        ("a value not among the declared ones", f"""UPDATE cortex.views SET options = options || '{{"algorithm": "SOMETIMES"}}' WHERE id = '{view}';""", False),
        ("a null where it may not be null", f"""UPDATE cortex.objects SET options = options || '{{"engine": null}}' WHERE id = '{tab}';""", False),
        ("an option the design's version does not have", f"""UPDATE cortex.objects SET options = options || '{{"future_option": true}}' WHERE id = '{tab}';""", False),
        ("a right option, rightly typed", f"""UPDATE cortex.objects SET options = options || '{{"row_format": "COMPACT"}}' WHERE id = '{tab}';""", True),
        # the kinds' guard (check_kinds): a kind the engine declares, in a namespace exactly when its kind lives in one
        ("a kind the engine does not declare", f"UPDATE cortex.objects SET kind = 'materialized_view' WHERE id = '{tab}';", False),
        ("a table taken out of its namespace", f"UPDATE cortex.objects SET namespace = NULL WHERE id = '{tab}';", False),
        ("a tablespace put in a namespace", f"UPDATE cortex.objects SET namespace = (SELECT namespace FROM cortex.objects WHERE id = '{tab}') "
                                            "WHERE id = (SELECT id FROM cortex.objects WHERE kind = 'tablespace' LIMIT 1);", False),
        ("a tablespace in no namespace, renamed", "UPDATE cortex.objects SET name = 'ts_renamed' WHERE id = (SELECT id FROM cortex.objects WHERE kind = 'tablespace' LIMIT 1);", True),
    ]
    bad = 0
    for what, sql, want in cases:
        ok, err = run(sql)
        right = ok == want and (want or "check_options" in err or "not declared" in err or "is a " in err or "may " in err or "is not in" in err or "lives in" in err)
        bad += not right
        print(f"  {'pass' if right else 'FAIL'}  {what}: {'taken' if ok else 'refused (' + err[7:110] + ')'}")
    print(f"{'pass' if not bad else 'FAIL'}  the options' guard: {bad} failures")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
