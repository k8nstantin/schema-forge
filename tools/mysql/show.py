#!/usr/bin/env python3
"""Shows exactly what a server says: loads the samples for its version into a fresh server, then prints the result of
each statement given, raw. For studying how a version writes an object before the reader reads it.

  python3 tools/mysql/show.py --server mysql:9.7 "SHOW CREATE FUNCTION shop.price_with_tax" "SELECT * FROM information_schema.LIBRARIES"
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
from sf.servers import MySQL  # noqa: E402

ARGS = sys.argv[1:]
IMAGE = ARGS[ARGS.index("--server") + 1] if "--server" in ARGS else "mysql:8.0"
STATEMENTS = [a for i, a in enumerate(ARGS) if a != "--server" and (i == 0 or ARGS[i - 1] != "--server")]


def main():
    sys.argv = [sys.argv[0], "--server", IMAGE]
    import roundtrip  # noqa: E402
    with MySQL(IMAGE, name="sf-show") as s:
        for f in roundtrip.samples(IMAGE):
            s.load(f)
        for st in STATEMENTS:
            print(f"== {st}")
            print(s.sql(st.rstrip(";") + ";\n").replace("\\n", "\n"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
