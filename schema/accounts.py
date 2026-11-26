#!/usr/bin/env python3
"""The service accounts of a SchemaForge PostgreSQL cluster (decision database-roles in specs/root.xml).

  sf_owner    no login: owns every namespace, table, view and function; the only role that changes the schema
  sf_service  the app's account: reads and writes rows, runs the rules; creates, alters and drops nothing
  sf_agent    a coding agent's account: reads everything, writes the design's rows with the log's new rows; creates,
              alters and drops nothing, never rewrites the log nor changes what is locked
  sf_reader   reads only

Each login account gets a strong random password, set over psql's standard input (never on a command line) and
written only to the accounts file, mode 600; nothing prints a password. Run again, it rotates them.

  python3 schema/accounts.py [--host H] [--port P] [--user postgres] [--accounts-file PATH]

It asks for the superuser's password (or reads SF_ROOT_PASSWORD, for automation). PSQL names the psql command to run
(default: psql).
"""
import argparse
import getpass
import os
import secrets
import shlex
import stat
import subprocess
import sys

LOGINS = ("sf_service", "sf_agent", "sf_reader")
DEFAULT_FILE = os.path.expanduser("~/.schemaforge/accounts.env")


def psql_command():
    return shlex.split(os.environ.get("PSQL", "psql"))


def run(conn, sql, db="postgres", user=None, password=None):
    """SQL sent to psql's standard input, as the superuser or as the given account."""
    env = dict(os.environ, PGPASSWORD=password if password is not None else conn["password"])
    args = psql_command() + ["-h", conn["host"], "-p", str(conn["port"]), "-U", user or conn["user"], "-d", db,
                             "-v", "ON_ERROR_STOP=1", "-q", "-At", "-X"]
    return subprocess.run(args, input=sql, capture_output=True, text=True, env=env)


def ok(r, what):
    if r.returncode:
        raise SystemExit(f"{what}: {r.stderr.strip()[-400:]}")
    return r.stdout.strip()


def connection(args):
    password = os.environ.get("SF_ROOT_PASSWORD")
    if password is None:
        password = getpass.getpass(f"password of the PostgreSQL superuser {args.user}@{args.host}:{args.port}: ")
    conn = {"host": args.host, "port": args.port, "user": args.user, "password": password}
    version = ok(run(conn, "SHOW server_version_num;"), f"connecting as {args.user}")
    if int(version) < 180000:
        raise SystemExit(f"PostgreSQL 18 or later is needed (uuidv7()); this server is {version}")
    if ok(run(conn, "SELECT rolsuper FROM pg_roles WHERE rolname = current_user;"), "checking the account") != "t":
        raise SystemExit(f"{args.user} is not a superuser: making roles needs one")
    return conn


def make_accounts(conn, accounts_file):
    """The four roles, made or kept; every login account given a new password, saved to the accounts file."""
    sql = ["DO $$ BEGIN CREATE ROLE sf_owner NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END $$;"]
    passwords = {}
    for role in LOGINS:
        passwords[role] = secrets.token_urlsafe(32)
        sql.append(f"DO $$ BEGIN CREATE ROLE {role} LOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END $$;")
        sql.append(f"ALTER ROLE {role} LOGIN PASSWORD '{passwords[role]}';")
    sql.append("ALTER ROLE sf_owner NOLOGIN;")
    ok(run(conn, "\n".join(sql)), "making the roles")
    os.makedirs(os.path.dirname(accounts_file), exist_ok=True)
    fd = os.open(accounts_file, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, stat.S_IRUSR | stat.S_IWUSR)
    with os.fdopen(fd, "w") as f:
        f.write("# SchemaForge service accounts: keep this file private (mode 600); never commit it.\n")
        f.write(f"SF_PGHOST={conn['host']}\nSF_PGPORT={conn['port']}\n")
        for role, pw in passwords.items():
            f.write(f"{role.upper()}_PASSWORD={pw}\n")
    os.chmod(accounts_file, stat.S_IRUSR | stat.S_IWUSR)
    return passwords


def parser():
    p = argparse.ArgumentParser(description="Make or rotate SchemaForge's service accounts.")
    p.add_argument("--host", default=os.environ.get("PGHOST", "127.0.0.1"))
    p.add_argument("--port", type=int, default=int(os.environ.get("PGPORT", "5432")))
    p.add_argument("--user", default="postgres", help="a superuser (default postgres)")
    p.add_argument("--accounts-file", default=DEFAULT_FILE, help=f"where the passwords are written (default {DEFAULT_FILE})")
    return p


def main():
    args = parser().parse_args()
    conn = connection(args)
    make_accounts(conn, args.accounts_file)
    print(f"service accounts {', '.join(LOGINS)} ready; their passwords are in {args.accounts_file} (mode 600)")


if __name__ == "__main__":
    sys.exit(main())
