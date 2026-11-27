"""A PostgreSQL 18 store in a Docker container, made for one tool run and dropped after it (its volume with it): the
roles made as the installer makes them, the one database schema_forge, and psql into it as any role."""
import os
import subprocess
import time

IMAGE = os.environ.get("SF_STORE_IMAGE", "postgres:18-alpine")


def docker(*args, stdin=None):
    return subprocess.run(["docker", *args], input=stdin, capture_output=True, text=True)


class Failed(Exception):
    pass


class Store:
    def __init__(self, name="sf-tool"):
        self.name = f"{name}-{os.getpid()}"

    def __enter__(self):
        if docker("info").returncode:
            raise SystemExit("docker is not running")
        r = docker("run", "-d", "--name", self.name, "-e", "POSTGRES_HOST_AUTH_METHOD=trust", IMAGE)
        if r.returncode:
            raise SystemExit(f"docker run {IMAGE}: {r.stderr.strip()}")
        for _ in range(240):
            logs = docker("logs", self.name)
            if "PostgreSQL init process complete" in logs.stdout + logs.stderr and self.sql("SELECT 1", db="postgres", check=False)[0] == 0:
                break
            time.sleep(0.25)
        else:
            self.__exit__(None, None, None)
            raise SystemExit("the store did not answer within a minute")
        self.sql("CREATE ROLE cortex_owner NOLOGIN; CREATE ROLE cortex_service LOGIN; CREATE ROLE cortex_agent LOGIN; CREATE ROLE cortex_reader LOGIN;"
                 "CREATE DATABASE schema_forge OWNER cortex_owner; REVOKE CONNECT ON DATABASE postgres, template1 FROM PUBLIC;", db="postgres")
        self.sql("REVOKE ALL ON SCHEMA public FROM PUBLIC; REVOKE TEMPORARY ON DATABASE schema_forge FROM PUBLIC; GRANT CREATE ON DATABASE schema_forge TO cortex_owner;")
        return self

    def __exit__(self, *exc):
        docker("rm", "-f", "-v", self.name)

    def sql(self, script, db="schema_forge", user="postgres", check=True):
        """Runs a psql script; returns (exit, stdout, stderr). With check, a failure raises Failed naming the last
        labelled part (\\echo @@ <label>) it reached."""
        r = docker("exec", "-i", self.name, "psql", "-U", user, "-d", db, "-v", "ON_ERROR_STOP=1", "-q", "-At", "-X", stdin=script)
        if check and r.returncode:
            labels = [l[3:] for l in r.stdout.splitlines() if l.startswith("@@ ")]
            raise Failed(f"{labels[-1] if labels else db}: {r.stderr.strip()}")
        return r.returncode, r.stdout, r.stderr

    def value(self, query, user="postgres"):
        return self.sql(query, user=user)[1].strip()

    def dump(self):
        r = docker("exec", self.name, "pg_dump", "-U", "postgres", "--schema-only", "schema_forge")
        if r.returncode:
            raise Failed(f"pg_dump: {r.stderr.strip()}")
        return "\n".join(l for l in r.stdout.splitlines() if not l.startswith(("-- Dumped", "\\restrict", "\\unrestrict"))) + "\n"
