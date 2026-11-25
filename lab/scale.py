"""The lab's scale test: real schemas, read from every MySQL target, stored in the global schema and the MySQL plugin's
with versioning on, then every part rebuilt from the store and compared with what the server gave, property by
property. The schemas read are LAB_SCHEMAS; their snapshots go to LAB_OUT, which for anything private must be outside
the repository. Nothing of them is printed but counts and the first differences' property names.

  LAB_SCHEMAS=a,b LAB_OUT=~/private/out python3 lab/scale.py [--versioning]
"""
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import extract as X  # noqa: E402
import versioning_test as V  # noqa: E402
from concepts import SHARED  # noqa: E402


def stored(db, engine, concepts):
    """Every part as the store gives it back: {(concept, id): (shared, own)}."""
    have = set(V.psql(f"SELECT table_name FROM information_schema.tables WHERE table_schema = 'engine_{engine}'", db).split())
    out = {}
    for c in concepts:
        opt = f"{c}_options" in have
        sql = (f"SELECT coalesce(json_agg(json_build_object('c', to_jsonb(t), 'o', {'to_jsonb(o)' if opt else 'NULL'})), '[]') "
               f"FROM core.{c} t" + (f" LEFT JOIN engine_{engine}.{c}_options o ON o.id = t.id" if opt else "") + ";")
        for r in json.loads(V.psql(sql, db)):
            core, own = r["c"], r["o"] or {}
            shared = {a: core[a] for a in SHARED.get(c, {}) if core.get(a) is not None}
            out[(c, core["id"])] = (shared, {k: v for k, v in own.items() if k != "id" and v is not None})
    return out


def same(a, b):
    """One value as read and as stored: equal, or equal as text where the store kept a text column."""
    if a == b:
        return True
    if isinstance(b, str):
        return V.text(a) == b
    if isinstance(a, (list, dict)) and isinstance(b, str):
        return json.loads(b) == a
    return False


def main():
    if not os.environ.get("LAB_SCHEMAS") or not os.environ.get("LAB_OUT"):
        raise SystemExit("LAB_SCHEMAS and LAB_OUT name the schemas and where their snapshots go")
    os.makedirs(X.OUT, exist_ok=True)
    failures = 0
    for version, container in X.MYSQL:
        t = time.time()
        parts = X.extract_mysql(version, container)
        t_read = time.time() - t
        snap = {"engine": "mysql", "version": version, "parts": parts}
        json.dump(snap, open(os.path.join(X.OUT, f"mysql-{version}.json"), "w"), indent=1, sort_keys=True, default=str)
        kinds = {}
        for p in parts:
            kinds[p["kind"]] = kinds.get(p["kind"], 0) + 1
        t = time.time()
        db, merged = V.build("mysql", snap, f"lab_scale_mysql_{version.replace('.', '_')}")
        t_store = time.time() - t
        # a view is listed by TABLES and VIEWS: one part once merged, and it must carry the server's definition
        undefined = [p["kind"] for _, p, _, _ in merged if p["kind"] in ("table", "view", "routine", "trigger", "event")
                     and "__show_create" not in p["props"]]
        missing_def = len(undefined)
        t = time.time()
        back = stored(db, "mysql", sorted({c for c, *_ in merged}))
        t_back = time.time() - t
        exact, diffs = 0, {}
        for c, p, s, o in merged:
            got = back.get((c, p["key"]))
            if got is None:
                diffs.setdefault(f"{c}: missing from the store", 0)
                diffs[f"{c}: missing from the store"] += 1
                continue
            bad = [k for k in set(s) | set(got[0]) if not same(s.get(k), got[0].get(k))]
            bad += [k for k in set(o) | set(got[1]) if not same(o.get(k), got[1].get(k))]
            if bad:
                for k in bad:
                    diffs[f"{c}.{k}"] = diffs.get(f"{c}.{k}", 0) + 1
            else:
                exact += 1
        extra = len(back) - len(merged)
        size = V.psql("SELECT pg_size_pretty(pg_database_size(current_database())) || ', the log ' || "
                      "(SELECT count(*) FROM log.changes) || ' changes'", db)
        ok = exact == len(merged) and not extra and not missing_def
        failures += not ok
        print(f"{'pass' if ok else 'FAIL'}  mysql {version}: {len(parts)} parts read ({', '.join(f'{k} {n}' for k, n in sorted(kinds.items()))})")
        print(f"      read {t_read:.1f}s, stored {t_store:.1f}s, rebuilt {t_back:.1f}s; {size}")
        print(f"      {exact} of {len(merged)} parts rebuilt exactly" + (f"; {extra} extra in the store" if extra else "")
              + (f"; without a definition: {', '.join(sorted(set(undefined)))} ({missing_def})" if missing_def else ""))
        for k, n in sorted(diffs.items(), key=lambda x: -x[1])[:8]:
            print(f"        differs: {k} in {n} parts")
    print(f"== {failures} servers failed")
    if "--versioning" in sys.argv:
        # the same savepoints, version, branch, switches, opens and restores as the lab's, on the real schema's size
        V.run("mysql", 300, json.load(open(os.path.join(X.OUT, "mysql-8.4.json"))), "lab_scale_versioning")


if __name__ == "__main__":
    main()
