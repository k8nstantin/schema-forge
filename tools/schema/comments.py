"""The comments of a table file, kept in one place.

A table file is a header of `--` lines, one CREATE TABLE whose every column carries its comment on its line, and then
the COMMENT ON statements that put the same words into the database. The inline comments are the source: this tool
writes the COMMENT ON statements from them (`--write`), or reports every file whose statements differ (`--check`).
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
QUOTE = {"desc", "binary", "columns", "column", "index", "trigger", "on", "unique", "deferrable", "connection", "collation"}
TYPES = {"TEXT", "INTEGER", "NUMERIC", "BOOLEAN", "UUID", "TIMESTAMPTZ", "JSONB", "BIGINT"}
COLUMN = re.compile(r'^(\s+)("?[a-z_]+"?)\s+([A-Z]+)\b(.*)$')


def files():
    for pattern in ("schema/*/*.sql", "engines/*/schema/*.sql"):
        for f in sorted(ROOT.glob(pattern)):
            yield f


def split_comment(line):
    quoted = False
    for i, c in enumerate(line):
        if c == "'":
            quoted = not quoted
        elif not quoted and line.startswith("--", i):
            return line[:i].rstrip(), line[i + 2:].strip()
    return line.rstrip(), None


def literal(text):
    return "'" + text.replace("'", "''") + "'"


def ident(name):
    return f'"{name}"' if name in QUOTE else name


def expected(path):
    """The file as it should be: its table aligned, and its COMMENT ON statements written from its comments."""
    lines = path.read_text().split("\n")
    start = next(i for i, l in enumerate(lines) if l.startswith("CREATE TABLE "))
    end = next(i for i in range(start, len(lines)) if lines[i].startswith(");"))
    table = lines[start].split()[2]
    header = []
    for l in lines[:start]:
        header.append(l[3:] if l.startswith("-- ") else l)
    about = " ".join(header)
    about = re.sub(r"^[\w.]+: ", "", about)
    about = re.sub(r"\s*Owner: [a-z_]+\.", "", about).strip()
    body, notes = [], []
    for l in lines[start + 1:end]:
        code, comment = split_comment(l)
        m = COLUMN.match(code)
        if m and m.group(3) in TYPES:
            if comment is None:
                raise SystemExit(f"{path.relative_to(ROOT)}: column {m.group(2)} has no comment")
            notes.append((m.group(2).strip('"'), comment))
        code = re.sub(r"(\w) ,", r"\1,", code)
        body.append((code, comment, m.groups() if m and m.group(3) in TYPES else None))
    names = max((len(g[1]) for _, _, g in body if g), default=0)
    types = max((len(g[2]) for _, _, g in body if g), default=0)
    body = [
        ((f"  {g[1].ljust(names)}  {(g[2] + g[3]).strip() if not g[3].strip() or g[3].strip()[0] == ',' else g[2].ljust(types) + ' ' + g[3].strip()}") if g else c, n)
        for c, n, g in body
    ]
    short = [len(c) for c, n in body if n is not None and len(c) <= 100]
    width = max([80] + [s + 2 for s in short])
    out = lines[: start + 1]
    for code, comment in body:
        out.append(code if comment is None else (code.ljust(width) if len(code) < width else code + "  ") + "-- " + comment)
    out.append(lines[end])
    tail = [l for l in lines[end + 1:] if l and not l.startswith("COMMENT ON ")]
    out += tail
    out.append("")
    out.append(f"COMMENT ON TABLE {table} IS {literal(about)};")
    for name, comment in notes:
        out.append(f"COMMENT ON COLUMN {table}.{ident(name)} IS {literal(comment)};")
    return "\n".join(out) + "\n"


def main():
    write = "--write" in sys.argv
    wrong = []
    for f in files():
        if "CREATE TABLE " not in f.read_text():
            continue
        want = expected(f)
        if f.read_text() != want:
            if write:
                f.write_text(want)
            else:
                wrong.append(str(f.relative_to(ROOT)))
    for w in wrong:
        print(f"{w}: its COMMENT ON statements or alignment differ from its comments; run python3 tools/schema/comments.py --write")
    return 1 if wrong else 0


if __name__ == "__main__":
    sys.exit(main())
