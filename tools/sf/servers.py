"""Source servers for the tools, each in a Docker container made for one run and dropped after it: a MySQL (or
Percona) server and a PostgreSQL server, a schema loaded into each from a file, and JSON read back from their catalogs."""
import json
import os
import subprocess
import time

from sf.store import Failed, docker


class MySQL:
    def __init__(self, image="mysql:8.0", name="sf-mysql", options=()):
        self.image, self.name, self.options = image, f"{name}-{os.getpid()}", list(options)

    def __enter__(self):
        r = docker("run", "-d", "--name", self.name, "-e", "MYSQL_ALLOW_EMPTY_PASSWORD=1", "-e", "MYSQL_ROOT_HOST=%", self.image,
                   "--log-bin-trust-function-creators=1", *self.options)
        if r.returncode:
            raise SystemExit(f"docker run {self.image}: {r.stderr.strip()}")
        # the image first runs a bootstrap server with networking off, then restarts: wait for the real one, on 3306
        # 8.0 and later write both on one line; 5.7 writes the port on the line after "ready for connections"
        for _ in range(900):
            text = "\n".join((lambda l: l.stdout + l.stderr)(docker("logs", self.name)).splitlines())
            ready = "ready for connections" in text and "port: 3306" in text
            if ready and docker("exec", self.name, "mysql", "-uroot", "-N", "-e", "SELECT 1").returncode == 0:
                return self
            time.sleep(0.5)
        self.__exit__()
        raise SystemExit(f"{self.image} did not answer within five minutes")

    def __exit__(self, *exc):
        docker("rm", "-f", "-v", self.name)

    def load(self, path):
        # the file's bytes as they are: a dump names its own character set (SET NAMES), which a decode would break
        r = subprocess.run(["docker", "exec", "-i", self.name, "mysql", "-uroot"], input=open(path, "rb").read(), capture_output=True)
        if r.returncode:
            raise Failed(f"loading {os.path.basename(path)} into {self.image}: {r.stderr.decode('utf-8', 'replace').strip()[:300]}")

    # everything the tools read or write is utf8mb4 on the wire: the server converts each value from its own character set
    CLIENT = "--default-character-set=utf8mb4"

    def json(self, query):
        r = docker("exec", "-i", self.name, "mysql", "-uroot", self.CLIENT, "-N", "-B", "--raw", "-e", query)
        if r.returncode:
            raise Failed(f"{self.image}: {r.stderr.strip()[:300]}")
        out = r.stdout.strip()
        return json.loads(out) if out and out != "NULL" else []

    def rows(self, statements):
        """Runs SHOW statements, one line of output each; returns each one's fields, the server's escaping undone."""
        if not statements:
            return []
        r = docker("exec", "-i", self.name, "mysql", "-uroot", self.CLIENT, "-N", "-B", stdin="".join(s.rstrip(";") + ";\n" for s in statements))
        if r.returncode:
            raise Failed(f"{self.image}: {r.stderr.strip()[:300]}")
        out = []
        for line in r.stdout.split("\n"):
            if line:
                out.append([unescape(f) for f in line.split("\t")])
        return out

    def sql(self, text):
        r = docker("exec", "-i", self.name, "mysql", "-uroot", self.CLIENT, stdin=text)
        if r.returncode:
            raise Failed(f"{self.image}: {r.stderr.strip()[:400]}")
        return r.stdout


def unescape(field):
    """mysql -B escapes a field's newline, tab, backslash and NUL; this undoes it."""
    out, i = [], 0
    while i < len(field):
        c = field[i]
        if c == "\\" and i + 1 < len(field):
            out.append({"n": "\n", "t": "\t", "\\": "\\", "0": "\0"}.get(field[i + 1], field[i + 1]))
            i += 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


class TiDB(MySQL):
    """TiDB, standalone (its own storage in the container), spoken to over the MySQL protocol on port 4000 by a mysql
    client in a second container sharing its network: the TiDB image carries no client."""

    CLIENT = "mysql:8.4"

    def __init__(self, image="pingcap/tidb:v8.5.4", name="sf-tidb"):
        super().__init__(image, name)

    def __enter__(self):
        r = docker("run", "-d", "--name", self.name, self.image)
        if r.returncode:
            raise SystemExit(f"docker run {self.image}: {r.stderr.strip()}")
        for _ in range(240):
            if self._client("SELECT 1").returncode == 0:
                return self
            time.sleep(0.5)
        self.__exit__()
        raise SystemExit(f"{self.image} did not answer within two minutes")

    def _client(self, query, stdin=None):
        args = ["run", "--rm", "-i", "--network", f"container:{self.name}", "--entrypoint", "mysql", self.CLIENT,
                "-h127.0.0.1", "-P4000", "-uroot", "-N", "-B", "--raw"]
        return docker(*args, *(["-e", query] if query else []), stdin=stdin)

    def load(self, path):
        r = self._client(None, stdin=open(path, encoding="utf-8", errors="replace").read())
        if r.returncode:
            raise Failed(f"loading {os.path.basename(path)} into {self.image}: {r.stderr.strip()[:300]}")

    def json(self, query):
        r = self._client(query)
        if r.returncode:
            raise Failed(f"{self.image}: {r.stderr.strip()[:300]}")
        out = r.stdout.strip()
        return json.loads(out) if out and out != "NULL" else []


class PostgreSQL:
    def __init__(self, image="postgres:18-alpine", name="sf-postgresql"):
        self.image, self.name = image, f"{name}-{os.getpid()}"

    def __enter__(self):
        r = docker("run", "-d", "--name", self.name, "-e", "POSTGRES_HOST_AUTH_METHOD=trust", self.image)
        if r.returncode:
            raise SystemExit(f"docker run {self.image}: {r.stderr.strip()}")
        for _ in range(240):
            logs = docker("logs", self.name)
            if "PostgreSQL init process complete" in logs.stdout + logs.stderr and \
                    docker("exec", self.name, "psql", "-U", "postgres", "-c", "SELECT 1").returncode == 0:
                return self
            time.sleep(0.25)
        self.__exit__()
        raise SystemExit(f"{self.image} did not answer within a minute")

    def __exit__(self, *exc):
        docker("rm", "-f", "-v", self.name)

    def sql(self, text, db="postgres"):
        r = docker("exec", "-i", self.name, "psql", "-U", "postgres", "-d", db, "-v", "ON_ERROR_STOP=1", "-q", "-At", "-X", stdin=text)
        if r.returncode:
            raise Failed(f"{self.image}: {r.stderr.strip()[:300]}")
        return r.stdout

    def json(self, query, db="postgres"):
        out = self.sql(f"SELECT coalesce(json_agg(x), '[]') FROM ({query}) x;", db).strip()
        return json.loads(out)
