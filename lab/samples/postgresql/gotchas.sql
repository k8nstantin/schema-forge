-- PostgreSQL gotchas: names a reader must quote, a reserved word, overloaded functions, a partition tree, a view on a
-- view, an object in a name with a dot.
CREATE SCHEMA "Gotcha Zone";
CREATE TABLE "Gotcha Zone"."Order" ("Select" int PRIMARY KEY, "two words" varchar(10), "dou""ble" int, "ünïcode" text);
CREATE TABLE "Gotcha Zone"."my.table" (id int PRIMARY KEY, "it's" varchar(5));
COMMENT ON COLUMN "Gotcha Zone"."my.table"."it's" IS 'a comment with ''quotes'' and a ; semicolon';
CREATE TABLE "Gotcha Zone"."it's" (id int PRIMARY KEY);
CREATE TABLE "Gotcha Zone"."MixedCase" (id int PRIMARY KEY);
CREATE TABLE "Gotcha Zone".mixedcase (id int PRIMARY KEY);
CREATE FUNCTION "Gotcha Zone".area(r float8) RETURNS float8 LANGUAGE sql IMMUTABLE AS $$ SELECT pi() * r * r $$;
CREATE FUNCTION "Gotcha Zone".area(w float8, h float8) RETURNS float8 LANGUAGE sql IMMUTABLE AS $$ SELECT w * h $$;
CREATE FUNCTION "Gotcha Zone"."select"() RETURNS int LANGUAGE sql AS $$ SELECT 1 $$;
CREATE TABLE "Gotcha Zone".logs (at date NOT NULL, msg text) PARTITION BY RANGE (at);
CREATE TABLE "Gotcha Zone".logs_2025 PARTITION OF "Gotcha Zone".logs FOR VALUES FROM ('2025-01-01') TO ('2026-01-01');
CREATE TABLE "Gotcha Zone".logs_2026 PARTITION OF "Gotcha Zone".logs FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');
CREATE VIEW "Gotcha Zone".v1 AS SELECT "Select" FROM "Gotcha Zone"."Order";
CREATE VIEW "Gotcha Zone"."v on v" AS SELECT * FROM "Gotcha Zone".v1;
