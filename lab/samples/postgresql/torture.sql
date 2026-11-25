-- PostgreSQL torture schema, every PostgreSQL from 14: what PostgreSQL has, much of it MySQL has not.
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS citext;
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE SCHEMA torture;
CREATE SCHEMA audit;
COMMENT ON SCHEMA torture IS 'every kind of object';
CREATE TYPE torture.status AS ENUM ('new', 'paid', 'shipped');
CREATE TYPE torture.address AS (street text, city text, zip varchar(10));
CREATE TYPE torture.floatrange AS RANGE (subtype = float8);
CREATE DOMAIN torture.money_amount AS numeric(18,4) NOT NULL DEFAULT 0 CHECK (VALUE >= 0);
CREATE DOMAIN torture.email AS citext CHECK (VALUE ~ '@');
CREATE SEQUENCE torture.ticket_seq AS bigint START 1000 INCREMENT 5 MINVALUE 1000 MAXVALUE 9999999 CACHE 10 CYCLE;
CREATE COLLATION torture.ci (provider = icu, locale = 'und-u-ks-level2', deterministic = false);
CREATE TABLE torture.kinds (
  id bigint GENERATED ALWAYS AS IDENTITY (START WITH 10 INCREMENT BY 2) PRIMARY KEY,
  ticket bigint NOT NULL DEFAULT nextval('torture.ticket_seq'),
  amount torture.money_amount,
  mail torture.email,
  status torture.status NOT NULL DEFAULT 'new',
  home torture.address,
  tags text[] DEFAULT '{}',
  doc jsonb,
  ident uuid DEFAULT gen_random_uuid(),
  window_ tstzrange,
  ratio double precision,
  name text COLLATE torture.ci NOT NULL,
  name_upper text GENERATED ALWAYS AS (upper(name)) STORED,
  CONSTRAINT ck_ratio CHECK (ratio BETWEEN 0 AND 1) NOT VALID
);
ALTER SEQUENCE torture.ticket_seq OWNED BY torture.kinds.ticket;
COMMENT ON TABLE torture.kinds IS 'every column type';
COMMENT ON COLUMN torture.kinds.amount IS 'never negative';
CREATE UNIQUE INDEX uk_name ON torture.kinds (lower(name)) INCLUDE (status) WHERE status <> 'shipped';
CREATE INDEX k_tags ON torture.kinds USING gin (tags);
CREATE INDEX k_doc ON torture.kinds USING gin (doc jsonb_path_ops);
CREATE INDEX k_name_trgm ON torture.kinds USING gist (name gist_trgm_ops);
CREATE INDEX k_window ON torture.kinds USING gist (window_);
CREATE INDEX k_ident_brin ON torture.kinds USING brin (id) WITH (pages_per_range = 32);
CREATE INDEX k_status_desc ON torture.kinds (status DESC NULLS LAST, id);
CREATE TABLE torture.parent (id int PRIMARY KEY, code char(3) NOT NULL UNIQUE);
CREATE TABLE torture.child (
  id int PRIMARY KEY, parent_id int, parent_code char(3),
  CONSTRAINT fk_parent FOREIGN KEY (parent_id) REFERENCES torture.parent (id) ON DELETE CASCADE ON UPDATE SET NULL DEFERRABLE INITIALLY DEFERRED,
  CONSTRAINT fk_code FOREIGN KEY (parent_code) REFERENCES torture.parent (code) MATCH FULL ON DELETE RESTRICT
);
CREATE TABLE torture.booking (room int, during tstzrange, EXCLUDE USING gist (room WITH =, during WITH &&));
CREATE TABLE torture.measurements (id bigint, taken date NOT NULL, region text, value numeric) PARTITION BY RANGE (taken);
CREATE TABLE torture.measurements_2024 PARTITION OF torture.measurements FOR VALUES FROM ('2024-01-01') TO ('2025-01-01');
CREATE TABLE torture.measurements_2025 PARTITION OF torture.measurements FOR VALUES FROM ('2025-01-01') TO ('2026-01-01') PARTITION BY LIST (region);
CREATE TABLE torture.measurements_2025_east PARTITION OF torture.measurements_2025 FOR VALUES IN ('east');
CREATE TABLE torture.measurements_2025_rest PARTITION OF torture.measurements_2025 DEFAULT;
CREATE TABLE torture.by_hash (id int) PARTITION BY HASH (id);
CREATE TABLE torture.by_hash_0 PARTITION OF torture.by_hash FOR VALUES WITH (MODULUS 2, REMAINDER 0);
CREATE TABLE torture.by_hash_1 PARTITION OF torture.by_hash FOR VALUES WITH (MODULUS 2, REMAINDER 1);
CREATE TABLE torture.base_event (id int, at timestamptz);
CREATE TABLE torture.click_event (url text) INHERITS (torture.base_event);
CREATE UNLOGGED TABLE torture.scratch (k text PRIMARY KEY, v text) WITH (fillfactor = 70, autovacuum_enabled = false);
CREATE VIEW torture.v_paid WITH (security_barrier = true) AS SELECT id, name FROM torture.kinds WHERE status = 'paid' WITH CASCADED CHECK OPTION;
CREATE MATERIALIZED VIEW torture.mv_counts AS SELECT status, count(*) AS n FROM torture.kinds GROUP BY status WITH NO DATA;
CREATE UNIQUE INDEX mv_counts_status ON torture.mv_counts (status);
CREATE FUNCTION torture.f_cents(m numeric) RETURNS bigint LANGUAGE sql IMMUTABLE PARALLEL SAFE STRICT AS $$ SELECT (m * 100)::bigint $$;
CREATE FUNCTION torture.f_paid(p_status torture.status DEFAULT 'paid') RETURNS TABLE (id bigint, name text) LANGUAGE plpgsql STABLE SECURITY DEFINER
  SET search_path = torture AS $$ BEGIN RETURN QUERY SELECT k.id, k.name FROM torture.kinds k WHERE k.status = p_status; END $$;
CREATE PROCEDURE torture.p_purge(INOUT n int) LANGUAGE plpgsql AS $$ BEGIN DELETE FROM torture.scratch; n := 0; END $$;
CREATE FUNCTION audit.log_change() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NULL; END $$;
CREATE TRIGGER t_child_audit AFTER INSERT ON torture.child REFERENCING NEW TABLE AS new_rows
  FOR EACH STATEMENT EXECUTE FUNCTION audit.log_change();
CREATE TRIGGER t_child_when BEFORE UPDATE ON torture.child FOR EACH ROW WHEN (OLD.parent_id IS DISTINCT FROM NEW.parent_id)
  EXECUTE FUNCTION audit.log_change();
ALTER TABLE torture.kinds ENABLE ROW LEVEL SECURITY;
CREATE POLICY own_rows ON torture.kinds FOR SELECT TO PUBLIC USING (status <> 'shipped');
CREATE RULE r_scratch AS ON DELETE TO torture.scratch DO INSTEAD NOTHING;
CREATE ROLE torture_reader NOLOGIN;
GRANT USAGE ON SCHEMA torture TO torture_reader;
GRANT SELECT ON torture.kinds TO torture_reader;
