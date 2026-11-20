-- The schema behind the PostgreSQL fixtures. `pg_dump` of a database built from this file gives
-- schema.sql (--schema-only) and full.sql (with data). Regenerate with tools/pg_fixtures.sh.

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE SCHEMA billing;
CREATE ROLE reporter;

CREATE TYPE public.order_status AS ENUM ('new', 'paid', 'shipped', 'cancelled');
CREATE DOMAIN public.positive_amount AS numeric(18,2) CONSTRAINT positive_amount_check CHECK (VALUE > 0);
CREATE TYPE public.address AS (street text, city text, postcode varchar(16));

CREATE TABLE public.customers (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email text NOT NULL UNIQUE,
    name varchar(200) NOT NULL,
    home public.address,
    tags text[] DEFAULT '{}'::text[] NOT NULL,
    profile jsonb,
    external_id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);
COMMENT ON TABLE public.customers IS 'People who order.';
COMMENT ON COLUMN public.customers.email IS 'Unique, lowercased.';

CREATE TABLE public.orders (
    order_key bigserial PRIMARY KEY,
    order_no text NOT NULL,
    customer_id bigint NOT NULL REFERENCES public.customers (id) ON DELETE RESTRICT,
    status public.order_status DEFAULT 'new' NOT NULL,
    total numeric(12,2) NOT NULL CHECK (total >= 0),
    tax numeric(12,2) GENERATED ALWAYS AS (round(total * 0.2, 2)) STORED,
    valid_from timestamp(6) with time zone NOT NULL,
    valid_to timestamp(6) with time zone,
    CONSTRAINT orders_version_key UNIQUE (order_no, valid_from),
    CONSTRAINT orders_valid_range CHECK (valid_to IS NULL OR valid_to > valid_from)
);
COMMENT ON TABLE public.orders IS 'Every version of every order.';
CREATE INDEX orders_customer_idx ON public.orders (customer_id);
CREATE INDEX orders_current_idx ON public.orders (order_no) WHERE valid_to IS NULL;
CREATE INDEX orders_lower_no_idx ON public.orders (lower(order_no) DESC NULLS LAST);

CREATE TABLE billing.invoices (
    id integer NOT NULL,
    order_key bigint NOT NULL,
    amount public.positive_amount NOT NULL,
    issued_on date DEFAULT CURRENT_DATE NOT NULL,
    note character varying(500)
);
CREATE SEQUENCE billing.invoice_no START WITH 1000 INCREMENT BY 1 CACHE 10;
ALTER TABLE billing.invoices ALTER COLUMN id SET DEFAULT nextval('billing.invoice_no');
ALTER SEQUENCE billing.invoice_no OWNED BY billing.invoices.id;
ALTER TABLE billing.invoices ADD CONSTRAINT invoices_pkey PRIMARY KEY (id);
ALTER TABLE billing.invoices ADD CONSTRAINT invoices_order_fkey FOREIGN KEY (order_key)
    REFERENCES public.orders (order_key) ON UPDATE CASCADE ON DELETE CASCADE;
CREATE INDEX invoices_order_idx ON billing.invoices (order_key) INCLUDE (amount);

CREATE TABLE public.events (
    id bigint NOT NULL,
    happened_on date NOT NULL,
    payload jsonb
) PARTITION BY RANGE (happened_on);
CREATE TABLE public.events_2025_01_01 PARTITION OF public.events FOR VALUES FROM ('2025-01-01') TO ('2025-01-02');
CREATE TABLE public.events_2025_01_02 PARTITION OF public.events FOR VALUES FROM ('2025-01-02') TO ('2025-01-03');
CREATE TABLE public.events_2025_01_03 PARTITION OF public.events FOR VALUES FROM ('2025-01-03') TO ('2025-01-04');
CREATE TABLE public.events_2025_01_04 PARTITION OF public.events FOR VALUES FROM ('2025-01-04') TO ('2025-01-05');
CREATE TABLE public.events_2025_01_05 PARTITION OF public.events FOR VALUES FROM ('2025-01-05') TO ('2025-01-06');
CREATE TABLE public.events_2025_01_06 PARTITION OF public.events FOR VALUES FROM ('2025-01-06') TO ('2025-01-07');
CREATE TABLE public.events_2025_01_07 PARTITION OF public.events FOR VALUES FROM ('2025-01-07') TO ('2025-01-08');
CREATE TABLE public.events_default PARTITION OF public.events DEFAULT;

CREATE TABLE public.regions_data (
    region text NOT NULL,
    value integer
) PARTITION BY LIST (region);
CREATE TABLE public.regions_data_eu PARTITION OF public.regions_data FOR VALUES IN ('eu');
CREATE TABLE public.regions_data_us PARTITION OF public.regions_data FOR VALUES IN ('us');

CREATE VIEW public.current_orders AS
    SELECT o.order_no, o.customer_id, o.total FROM public.orders o WHERE o.valid_to IS NULL;
COMMENT ON VIEW public.current_orders IS 'Each order as it is now.';
CREATE MATERIALIZED VIEW billing.revenue_by_day AS
    SELECT issued_on, sum(amount) AS revenue FROM billing.invoices GROUP BY issued_on WITH NO DATA;
CREATE UNIQUE INDEX revenue_by_day_idx ON billing.revenue_by_day (issued_on);

CREATE FUNCTION public.touch_valid_from() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.valid_from := now();
    RETURN NEW;
END;
$$;
CREATE TRIGGER orders_touch BEFORE INSERT ON public.orders FOR EACH ROW EXECUTE FUNCTION public.touch_valid_from();
GRANT SELECT ON public.current_orders TO reporter;

INSERT INTO public.customers (email, name) VALUES ('a@example.com', 'Ann'), ('b@example.com', 'Bo');
INSERT INTO public.orders (order_no, customer_id, total, valid_from)
    VALUES ('O-1', 1, 10.00, now()), ('O-2', 2, 25.50, now());
