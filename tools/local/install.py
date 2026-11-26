"""Drops SchemaForge from this machine's PostgreSQL 18 and installs the locked schema of a branch, then restarts the server,
checks every service account and the schema, saves the installed version's locked dump for tools/local/schema_drift.py,
runs it, and installs (or refreshes) its hourly check. Run it yourself, as the DBA: it asks for the DBA's password once and checks it (a typo may be typed again,
three times), and asks you to type DROP. The password lives only in this process while it runs; no file keeps it. The
service accounts' new passwords go to the accounts file (mode 600).

  python3 tools/local/install.py [--dba dba] [--ref design-declared-options] [--private ~/schema-forge-lab-private]
"""
import getpass
import os
import shutil
import subprocess
import sys
import time

BIN = "/opt/homebrew/opt/postgresql@18/bin"
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
WORK = "/tmp/schema-forge-install"
DECLARATIONS = ["engine_versions", "engine_features", "catalog_sources", "object_kinds", "option_declarations", "engine_flavors", "flavor_limits",
                "reference_kinds", "privilege_declarations"]


def arg(name, default):
    a = sys.argv[1:]
    return a[a.index(name) + 1] if name in a else default


def stop(why):
    subprocess.run(["git", "-C", REPO, "worktree", "remove", "--force", WORK], capture_output=True)
    raise SystemExit(f"STOPPED: {why}")


def psql(user, password, db, sql):
    r = subprocess.run([f"{BIN}/psql", "-h", "127.0.0.1", "-U", user, "-d", db, "-Atq", "-c", sql], capture_output=True, text=True,
                       env=dict(os.environ, PGPASSWORD=password))
    return r.returncode == 0, r.stdout.strip(), r.stderr.strip()


def main():
    dba, ref = arg("--dba", "dba"), arg("--ref", "design-declared-options")
    private = os.path.expanduser(arg("--private", "~/schema-forge-lab-private"))
    accounts_file = os.path.join(private, "local-accounts.env")

    print("== 0. the DBA's password")
    for n in (1, 2, 3):
        password = getpass.getpass(f"   password of {dba}@127.0.0.1:5432: ")
        if psql(dba, password, "postgres", "SELECT 1")[0]:
            print("   signed in")
            break
        print(f"   that password does not sign {dba} in ({n} of 3)")
    else:
        stop("the DBA's password was not right three times")

    print(f"== 1. the repository at {ref}")
    if subprocess.run(["git", "-C", REPO, "fetch", "-q", "origin"]).returncode:
        stop("fetching the repository")
    head = subprocess.run(["git", "-C", REPO, "log", "-1", "--format=%h %s", f"origin/{ref}"], capture_output=True, text=True).stdout.strip()
    print(f"   {ref} is {head[:100]}")
    subprocess.run(["git", "-C", REPO, "worktree", "remove", "--force", WORK], capture_output=True)
    if subprocess.run(["git", "-C", REPO, "worktree", "add", "-q", "--detach", WORK, f"origin/{ref}"]).returncode:
        stop(f"checking out {ref}")

    print("== 2. drop the old, install the new (type DROP when asked)")
    r = subprocess.run([sys.executable, "-B", "schema/install.py", "--fresh", "--host", "127.0.0.1", "--user", dba, "--accounts-file", accounts_file],
                       cwd=WORK, env=dict(os.environ, SF_ROOT_PASSWORD=password, PSQL=f"{BIN}/psql"))
    if r.returncode:
        stop("the install did not finish; nothing after it was run")

    print("== 3. restart PostgreSQL")
    subprocess.run(["brew", "services", "restart", "postgresql@18"], capture_output=True)
    for _ in range(30):
        if subprocess.run([f"{BIN}/pg_isready", "-h", "127.0.0.1", "-q"]).returncode == 0:
            break
        time.sleep(1)
    else:
        stop("PostgreSQL did not come back")
    print("   accepting connections")

    print("== 4. after the restart: the service accounts sign in, and the schema is whole")
    secrets = {}
    for line in open(accounts_file):
        k, _, v = line.strip().removeprefix("export ").partition("=")
        secrets[k] = v.strip("'\"")
    for role in ("sf_service", "sf_agent", "sf_reader"):
        ok, out, err = psql(role, secrets[f"{role.upper()}_PASSWORD"], "schema_forge", "SELECT current_user")
        print(f"   {role} signs in" if ok else stop(f"{role} does not sign in: {err}"))
    ok, out, err = psql(dba, password, "schema_forge", """
        SELECT string_agg(n.nspname || ': ' || c, ', ' ORDER BY n.nspname) FROM (SELECT relnamespace, count(*) c FROM pg_class
        WHERE relkind = 'r' GROUP BY 1) x JOIN pg_namespace n ON n.oid = x.relnamespace WHERE n.nspname IN ('cortex', 'ui', 'engine_mysql', 'engine_postgresql')""")
    print(f"   tables: {out}" if ok else stop(f"reading the schema: {err}"))
    ok, out, err = psql(dba, password, "schema_forge", """
        SELECT string_agg(k.engine || ': ' || k.n || ' kinds, ' || (SELECT count(*) FROM cortex.option_declarations o WHERE o.engine = k.engine)
          || ' options, ' || (SELECT count(*) FROM cortex.engine_flavors f WHERE f.engine = k.engine) || ' flavors, '
          || (SELECT count(*) FROM cortex.flavor_limits l JOIN cortex.engine_flavors f ON f.id = l.flavor WHERE f.engine = k.engine) || ' flavor limits', '; ')
        FROM (SELECT engine, count(*) n FROM cortex.object_kinds GROUP BY engine) k""")
    print(f"   {out}" if ok else stop(f"reading the declarations: {err}"))
    ok, out, err = psql("sf_service", secrets["SF_SERVICE_PASSWORD"], "schema_forge",
                        f"SELECT count(*) FROM unnest(ARRAY{DECLARATIONS}) t, unnest(ARRAY['INSERT', 'UPDATE', 'DELETE']) p WHERE has_table_privilege('cortex.' || t, p)")
    print("   sf_service reads the engines' declarations and cannot change them" if ok and out == "0" else stop(f"sf_service may change the declarations ({out} {err})"))

    print("== 5. the drift check's baseline: the locked schema of what was installed")
    os.makedirs(os.path.join(private, "installed"), exist_ok=True)
    shutil.copy(os.path.join(WORK, "schema", "dump", "schema_forge.sql"), os.path.join(private, "installed", "schema_forge.sql"))
    sha = subprocess.run(["git", "-C", WORK, "rev-parse", "--short", "HEAD"], capture_output=True, text=True).stdout.strip()
    open(os.path.join(private, "installed", "ref"), "w").write(f"{ref} {sha}\n")
    subprocess.run([sys.executable, "-B", os.path.join(REPO, "tools", "local", "schema_drift.py"), "--private", private])
    print("== 6. the hourly drift check, installed or refreshed (a launchd agent; it checks once now)")
    if subprocess.run([sys.executable, "-B", os.path.join(REPO, "tools", "local", "schema_drift.py"), "--schedule", "--private", private]).returncode:
        stop("installing the hourly drift check")
    subprocess.run(["git", "-C", REPO, "worktree", "remove", "--force", WORK], capture_output=True)
    print(f"done: sign in with   psql -h 127.0.0.1 -U {dba} -d schema_forge")


if __name__ == "__main__":
    main()
