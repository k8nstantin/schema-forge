#!/usr/bin/env python3
"""Every proof of the Rust app, in order; CI runs it, and it is the only way the app is built, linted or tested here:

  1. the toolchain: cargo and rustup, at the version rust-toolchain.toml pins
  2. format: cargo fmt --check
  3. lint: cargo clippy on every crate and target, warnings failing it
  4. licences and advisories: cargo deny check (skipped, and said so, where cargo-deny is not installed)
  5. build: the workspace, from the committed Cargo.lock
  6. a store: PostgreSQL 18 in a container, schema_forge installed as the installer makes it (the cortex and every
     engine package), every service account with its own random password, written to an accounts file (mode 600)
  7. tests: cargo test on every crate against that store (SF_TEST_* name it)
  8. the binary: schema-forge check signs in as every account and reports
  9. the store dropped, its volume with it (--keep leaves it running and prints how to reach it)

  python3 tools/app/all.py [--update-lock] [--lint] [--test NAME] [--keep]

--update-lock writes Cargo.lock afresh first (after a dependency changed; commit it); --format formats the code
first (cargo fmt), so the format check then passes; --lint stops after step 5;
--test NAME runs only the tests whose name holds NAME.
"""
import os
import secrets
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.dirname(HERE))
from sf.plugin import engine_folders, install_all, package  # noqa: E402
from sf.store import Store  # noqa: E402

ARGS = sys.argv[1:]
CORTEX = ("cortex_service", "cortex_agent", "cortex_reader")


def run(label, cmd, env=None):
    """One step: its command in the repository, its output as it comes; returns True when it passed."""
    print(f"== {label}: {' '.join(cmd)}", flush=True)
    start = time.time()
    r = subprocess.run(cmd, cwd=ROOT, env=dict(os.environ, **(env or {})))
    print(f"  {'pass' if r.returncode == 0 else 'FAIL'}  {label} ({time.time() - start:.1f} s)", flush=True)
    return r.returncode == 0


def main():
    results = []
    if not shutil.which("cargo"):
        print("FAIL  toolchain: cargo is not installed (https://rustup.rs installs it; rust-toolchain.toml picks the version)")
        return 1
    steps = [("toolchain", ["cargo", "--version"])]
    if "--update-lock" in ARGS:
        steps.append(("Cargo.lock", ["cargo", "generate-lockfile"]))
    if "--format" in ARGS:
        steps.append(("formatting", ["cargo", "fmt", "--all"]))
    steps += [("format", ["cargo", "fmt", "--all", "--check"]),
             ("lint", ["cargo", "clippy", "--workspace", "--all-targets", "--locked", "--", "-D", "warnings"])]
    if shutil.which("cargo-deny"):
        steps.append(("licences and advisories", ["cargo", "deny", "check"]))
    else:
        print("note  cargo-deny is not installed here: licences and advisories are checked in CI only")
    steps.append(("build", ["cargo", "build", "--workspace", "--all-targets", "--locked"]))
    for label, cmd in steps:
        results.append((label, run(label, cmd)))
        if not results[-1][1]:
            return report(results)
    if "--lint" in ARGS:
        return report(results)

    print("== a store: PostgreSQL 18 in a container, schema_forge installed", flush=True)
    store = Store("sf-app", published=True).__enter__()
    try:
        plugins = [package(f)[0]["namespace"] for f in engine_folders()]
        accounts = list(CORTEX) + [f"{ns}_service" for ns in plugins]
        passwords = {a: secrets.token_urlsafe(24) for a in accounts}
        store.sql("".join(f"ALTER ROLE {a} PASSWORD '{passwords[a]}';\n" for a in CORTEX), db="postgres")
        install_all(store, passwords)
        folder = tempfile.mkdtemp(prefix="sf-app-")
        path = os.path.join(folder, "accounts.env")
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write("".join(f"{a.upper()}_PASSWORD={p}\n" for a, p in passwords.items()))
        print(f"  pass  installed on 127.0.0.1:{store.port}: the cortex and {', '.join(plugins)}; {len(accounts)} accounts", flush=True)
        env = {"SF_TEST_HOST": "127.0.0.1", "SF_TEST_PORT": store.port, "SF_TEST_ACCOUNTS": path, "SF_TEST_CONTAINER": store.name}
        test = ["cargo", "test", "--workspace", "--locked"]
        if "--test" in ARGS:
            test += [ARGS[ARGS.index("--test") + 1]]
        results.append(("tests", run("tests", test, env)))
        results.append(("schema-forge check", run("schema-forge check", ["cargo", "run", "--quiet", "--locked", "--bin", "schema-forge", "--", "check",
                                                                       "--host", "127.0.0.1", "--port", store.port, "--accounts-file", path])))
    finally:
        if "--keep" in ARGS:
            print(f"  kept: {store.name} on 127.0.0.1:{store.port}, its accounts in {path}; drop both with: "
                  f"docker rm -f -v {store.name} && rm -r {folder}")
        else:
            store.__exit__(None, None, None)
            if "folder" in locals():
                shutil.rmtree(folder, ignore_errors=True)
    return report(results)


def report(results):
    print("\n== the app")
    for label, ok in results:
        print(f"  {'pass' if ok else 'FAIL'}  {label}")
    failed = [label for label, ok in results if not ok]
    print(f"{'pass' if not failed else 'FAIL'}  app: {len(results) - len(failed)} of {len(results)} steps")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
