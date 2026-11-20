# Versions and git

The draft lives in `sf`'s embedded SurrealDB while you and the agent work. **Locked versions live in git:**
locking a version is a commit, so the schema's history, review and sharing are git's, with nothing new to
learn.

## Linking a schema to a repository

A schema is linked to a folder in a git repository (`sf link ../data-platform/schemas/orders`, or chosen
when the schema is created). That folder holds the schema's file form:

```
schemas/orders/
  schema.json                      the model at the last locked version
  rules.toml                       its rules
  versions/0003.json               every locked version, never edited, with its hash
  export/0003_iceberg_spark.sql    the full schema for its target
  migrations/0002_to_0003.sql      what changed since the version before
  CHANGELOG.md                     one entry per version, in words
```

## Locking a version

When you say "lock it" (the agent never locks on its own):

1. The draft is checked: every rule, every inconsistency. A version with failing `error` rules is refused.
2. The file form is written into the linked folder: the version, the export, the migration, the changelog
   entry.
3. **A commit** is made on the current branch, with a message the agent writes from the turn's changes and
   its references: what changed, why (the prompts it served), what it breaks if anything.
4. **A tag** marks it: `schema/orders/v3`.
5. The version records its commit and tag; `@v3` resolves to them.

`sf` never pushes. Pushing, branches and pull requests stay yours (or the agent's, when you ask it to run
git), with the review your team already uses.

## Reading history back

- Every locked version is read from git, so the History perspective shows who locked it, when, on which
  branch, and the commit message, beside the operations that led to it.
- **Any two versions, or any two commits, can be compared** as schemas, not as text: tables, columns,
  keys and views added, changed and removed, drawn on the diagram.
- A teammate's newer version, pulled into the repository, appears in the workspace; opening it makes it
  the draft's base.

## Branches and merging

- A branch can carry its own versions; version numbers are per branch until merged (`v3` on `main`,
  `v3-billing` on `billing`).
- Merging two branches' schemas is done on the model, not on JSON text: `sf merge` compares both with their
  common version, applies what does not conflict, and shows each conflict (the same column changed two
  ways) for you to decide, or for the agent to propose.
- A git merge driver for `schema.json` can call `sf merge`, so `git merge` itself takes the same path.

## Drafts

The draft is not committed; it is in the store. `sf export --draft` writes it to the folder without
locking, for a teammate to look at or for CI to check.

## CI

`sf check <folder>` runs in CI on the file form: rules, inconsistencies, that every migration takes
version N−1 exactly to version N. A pull request that breaks a standard fails like any other check.

## Built on

**gix** (gitoxide), pure Rust: reading history, writing commits and tags, reading a branch's files. Pushing
and fetching are left to the user's git.
