-- What MySQL 9.7 adds to the every-object sample (loaded after common.sql and 8.0.sql): a JavaScript library and a
-- JavaScript function that uses it.
USE shop;

CREATE LIBRARY IF NOT EXISTS pricing LANGUAGE JAVASCRIPT AS $$
  export function withTax(amount, rate) { return amount * (1 + rate); }
$$;

CREATE FUNCTION price_with_tax(amount DOUBLE, rate DOUBLE) RETURNS DOUBLE
  LANGUAGE JAVASCRIPT USING (pricing)
  AS $$ return pricing.withTax(amount, rate); $$;
