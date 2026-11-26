"""Is the schema of this machine's schema_forge still the locked one? Data changes are not drift: a schema-only dump
holds none.

Dumps the live database's schema (pg_dump --schema-only, as the read-only sf_reader, whose password is in the accounts
file: no DBA password is used or kept), takes out what differs between any two dumps (the versions named, pg_dump's
random restrict key, trailing blank lines), and compares it line by line with the locked dump of the version installed,
which tools/local/install.py saves as it installs. One line a run goes to <private>/drift/check.log; a drift writes its
difference to <private>/drift/<time>.diff and shows a notification.

  python3 tools/local/schema_drift.py                      check now: 0 no drift, 1 drift, 2 no baseline, 3 cannot dump
  python3 tools/local/schema_drift.py --schedule           check every hour (a launchd agent), and once now
  python3 tools/local/schema_drift.py --unschedule         stop the hourly check
  --private DIR    where the accounts file, the baseline and the log are (default ~/schema-forge-lab-private)
"""
import datetime
import difflib
import os
import plistlib
import re
import subprocess
import sys

BIN = "/opt/homebrew/opt/postgresql@18/bin"
AGENT = "com.schemaforge.drift"
PLIST = os.path.expanduser(f"~/Library/LaunchAgents/{AGENT}.plist")


def private_dir():
    args = sys.argv[1:]
    return os.path.expanduser(args[args.index("--private") + 1] if "--private" in args else "~/schema-forge-lab-private")


def normal(text):
    """A dump without what changes from run to run, as tools/schema_dump.py takes it out, and no trailing blank lines."""
    keep = [line for line in text.splitlines() if not line.startswith(("-- Dumped from", "-- Dumped by", "\\restrict", "\\unrestrict"))]
    while keep and not keep[-1].strip():
        keep.pop()
    return keep


def accounts(path):
    out = {}
    for line in open(path):
        m = re.match(r"^\s*(?:export\s+)?([A-Z_]+)=(.*)$", line.strip())
        if m:
            out[m.group(1)] = m.group(2).strip().strip("'\"")
    return out


def notify(text):
    subprocess.run(["osascript", "-e", f'display notification "{text}" with title "SchemaForge schema drift"'], capture_output=True)


def check(private):
    now = datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%S")
    os.makedirs(os.path.join(private, "drift"), exist_ok=True)
    log = os.path.join(private, "drift", "check.log")

    def say(line):
        print(f"{now} {line}")
        with open(log, "a") as f:
            f.write(f"{now} {line}\n")
    baseline = os.path.join(private, "installed", "schema_forge.sql")
    if not os.path.exists(baseline):
        say(f"NO BASELINE: {baseline} is missing; install with tools/local/install.py")
        notify("No baseline to compare with")
        return 2
    env = dict(os.environ, PGPASSWORD=accounts(os.path.join(private, "local-accounts.env"))["SF_READER_PASSWORD"])
    r = subprocess.run([f"{BIN}/pg_dump", "-h", "127.0.0.1", "-U", "sf_reader", "--schema-only", "schema_forge"],
                       capture_output=True, text=True, env=env)
    if r.returncode or r.stderr.strip():
        say(f"CANNOT DUMP: {r.stderr.strip().splitlines()[0] if r.stderr.strip() else 'pg_dump failed'}")
        notify("Could not dump schema_forge")
        return 3
    live = normal(r.stdout)
    locked = normal("\n".join(open(baseline).read().splitlines()[2:]))   # its two header lines name the file, not the schema
    ref = open(os.path.join(private, "installed", "ref")).read().strip() if os.path.exists(os.path.join(private, "installed", "ref")) else "?"
    if live == locked:
        say(f"no drift ({len(live)} lines, as installed: {ref})")
        return 0
    diff = list(difflib.unified_diff(locked, live, "locked", "live", lineterm=""))
    out = os.path.join(private, "drift", datetime.datetime.now().strftime("%Y%m%dT%H%M%S") + ".diff")
    open(out, "w").write("\n".join(diff) + "\n")
    changed = sum(1 for d in diff if d[:1] in "+-" and not d.startswith(("+++", "---")))
    say(f"DRIFT: {changed} lines differ from the locked schema ({ref}); see {out}")
    notify(f"{changed} lines differ from the locked schema")
    return 1


def schedule(private):
    """An hourly launchd agent, run at login too; its own output goes beside the log."""
    os.makedirs(os.path.dirname(PLIST), exist_ok=True)
    plistlib.dump({"Label": AGENT, "ProgramArguments": [sys.executable, "-B", os.path.abspath(__file__), "--private", private],
                   "StartInterval": 3600, "RunAtLoad": True,
                   "StandardOutPath": os.path.join(private, "drift", "agent.out"), "StandardErrorPath": os.path.join(private, "drift", "agent.err")},
                  open(PLIST, "wb"))
    uid = os.getuid()
    subprocess.run(["launchctl", "bootout", f"gui/{uid}/{AGENT}"], capture_output=True)
    r = subprocess.run(["launchctl", "bootstrap", f"gui/{uid}", PLIST], capture_output=True, text=True)
    if r.returncode:
        raise SystemExit(f"launchctl: {r.stderr.strip()}")
    print(f"the drift check runs every hour ({PLIST}); its log: {os.path.join(private, 'drift', 'check.log')}")


def unschedule():
    subprocess.run(["launchctl", "bootout", f"gui/{os.getuid()}/{AGENT}"], capture_output=True)
    if os.path.exists(PLIST):
        os.remove(PLIST)
    print("the hourly drift check is stopped")


def main():
    private = private_dir()
    if "--unschedule" in sys.argv:
        return unschedule()
    if "--schedule" in sys.argv:
        os.makedirs(os.path.join(private, "drift"), exist_ok=True)
        schedule(private)
        return 0
    return check(private)


if __name__ == "__main__":
    sys.exit(main() or 0)
