-- PostgreSQL sample: one of each object kind, PostgreSQL 15 and later.
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS citext;
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE SCHEMA features;
CREATE SCHEMA audit;
COMMENT ON SCHEMA features IS 'every kind of object';
CREATE TYPE features.status AS ENUM ('new', 'paid', 'shipped');
CREATE TYPE features.address AS (street text, city text, zip varchar(10));
CREATE TYPE features.floatrange AS RANGE (subtype = float8);
CREATE DOMAIN features.money_amount AS numeric(18,4) NOT NULL DEFAULT 0 CHECK (VALUE >= 0);
CREATE DOMAIN features.email AS citext CHECK (VALUE ~ '@');
CREATE SEQUENCE features.ticket_seq AS bigint START 1000 INCREMENT 5 MINVALUE 1000 MAXVALUE 9999999 CACHE 10 CYCLE;
CREATE COLLATION features.ci (provider = icu, locale = 'und-u-ks-level2', deterministic = false);
CREATE TABLE features.kinds (
  id bigint GENERATED ALWAYS AS IDENTITY (START WITH 10 INCREMENT BY 2) PRIMARY KEY,
  ticket bigint NOT NULL DEFAULT nextval('features.ticket_seq'),
  amount features.money_amount,
  mail features.email,
  status features.status NOT NULL DEFAULT 'new',
  home features.address,
  tags text[] DEFAULT '{}',
  doc jsonb,
  ident uuid DEFAULT gen_random_uuid(),
  window_ tstzrange,
  ratio double precision,
  name text COLLATE features.ci NOT NULL,
  name_upper text GENERATED ALWAYS AS (upper(name)) STORED,
  CONSTRAINT ck_ratio CHECK (ratio BETWEEN 0 AND 1) NOT VALID
);
ALTER SEQUENCE features.ticket_seq OWNED BY features.kinds.ticket;
COMMENT ON TABLE features.kinds IS 'every column type';
COMMENT ON COLUMN features.kinds.amount IS 'never negative';
CREATE UNIQUE INDEX uk_name ON features.kinds (lower(name)) INCLUDE (status) WHERE status <> 'shipped';
CREATE INDEX k_tags ON features.kinds USING gin (tags);
CREATE INDEX k_doc ON features.kinds USING gin (doc jsonb_path_ops);
CREATE INDEX k_name_trgm ON features.kinds USING gist (name gist_trgm_ops);
CREATE INDEX k_window ON features.kinds USING gist (window_);
CREATE INDEX k_ident_brin ON features.kinds USING brin (id) WITH (pages_per_range = 32);
CREATE INDEX k_status_desc ON features.kinds (status DESC NULLS LAST, id);
CREATE TABLE features.parent (id int PRIMARY KEY, code char(3) NOT NULL UNIQUE);
CREATE TABLE features.child (
  id int PRIMARY KEY, parent_id int, parent_code char(3),
  CONSTRAINT fk_parent FOREIGN KEY (parent_id) REFERENCES features.parent (id) ON DELETE CASCADE ON UPDATE SET NULL DEFERRABLE INITIALLY DEFERRED,
  CONSTRAINT fk_code FOREIGN KEY (parent_code) REFERENCES features.parent (code) MATCH FULL ON DELETE RESTRICT
);
CREATE TABLE features.booking (room int, during tstzrange, EXCLUDE USING gist (room WITH =, during WITH &&));
CREATE TABLE features.measurements (id bigint, taken date NOT NULL, region text, value numeric) PARTITION BY RANGE (taken);
CREATE TABLE features.measurements_2024 PARTITION OF features.measurements FOR VALUES FROM ('2024-01-01') TO ('2025-01-01');
CREATE TABLE features.measurements_2025 PARTITION OF features.measurements FOR VALUES FROM ('2025-01-01') TO ('2026-01-01') PARTITION BY LIST (region);
CREATE TABLE features.measurements_2025_east PARTITION OF features.measurements_2025 FOR VALUES IN ('east');
CREATE TABLE features.measurements_2025_rest PARTITION OF features.measurements_2025 DEFAULT;
CREATE TABLE features.by_hash (id int) PARTITION BY HASH (id);
CREATE TABLE features.by_hash_0 PARTITION OF features.by_hash FOR VALUES WITH (MODULUS 2, REMAINDER 0);
CREATE TABLE features.by_hash_1 PARTITION OF features.by_hash FOR VALUES WITH (MODULUS 2, REMAINDER 1);
CREATE TABLE features.base_event (id int, at timestamptz);
CREATE TABLE features.click_event (url text) INHERITS (features.base_event);
CREATE UNLOGGED TABLE features.scratch (k text PRIMARY KEY, v text) WITH (fillfactor = 70, autovacuum_enabled = false);
CREATE VIEW features.v_paid WITH (security_barrier = true) AS SELECT id, name FROM features.kinds WHERE status = 'paid' WITH CASCADED CHECK OPTION;
CREATE MATERIALIZED VIEW features.mv_counts AS SELECT status, count(*) AS n FROM features.kinds GROUP BY status WITH NO DATA;
CREATE UNIQUE INDEX mv_counts_status ON features.mv_counts (status);
CREATE FUNCTION features.f_cents(m numeric) RETURNS bigint LANGUAGE sql IMMUTABLE PARALLEL SAFE STRICT AS $$ SELECT (m * 100)::bigint $$;
CREATE FUNCTION features.f_paid(p_status features.status DEFAULT 'paid') RETURNS TABLE (id bigint, name text) LANGUAGE plpgsql STABLE SECURITY DEFINER
  SET search_path = features AS $$ BEGIN RETURN QUERY SELECT k.id, k.name FROM features.kinds k WHERE k.status = p_status; END $$;
CREATE PROCEDURE features.p_purge(INOUT n int) LANGUAGE plpgsql AS $$ BEGIN DELETE FROM features.scratch; n := 0; END $$;
CREATE FUNCTION audit.log_change() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NULL; END $$;
CREATE TRIGGER t_child_audit AFTER INSERT ON features.child REFERENCING NEW TABLE AS new_rows
  FOR EACH STATEMENT EXECUTE FUNCTION audit.log_change();
CREATE TRIGGER t_child_when BEFORE UPDATE ON features.child FOR EACH ROW WHEN (OLD.parent_id IS DISTINCT FROM NEW.parent_id)
  EXECUTE FUNCTION audit.log_change();
CREATE CONSTRAINT TRIGGER t_child_deferred AFTER INSERT OR UPDATE ON features.child DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION audit.log_change();
CREATE CONSTRAINT TRIGGER t_child_checked AFTER DELETE ON features.child FROM features.parent NOT DEFERRABLE
  FOR EACH ROW EXECUTE FUNCTION audit.log_change();
ALTER TABLE features.kinds ENABLE ROW LEVEL SECURITY;
CREATE POLICY own_rows ON features.kinds FOR SELECT TO PUBLIC USING (status <> 'shipped');
CREATE RULE r_scratch AS ON DELETE TO features.scratch DO INSTEAD NOTHING;
CREATE ROLE features_reader NOLOGIN;
GRANT USAGE ON SCHEMA features TO features_reader;
GRANT SELECT ON features.kinds TO features_reader;
