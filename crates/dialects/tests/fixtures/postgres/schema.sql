--
-- PostgreSQL database dump
--

\restrict QFNo4Ak6VtCx6QSPZLqLbzOLRj18RsBvqYFMbLXygd41qLezNlDOKbtisfa2LzY

-- Dumped from database version 17.12
-- Dumped by pg_dump version 17.12

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: billing; Type: SCHEMA; Schema: -; Owner: postgres
--

CREATE SCHEMA billing;


ALTER SCHEMA billing OWNER TO postgres;

--
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;


--
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';


--
-- Name: address; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.address AS (
	street text,
	city text,
	postcode character varying(16)
);


ALTER TYPE public.address OWNER TO postgres;

--
-- Name: order_status; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.order_status AS ENUM (
    'new',
    'paid',
    'shipped',
    'cancelled'
);


ALTER TYPE public.order_status OWNER TO postgres;

--
-- Name: positive_amount; Type: DOMAIN; Schema: public; Owner: postgres
--

CREATE DOMAIN public.positive_amount AS numeric(18,2)
	CONSTRAINT positive_amount_check CHECK ((VALUE > (0)::numeric));


ALTER DOMAIN public.positive_amount OWNER TO postgres;

--
-- Name: touch_valid_from(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.touch_valid_from() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.valid_from := now();
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.touch_valid_from() OWNER TO postgres;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: invoices; Type: TABLE; Schema: billing; Owner: postgres
--

CREATE TABLE billing.invoices (
    id integer NOT NULL,
    order_key bigint NOT NULL,
    amount public.positive_amount NOT NULL,
    issued_on date DEFAULT CURRENT_DATE NOT NULL,
    note character varying(500)
);


ALTER TABLE billing.invoices OWNER TO postgres;

--
-- Name: invoice_no; Type: SEQUENCE; Schema: billing; Owner: postgres
--

CREATE SEQUENCE billing.invoice_no
    START WITH 1000
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 10;


ALTER SEQUENCE billing.invoice_no OWNER TO postgres;

--
-- Name: invoice_no; Type: SEQUENCE OWNED BY; Schema: billing; Owner: postgres
--

ALTER SEQUENCE billing.invoice_no OWNED BY billing.invoices.id;


--
-- Name: revenue_by_day; Type: MATERIALIZED VIEW; Schema: billing; Owner: postgres
--

CREATE MATERIALIZED VIEW billing.revenue_by_day AS
 SELECT issued_on,
    sum((amount)::numeric) AS revenue
   FROM billing.invoices
  GROUP BY issued_on
  WITH NO DATA;


ALTER MATERIALIZED VIEW billing.revenue_by_day OWNER TO postgres;

--
-- Name: orders; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.orders (
    order_key bigint NOT NULL,
    order_no text NOT NULL,
    customer_id bigint NOT NULL,
    status public.order_status DEFAULT 'new'::public.order_status NOT NULL,
    total numeric(12,2) NOT NULL,
    tax numeric(12,2) GENERATED ALWAYS AS (round((total * 0.2), 2)) STORED,
    valid_from timestamp(6) with time zone NOT NULL,
    valid_to timestamp(6) with time zone,
    CONSTRAINT orders_total_check CHECK ((total >= (0)::numeric)),
    CONSTRAINT orders_valid_range CHECK (((valid_to IS NULL) OR (valid_to > valid_from)))
);


ALTER TABLE public.orders OWNER TO postgres;

--
-- Name: TABLE orders; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.orders IS 'Every version of every order.';


--
-- Name: current_orders; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.current_orders AS
 SELECT order_no,
    customer_id,
    total
   FROM public.orders o
  WHERE (valid_to IS NULL);


ALTER VIEW public.current_orders OWNER TO postgres;

--
-- Name: VIEW current_orders; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON VIEW public.current_orders IS 'Each order as it is now.';


--
-- Name: customers; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.customers (
    id bigint NOT NULL,
    email text NOT NULL,
    name character varying(200) NOT NULL,
    home public.address,
    tags text[] DEFAULT '{}'::text[] NOT NULL,
    profile jsonb,
    external_id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.customers OWNER TO postgres;

--
-- Name: TABLE customers; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.customers IS 'People who order.';


--
-- Name: COLUMN customers.email; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.customers.email IS 'Unique, lowercased.';


--
-- Name: customers_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.customers ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.customers_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: events; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.events (
    id bigint NOT NULL,
    happened_on date NOT NULL,
    payload jsonb
)
PARTITION BY RANGE (happened_on);


ALTER TABLE public.events OWNER TO postgres;

--
-- Name: events_2025_01_01; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.events_2025_01_01 (
    id bigint NOT NULL,
    happened_on date NOT NULL,
    payload jsonb
);


ALTER TABLE public.events_2025_01_01 OWNER TO postgres;

--
-- Name: events_2025_01_02; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.events_2025_01_02 (
    id bigint NOT NULL,
    happened_on date NOT NULL,
    payload jsonb
);


ALTER TABLE public.events_2025_01_02 OWNER TO postgres;

--
-- Name: events_2025_01_03; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.events_2025_01_03 (
    id bigint NOT NULL,
    happened_on date NOT NULL,
    payload jsonb
);


ALTER TABLE public.events_2025_01_03 OWNER TO postgres;

--
-- Name: events_2025_01_04; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.events_2025_01_04 (
    id bigint NOT NULL,
    happened_on date NOT NULL,
    payload jsonb
);


ALTER TABLE public.events_2025_01_04 OWNER TO postgres;

--
-- Name: events_2025_01_05; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.events_2025_01_05 (
    id bigint NOT NULL,
    happened_on date NOT NULL,
    payload jsonb
);


ALTER TABLE public.events_2025_01_05 OWNER TO postgres;

--
-- Name: events_2025_01_06; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.events_2025_01_06 (
    id bigint NOT NULL,
    happened_on date NOT NULL,
    payload jsonb
);


ALTER TABLE public.events_2025_01_06 OWNER TO postgres;

--
-- Name: events_2025_01_07; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.events_2025_01_07 (
    id bigint NOT NULL,
    happened_on date NOT NULL,
    payload jsonb
);


ALTER TABLE public.events_2025_01_07 OWNER TO postgres;

--
-- Name: events_default; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.events_default (
    id bigint NOT NULL,
    happened_on date NOT NULL,
    payload jsonb
);


ALTER TABLE public.events_default OWNER TO postgres;

--
-- Name: orders_order_key_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.orders_order_key_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.orders_order_key_seq OWNER TO postgres;

--
-- Name: orders_order_key_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.orders_order_key_seq OWNED BY public.orders.order_key;


--
-- Name: regions_data; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.regions_data (
    region text NOT NULL,
    value integer
)
PARTITION BY LIST (region);


ALTER TABLE public.regions_data OWNER TO postgres;

--
-- Name: regions_data_eu; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.regions_data_eu (
    region text NOT NULL,
    value integer
);


ALTER TABLE public.regions_data_eu OWNER TO postgres;

--
-- Name: regions_data_us; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.regions_data_us (
    region text NOT NULL,
    value integer
);


ALTER TABLE public.regions_data_us OWNER TO postgres;

--
-- Name: events_2025_01_01; Type: TABLE ATTACH; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.events ATTACH PARTITION public.events_2025_01_01 FOR VALUES FROM ('2025-01-01') TO ('2025-01-02');


--
-- Name: events_2025_01_02; Type: TABLE ATTACH; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.events ATTACH PARTITION public.events_2025_01_02 FOR VALUES FROM ('2025-01-02') TO ('2025-01-03');


--
-- Name: events_2025_01_03; Type: TABLE ATTACH; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.events ATTACH PARTITION public.events_2025_01_03 FOR VALUES FROM ('2025-01-03') TO ('2025-01-04');


--
-- Name: events_2025_01_04; Type: TABLE ATTACH; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.events ATTACH PARTITION public.events_2025_01_04 FOR VALUES FROM ('2025-01-04') TO ('2025-01-05');


--
-- Name: events_2025_01_05; Type: TABLE ATTACH; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.events ATTACH PARTITION public.events_2025_01_05 FOR VALUES FROM ('2025-01-05') TO ('2025-01-06');


--
-- Name: events_2025_01_06; Type: TABLE ATTACH; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.events ATTACH PARTITION public.events_2025_01_06 FOR VALUES FROM ('2025-01-06') TO ('2025-01-07');


--
-- Name: events_2025_01_07; Type: TABLE ATTACH; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.events ATTACH PARTITION public.events_2025_01_07 FOR VALUES FROM ('2025-01-07') TO ('2025-01-08');


--
-- Name: events_default; Type: TABLE ATTACH; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.events ATTACH PARTITION public.events_default DEFAULT;


--
-- Name: regions_data_eu; Type: TABLE ATTACH; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.regions_data ATTACH PARTITION public.regions_data_eu FOR VALUES IN ('eu');


--
-- Name: regions_data_us; Type: TABLE ATTACH; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.regions_data ATTACH PARTITION public.regions_data_us FOR VALUES IN ('us');


--
-- Name: invoices id; Type: DEFAULT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.invoices ALTER COLUMN id SET DEFAULT nextval('billing.invoice_no'::regclass);


--
-- Name: orders order_key; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.orders ALTER COLUMN order_key SET DEFAULT nextval('public.orders_order_key_seq'::regclass);


--
-- Name: invoices invoices_pkey; Type: CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.invoices
    ADD CONSTRAINT invoices_pkey PRIMARY KEY (id);


--
-- Name: customers customers_email_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_email_key UNIQUE (email);


--
-- Name: customers customers_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_pkey PRIMARY KEY (id);


--
-- Name: orders orders_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_pkey PRIMARY KEY (order_key);


--
-- Name: orders orders_version_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_version_key UNIQUE (order_no, valid_from);


--
-- Name: invoices_order_idx; Type: INDEX; Schema: billing; Owner: postgres
--

CREATE INDEX invoices_order_idx ON billing.invoices USING btree (order_key) INCLUDE (amount);


--
-- Name: revenue_by_day_idx; Type: INDEX; Schema: billing; Owner: postgres
--

CREATE UNIQUE INDEX revenue_by_day_idx ON billing.revenue_by_day USING btree (issued_on);


--
-- Name: orders_current_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX orders_current_idx ON public.orders USING btree (order_no) WHERE (valid_to IS NULL);


--
-- Name: orders_customer_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX orders_customer_idx ON public.orders USING btree (customer_id);


--
-- Name: orders_lower_no_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX orders_lower_no_idx ON public.orders USING btree (lower(order_no) DESC NULLS LAST);


--
-- Name: orders orders_touch; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER orders_touch BEFORE INSERT ON public.orders FOR EACH ROW EXECUTE FUNCTION public.touch_valid_from();


--
-- Name: invoices invoices_order_fkey; Type: FK CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.invoices
    ADD CONSTRAINT invoices_order_fkey FOREIGN KEY (order_key) REFERENCES public.orders(order_key) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: orders orders_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(id) ON DELETE RESTRICT;


--
-- Name: TABLE current_orders; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.current_orders TO reporter;


--
-- PostgreSQL database dump complete
--

\unrestrict QFNo4Ak6VtCx6QSPZLqLbzOLRj18RsBvqYFMbLXygd41qLezNlDOKbtisfa2LzY

