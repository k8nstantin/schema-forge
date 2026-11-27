#!/usr/bin/env python3
"""Every proof of the cortex, in order, each in its own fresh containers: load, ids, dump, history, privileges, samples,
and the installer (tools/local/test_install.py).
CI runs this on every pull request; the same command runs here.

  python3 tools/cortex/all.py
"""
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = ["load", "ids", "dump", "history", "privileges", "samples", "install"]


def main():
    results = []
    for t in TOOLS:
        start = time.time()
        print(f"== tools/cortex/{t}.py", flush=True)
        path = os.path.join(HERE, f"{t}.py") if t != "install" else os.path.join(os.path.dirname(HERE), "local", "test_install.py")
        r = subprocess.run([sys.executable, path])
        results.append((t, r.returncode, time.time() - start))
    print("\n== the cortex")
    for t, rc, s in results:
        print(f"  {'pass' if rc == 0 else 'FAIL'}  {t:11} {s:6.1f} s")
    failed = [t for t, rc, _ in results if rc]
    print(f"{'pass' if not failed else 'FAIL'}  cortex: {len(TOOLS) - len(failed)} of {len(TOOLS)} tools")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
