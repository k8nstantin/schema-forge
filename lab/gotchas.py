"""The lab's gotcha suite, on every server: the names a reader must quote, a reserved word, the same name in two
cases, a view whose table is gone, PostgreSQL's overloaded functions and partition trees. Every object must be in
the roster once, every definition read or reported unreadable with the server's reason, nothing lost in silence.

  python3 lab/gotchas.py
"""
import probe as P

EXPECT = {
    "mysql": {("table", "Order"), ("table", "my.table"), ("table", "it's"), ("table", "MixedCase"), ("table", "mixedcase"),
              ("view", "v broken"), ("procedure", "select")},
    "postgresql": {("table", "Order"), ("table", "my.table"), ("table", "it's"), ("table", "MixedCase"), ("table", "mixedcase"),
                   ("function", '"Gotcha Zone".area(double precision)'), ("function", '"Gotcha Zone".area(double precision,double precision)'),
                   ("function", '"Gotcha Zone"."select"()'), ("partitioned table", "logs"), ("partition", "logs_2025"),
                   ("partition", "logs_2026"), ("view", "v1"), ("view", "v on v")},
}


def main():
    failures = 0
    for engine, container in P.SERVERS:
        s = P.Server(engine, container)
        probed = P.probe(s)
        zone = [o for o in probed["roster"] if o["schema"] == "Gotcha Zone"]
        got = {(o["kind"], o["name"]) for o in zone}
        missing = EXPECT[engine] - got
        twice = len(zone) - len({(o["kind"], o["name"]) for o in zone})
        read = P.read(s, probed, {"objects": [o["display"] for o in zone], "groups": None})
        empty = [k for k, v in read["definitions"].items() if not any(v)]
        unread = read.get("unread", {})
        lost = len(zone) - len(read["definitions"]) - len(unread)
        ok = not missing and not twice and not empty and not lost
        failures += not ok
        print(f"  {'pass' if ok else 'FAIL'}  {engine} {probed['version'].split('-')[0]:8} {len(zone):2} objects, "
              f"{len(read['definitions'])} read, {len(unread)} unreadable"
              + (f"; missing {sorted(missing)}" if missing else "") + (f"; {twice} listed twice" if twice else "")
              + (f"; empty {empty}" if empty else "") + (f"; {lost} lost in silence" if lost else ""))
        for k, why in unread.items():
            print(f"        unreadable, as the server says: {k}: {why}")
        if engine == "postgresql":
            parts = [o for o in zone if o["kind"] == "partition"]
            bounds = [read["definitions"].get(f"partition {o['display']}", [[[]]])[0] for o in parts]
            print(f"        partitions with their parent and bounds: {[b[0][1] + ' ' + b[0][0] for b in bounds if b and b[0]]}")
    print(f"== {failures} servers failed")


if __name__ == "__main__":
    main()
