# Versions and the definitions folder

The draft lives in `sf`'s embedded SurrealDB while you and the agent work. Locked versions are written as
**definitions**: one SQL file per object, in a folder whose path says where the object lives. The folder is
a plain directory; in a git repository, locking a version is also a commit.

## The definitions folder

```
definitions/
  <node>/                               the server or catalog: prod-mysql, analytics-pg, lakehouse
    <database>/                         a MySQL or PostgreSQL database, an Iceberg catalog
      <schema>/                         a PostgreSQL schema, an Iceberg namespace (MySQL has none: skipped)
        tables/orders.sql               CREATE TABLE orders (…), with its keys, indexes and comments
        tables/customers.sql
        views/current_orders.sql        CREATE VIEW current_orders AS …
        sequences/orders_seq.sql        PostgreSQL
        types/order_status.sql          PostgreSQL enum and domain types
        kept/0001_function_audit.sql    statements carried through verbatim, in their order
      .sf/
        model.json                      what SQL cannot say: ids, tags, areas, patterns, logical relationships, layout
        rules.toml                      the schema's rules
        versions/0003.json              each locked version: its number, hash, and every file's hash
        migrations/0002_to_0003.sql     what changed since the version before
        CHANGELOG.md                    one entry per version, in words
```

So an object's path reads like its address: `prod-mysql / shop / tables / orders.sql`, or
`lakehouse / glue / analytics.sales / tables / orders.sql`.

- **Each file is valid SQL for the target**, the way that target writes it: MySQL and PostgreSQL DDL;
  for Iceberg, Spark SQL (`CREATE TABLE … USING iceberg PARTITIONED BY … TBLPROPERTIES …`), with the
  dialect chosen in the rules.
- **The SQL plus `.sf/model.json` is the whole model.** `sf` reads the folder back into exactly the same
  schema; the round-trip tests prove it.
- **Order:** foreign keys sit in their table's file; `sf export` and deploy put the files in dependency
  order (tables before the views that read them, referenced tables first).

## Git, or not

The folder works the same either way.

| | A plain folder | A folder in a git repository |
|---|---|---|
| Locking a version | rewrites the definitions; adds the version, the migration, the changelog entry | the same, then **a commit** with the agent's message and **a tag** `schema/<name>/v3` |
| History | kept by `sf` (the store holds every version) | git's: who, when, which branch, the message |
| Sharing | copy the folder | push, pull requests, review: yours, as usual |

**A plain folder can become part of a repository later.** Put it in a repo (`git init`, or move it into
one), and `sf git adopt` writes the history `sf` kept as commits, one per locked version, oldest first,
with their tags, so nothing is lost by starting without git.

`sf` never pushes; pushing, branches and pull requests stay with you.

## Locking a version

When you say "lock it" (the agent never locks on its own):

1. The draft is checked: every rule, every inconsistency. Failing `error` rules refuse the lock.
2. The definitions are written: changed objects' files rewritten, new ones added, dropped ones removed.
3. `.sf/` gains the version (with every file's hash), the migration, and a changelog entry.
4. In a git repository: a commit, written by the agent from the turn's changes and the prompts behind them,
   and a tag.
5. `@v3` resolves to the version, and to its commit when there is one.

## Reading history back

- The History perspective shows every version: when, by whom (from git when there is one), what changed.
- **Any two versions compare as schemas**, not as text, drawn on the diagram; in git, any two commits too.
- Because each object is its own file, a version's change is also readable as a plain file diff: one
  table changed, one file changed.

## Branches and merging (in git)

- A branch carries its own versions; numbers are per branch until merged.
- `sf merge` merges on the model against the common version, applies what does not conflict, and shows
  each conflict for you to decide or the agent to propose. A git merge driver lets `git merge` take the
  same path; with one file per object, most merges touch different files and never conflict.

## CI

`sf check <folder>` reads the definitions and checks rules, inconsistencies, and that each migration takes
version N−1 exactly to version N. A pull request that breaks a standard fails like any other check.

## Built on

**gix** (gitoxide), pure Rust: reading history, writing commits and tags. Pushing and fetching are left to
the user's git.
