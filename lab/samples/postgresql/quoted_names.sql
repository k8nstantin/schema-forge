-- PostgreSQL sample: names a reader must quote, a reserved word, overloaded functions, a partition tree, a view on a
-- view, an object in a name with a dot.
CREATE SCHEMA "Quoted Names";
CREATE TABLE "Quoted Names"."Order" ("Select" int PRIMARY KEY, "two words" varchar(10), "dou""ble" int, "ünïcode" text);
CREATE TABLE "Quoted Names"."my.table" (id int PRIMARY KEY, "it's" varchar(5));
COMMENT ON COLUMN "Quoted Names"."my.table"."it's" IS 'a comment with ''quotes'' and a ; semicolon';
CREATE TABLE "Quoted Names"."it's" (id int PRIMARY KEY);
CREATE TABLE "Quoted Names"."MixedCase" (id int PRIMARY KEY);
CREATE TABLE "Quoted Names".mixedcase (id int PRIMARY KEY);
CREATE FUNCTION "Quoted Names".area(r float8) RETURNS float8 LANGUAGE sql IMMUTABLE AS $$ SELECT pi() * r * r $$;
CREATE FUNCTION "Quoted Names".area(w float8, h float8) RETURNS float8 LANGUAGE sql IMMUTABLE AS $$ SELECT w * h $$;
CREATE FUNCTION "Quoted Names"."select"() RETURNS int LANGUAGE sql AS $$ SELECT 1 $$;
CREATE TABLE "Quoted Names".logs (at date NOT NULL, msg text) PARTITION BY RANGE (at);
CREATE TABLE "Quoted Names".logs_2025 PARTITION OF "Quoted Names".logs FOR VALUES FROM ('2025-01-01') TO ('2026-01-01');
CREATE TABLE "Quoted Names".logs_2026 PARTITION OF "Quoted Names".logs FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');
CREATE VIEW "Quoted Names".v1 AS SELECT "Select" FROM "Quoted Names"."Order";
CREATE VIEW "Quoted Names"."v on v" AS SELECT * FROM "Quoted Names".v1;
