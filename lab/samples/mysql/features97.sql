-- What MySQL has from 9.7 on: JavaScript libraries, and routines that use them (USING, each under the name its code
-- calls it by). A community server stores and shows them; running one needs the language component, which the
-- design never does.
CREATE LIBRARY features.lib_math COMMENT 'arithmetic it''s handy to share' LANGUAGE JAVASCRIPT AS $$
export function twice(x) { return 2 * x; }
$$;
CREATE DATABASE features_js;
CREATE LIBRARY features_js.lib_const LANGUAGE JAVASCRIPT AS $$ export const k = 3; $$;
CREATE FUNCTION features.f_js(x INT) RETURNS INT DETERMINISTIC NO SQL COMMENT 'twice and three' LANGUAGE JAVASCRIPT
  USING (features_js.lib_const AS konst, features.lib_math) AS $$ return lib_math.twice(x) + konst.k; $$;
CREATE PROCEDURE features.p_js(IN x INT) LANGUAGE JAVASCRIPT AS $$ let y = x; $$;
