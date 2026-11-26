"""MySQL routines, triggers, events and views written from their facts and their text as written (the body, and a
routine's parameter list), compared with the server's SHOW CREATE.

  python3 lab/mysql_programs.py <snapshot.json> [...]
"""
import json
import re
import sys
from collections import Counter

import mysql_ddl as D


def definer(d):
    user, _, host = d.rpartition("@")
    return f"{D.q(user)}@{D.q(host)}"


def written_params(text, name):
    """The parameter list as written: what is between the parentheses after the routine's name."""
    head = text.index(D.q(name) + "(") + len(D.q(name)) + 1
    depth, i = 1, head
    while depth:
        ch = text[i]
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        elif ch in "'\"`":
            i = text.index(ch, i + 1)
        i += 1
    return text[head:i - 1]


TRAIT = re.compile(r"    (NO SQL|READS SQL DATA|MODIFIES SQL DATA|DETERMINISTIC|SQL SECURITY INVOKER|LANGUAGE \w+|USING \((?:[^)`]|`(?:[^`]|``)*`)*\)|COMMENT '(?:[^'\\]|''|\\.)*')\n")
USES = re.compile(r"`((?:[^`]|``)+)`\.`((?:[^`]|``)+)`(?: AS `((?:[^`]|``)+)`)?")


def uses(text):
    """The libraries a routine uses, in its USING order: (schema, library, alias or None). MySQL 9.7's catalog keeps
    neither the order nor the alias; SHOW CREATE does."""
    m = re.search(r"\n    USING \(((?:[^)`]|`(?:[^`]|``)*`)*)\)\n", text)
    return [tuple(x.replace("``", "`") if x else None for x in u) for u in USES.findall(m.group(1))] if m else []


def body_of(kind, text, name=None):
    """The body exactly as SHOW CREATE holds it. information_schema's ROUTINE_DEFINITION is not it: it undoubles the
    quotes inside string literals."""
    if kind == "routine":
        start = text.index(D.q(name) + "(") + len(D.q(name)) + 1
        i = text.index("\n", start + len(written_params(text, name)) + 1) + 1
        while (m := TRAIT.match(text, i)):
            i = m.end()
        return text[i + 3:] if text.startswith("AS $", i) else text[i:]   # a JavaScript body: its code after AS
    if kind == "library":
        return text[text.index("\nAS ") + 4:]
    if kind == "trigger":
        return text[text.index(" FOR EACH ROW ") + 14:]
    if kind == "event":
        return text[re.search(r" ON COMPLETION (NOT )?PRESERVE (ENABLE|DISABLE( ON SLAVE| ON REPLICA)?)( COMMENT '(?:[^'\\]|''|\\.)*')? DO ", text).end():]
    return text[text.index(" AS ", text.index(D.q(name))) + 4:]


def when(v):
    """A datetime as SHOW CREATE writes it; JSON_OBJECT adds microseconds."""
    return re.sub(r"\.0+$", "", str(v))


def view_algorithm(text):
    return re.match(r"CREATE ALGORITHM=(\w+)", text).group(1)


def routine(r, params_text, body, version):
    out = f"CREATE DEFINER={definer(r['DEFINER'])} {r['ROUTINE_TYPE']} {D.q(r['ROUTINE_NAME'])}({params_text})"
    if r["ROUTINE_TYPE"] == "FUNCTION":
        out += f" RETURNS {r['DTD_IDENTIFIER']}"
        if r.get("CHARACTER_SET_NAME"):
            out += f" CHARSET {r['CHARACTER_SET_NAME']}"
    out += "\n"
    traits = []
    if r["SQL_DATA_ACCESS"] != "CONTAINS SQL":
        traits.append(r["SQL_DATA_ACCESS"])
    if r["IS_DETERMINISTIC"] == "YES":
        traits.append("DETERMINISTIC")
    if r["SECURITY_TYPE"] == "INVOKER":
        traits.append("SQL SECURITY INVOKER")
    external = r.get("LANGUAGE") not in (None, "SQL")
    if external:
        traits.append(f"LANGUAGE {r['LANGUAGE']}")
    if r.get("USING"):
        traits.append("USING (" + ", ".join(f"{D.q(sch)}.{D.q(lib)}" + (f" AS {D.q(alias)}" if alias else "") for sch, lib, alias in r["USING"]) + ")")
    if r.get("ROUTINE_COMMENT"):
        traits.append(f"COMMENT {D.text_lit(r['ROUTINE_COMMENT'])}")
    return out + "".join(f"    {t}\n" for t in traits) + ("AS " if external else "") + body


def library(name, language, comment, body):
    """CREATE LIBRARY as SHOW CREATE LIBRARY writes it (MySQL 9.7)."""
    return (f"CREATE LIBRARY {D.q(name)}\n" + (f"    COMMENT {D.text_lit(comment)}\n" if comment else "")
            + f"    LANGUAGE {language}\nAS {body}")


def trigger(t, body):
    return (f"CREATE DEFINER={definer(t['DEFINER'])} TRIGGER {D.q(t['TRIGGER_NAME'])} {t['ACTION_TIMING']} {t['EVENT_MANIPULATION']} "
            f"ON {D.q(t['EVENT_OBJECT_TABLE'])} FOR EACH ROW {body}")


STATUS = {"ENABLED": "ENABLE", "DISABLED": "DISABLE", "SLAVESIDE_DISABLED": "DISABLE ON SLAVE", "REPLICA_SIDE_DISABLED": "DISABLE ON REPLICA"}


def event(e, body):
    if e.get("INTERVAL_VALUE") is not None:
        v = e["INTERVAL_VALUE"]
        v = v if re.fullmatch(r"\d+", str(v)) else D.text_lit(str(v))
        sched = f"EVERY {v} {e['INTERVAL_FIELD']}" + (f" STARTS '{when(e['STARTS'])}'" if e.get("STARTS") else "") + (f" ENDS '{when(e['ENDS'])}'" if e.get("ENDS") else "")
    else:
        sched = f"AT '{when(e['EXECUTE_AT'])}'"
    out = (f"CREATE DEFINER={definer(e['DEFINER'])} EVENT {D.q(e['EVENT_NAME'])} ON SCHEDULE {sched} ON COMPLETION {e['ON_COMPLETION']} "
           f"{STATUS[e['STATUS']]}")
    if e.get("EVENT_COMMENT"):
        out += f" COMMENT {D.text_lit(e['EVENT_COMMENT'])}"
    return out + f" DO {body}"


def view(v, algorithm, body, version):
    name = D.q(v["TABLE_SCHEMA"]) + "." + D.q(v["TABLE_NAME"])
    out = f"CREATE ALGORITHM={algorithm} DEFINER={definer(v['DEFINER'])} SQL SECURITY {v['SECURITY_TYPE']} VIEW {name} AS {body}"
    if v.get("CHECK_OPTION") and v["CHECK_OPTION"] != "NONE":
        out += f" WITH {v['CHECK_OPTION']} CHECK OPTION"
    return out


def main():
    for path in sys.argv[1:]:
        snap = json.load(open(path))
        version = snap["version"]
        n, exact, why, first = Counter(), Counter(), Counter(), {}
        for p in snap["parts"]:
            pr = p["props"]
            want = pr.get("__show_create")
            if p["kind"] not in ("routine", "trigger", "event", "view") or not want:
                continue
            if p["kind"] == "trigger" and not D.mysql8(version):
                n["trigger kept as written (5.7)"] += 1  # 5.7 gives the statement as it was typed, not one it writes
                exact["trigger kept as written (5.7)"] += 1
                continue
            body = body_of(p["kind"], want, pr.get("ROUTINE_NAME") or pr.get("TABLE_NAME"))
            if p["kind"] == "routine":
                got = routine(pr, written_params(want, pr["ROUTINE_NAME"]), body, version)
            elif p["kind"] == "trigger":
                got = trigger(pr, body)
            elif p["kind"] == "event":
                got = event(pr, body)
            else:
                body = body if not pr.get("CHECK_OPTION") or pr["CHECK_OPTION"] == "NONE" else body[:body.rindex(" WITH ")]
                got = view(pr, view_algorithm(want), body, version)
            n[p["kind"]] += 1
            if got == want:
                exact[p["kind"]] += 1
                continue
            i = next((k for k in range(min(len(got), len(want))) if got[k] != want[k]), min(len(got), len(want)))
            key = f"{p['kind']}: {re.sub('[A-Za-z0-9_]+', 'x', want[max(0, i - 15):i + 15])!r} got {re.sub('[A-Za-z0-9_]+', 'x', got[max(0, i - 15):i + 15])!r}"
            why[key] += 1
        print(f"mysql {version}: " + ", ".join(f"{exact[k]} of {n[k]} {k}s" for k in sorted(n)) + " written exactly")
        for k, c in why.most_common(6):
            print(f"   {c:5} {k}")


if __name__ == "__main__":
    main()
