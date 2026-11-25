"""The lab's access test: the probe and the read as a read-only account that may see the definitions and nothing of
the statistics, then the same account given the statistics grants. The probe must say which groups the account
cannot read and why, never fail, never call one on.

  python3 lab/probe_access.py
"""
import secrets
import subprocess

import probe as P

PW = secrets.token_hex(8)


class As(P.Server):
    """A server asked as another account."""

    def __init__(self, engine, container, user):
        super().__init__(engine, container)
        self.user = user

    def ask(self, sql):
        self.sent.append(sql)
        if self.engine == "mysql":
            args = ["docker", "exec", "-i", self.container, "mysql", f"-u{self.user}", f"-p{PW}", "-B", "-N", "--raw"]
        else:
            args = ["docker", "exec", "-i", self.container, "psql", "-U", self.user, "-d", "postgres", "-At", "-F", "\t", "-v", "ON_ERROR_STOP=1"]
        r = subprocess.run(args, input=sql, capture_output=True, text=True)
        if r.returncode:
            raise RuntimeError(r.stderr.strip()[-300:])
        return [l.split("\t") for l in r.stdout.splitlines() if l]


def root(engine, container, sql):
    if engine == "mysql":
        args = ["docker", "exec", "-i", container, "mysql", "-uroot", f"-p{P.PW}"]
    else:
        args = ["docker", "exec", "-i", container, "psql", "-U", "postgres", "-q", "-v", "ON_ERROR_STOP=1"]
    r = subprocess.run(args, input=sql, capture_output=True, text=True)
    if r.returncode:
        raise SystemExit(r.stderr.strip()[-400:])


SETUP = {
    "mysql": (f"""DROP USER IF EXISTS sf_lab_reader@'%'; CREATE USER sf_lab_reader@'%' IDENTIFIED BY '{PW}';
                 GRANT SELECT, SHOW VIEW, TRIGGER, EVENT ON shop.* TO sf_lab_reader@'%';
                 GRANT SELECT, SHOW VIEW, TRIGGER, EVENT ON torture.* TO sf_lab_reader@'%';
                 GRANT SHOW_ROUTINE ON *.* TO sf_lab_reader@'%';""",
              "GRANT SELECT ON performance_schema.* TO sf_lab_reader@'%'; GRANT SELECT ON mysql.innodb_table_stats TO sf_lab_reader@'%';"),
    "postgresql": ("""DO $$ BEGIN IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sf_lab_reader') THEN
                       REVOKE pg_read_all_stats FROM sf_lab_reader; DROP OWNED BY sf_lab_reader; DROP ROLE sf_lab_reader; END IF; END $$;
                    CREATE ROLE sf_lab_reader LOGIN;
                    GRANT USAGE ON SCHEMA shop, torture TO sf_lab_reader; GRANT SELECT ON ALL TABLES IN SCHEMA shop, torture TO sf_lab_reader;""",
                   "GRANT pg_read_all_stats TO sf_lab_reader;"),
}


def show(label, s):
    probed = P.probe(s)
    print(f"  {label}: {len(probed['roster'])} objects in the roster")
    for g in probed["groups"]:
        print(f"    {g['group']:14} {g['state']:9} {g['why'][:110]}")
    s.sent = []
    got = P.read(s, probed, {"objects": "all", "groups": "all"})
    print(f"    read all: {len(got['definitions'])} definitions, statistics {', '.join(sorted(got['statistics'])) or '-'}")
    if "statements" in got["statistics"]:
        hidden = sum(1 for r in got["statistics"]["statements"] if len(r) > 1 and "insufficient privilege" in r[1])
        print(f"    statement texts hidden from this account: {hidden} of {len(got['statistics']['statements'])}")


def main():
    for engine, container in (("mysql", "sf-mysql-8.4"), ("postgresql", "sf-pg-18")):
        print(f"== {engine} ({container})")
        root(engine, container, SETUP[engine][0])
        show("read-only, no statistics grants", As(engine, container, "sf_lab_reader"))
        root(engine, container, SETUP[engine][1])
        show("with the statistics grants", As(engine, container, "sf_lab_reader"))
        root(engine, container, "DROP USER sf_lab_reader@'%';" if engine == "mysql" else
             "REVOKE pg_read_all_stats FROM sf_lab_reader; DROP OWNED BY sf_lab_reader; DROP ROLE sf_lab_reader;")


if __name__ == "__main__":
    main()
