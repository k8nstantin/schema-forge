# Connections: reading a schema from the live database

Every engine reads its schemas two ways: from **files** (a dump, definition files, table metadata) and from **the live
database**, over a connection. This is the design for the live side, agreed before any code: what an engine provides,
what the app shares across engines, how credentials are kept, and how a connection is set up and tested.

## What is shared, and what is the engine's

| Shared by every engine (the app) | Each engine's own (`engines/<database>`) |
|---|---|
| connection profiles, and where their secrets are kept | the fields a connection needs, declared as data |
| the Connections page: list, add, edit, test, remove | how to test a connection: reach, secure, sign in, version, rights |
| testing: running the engine's test and showing every step | how to read the live schema, read-only |
| reading: the engine's live read, with the same report as a file import | the driver, the queries, the parsing |
| the agent's view: connection names only, never a secret | |

## Profiles and secrets

A **connection profile** is a name, an engine, and the values of the fields that engine declares (host, port, user,
database, TLS mode…). Profiles live in the workspace, and **never hold a secret**.

A **secret** (a password, a token) is kept in one of these, chosen per profile:

1. **the operating system's keychain** (macOS Keychain, Windows Credential Manager, the Linux secret service): the
   default when the secret is typed on the Connections page;
2. **a file the database's own tools already use**, by reference: `~/.my.cnf` or a `mysql_config_editor` login path
   for MySQL, `~/.pgpass` or a service file for PostgreSQL;
3. **an environment variable**, by name;
4. **ambient credentials** the database's cloud provides (gcloud application default credentials, an AWS profile),
   for the engines whose catalogs use them.

A secret is never written to the workspace, never logged, never put in a URL, never returned by the server's API and
never seen by the agent. The server serves this machine only (it already refuses other hosts and origins).

## The Connections page

One page in the canvas, shared by every engine, drawn from what each engine declares:

- **the list**: each connection's name, engine, where it points (host and database, never the secret), when it was
  last tested and how that went;
- **adding or editing**: choose the engine, and its form appears, built from the fields it declares (each with its
  label, kind, default and help); the secret field says where the secret will be kept;
- **Test**: runs the engine's test and shows **each step** with what happened, so a failure says exactly where it
  failed:
  1. **reach**: the host answers on the port;
  2. **secure**: TLS as the profile asks (required, verified, or off), and the certificate;
  3. **sign in**: the user and the secret are accepted;
  4. **version**: the server's version, and the engine version a schema read from it will be designed for;
  5. **rights**: the user can read the schema's definitions, and whether it can also change anything (a read-only
     user is recommended, and the test says so when it is not);
- **Read the schema**: reads it into a new schema, or into an existing one to compare, with the same report a file
  import gives.

## What an engine provides

A new optional part of the engine interface, `Live`:

- **its connection fields**, as data: key, label, kind (text, number, one of a list, secret), default, help, required;
  so the Connections page and the agent's tools are built from them, and a new engine's connection form needs no
  canvas code;
- **`test(profile, secret) -> steps`**: the five steps above, each passed or failed with what happened;
- **`read(profile, secret, which) -> the schema and its report`**: read-only, every object the engine models, with
  the report adding up exactly as a file read's does; `which` names the databases (or namespaces) to read.

Every live read uses only statements that read. An engine reads the definitions the way its database writes them
when it can (`SHOW CREATE TABLE`, `SHOW CREATE PROCEDURE` in MySQL), through the same reader its dumps go through, so
a schema read live and one read from a dump of the same database are the same model.

## The agent

The agent sees connection names, their engines and where they point, and can ask to read a schema from one; the
server connects, with the secret it keeps. The agent never sees, sends or chooses a secret, and cannot create a
profile; the person does that on the Connections page.

## Where it is built

- **Each engine's live part** (its connection fields, its test, its live read, and the `Live` part of the interface
  the first engine needs) is built in that engine's own branch and pull request, with its dump reader: the MySQL engine
  first.
- **Connections in the app** (profiles in the workspace, secrets in the keychain or referenced, the Connections page
  with its test, the agent's tools) is its own piece of work, built with the server and the canvas.
