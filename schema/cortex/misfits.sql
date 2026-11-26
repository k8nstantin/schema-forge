-- misfits: what a design holds that a target, another version of its engine or a flavor of it, would not take
-- (refused) or would take at a cost (warned), each with why and, for a flavor's limit, where that was read. The
-- question an upgrade or a move asks first (will 5.7's design go to 8.0? to Cloud SQL? to Spanner?), answered from the
-- declarations alone; the target's own server, where one can run, answers the rest. Owner: cortex.

CREATE FUNCTION cortex.misfits(p_design uuid, p_version text, p_flavor text DEFAULT NULL)
RETURNS TABLE (part text, row_id uuid, what text, name text, severity text, about text, source text)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  e text;
  at numeric;
  p text;
BEGIN
  SELECT engine INTO e FROM cortex.designs WHERE id = p_design;
  SELECT position INTO at FROM cortex.engine_versions WHERE engine = e AND version = p_version;
  IF at IS NULL THEN
    RAISE EXCEPTION '% has no version %', e, p_version USING ERRCODE = 'check_violation';
  END IF;
  -- the target itself: a flavor that does not offer the version
  RETURN QUERY SELECT 'designs'::text, p_design, 'version'::text, p_version, l.severity, l.about, l.source
    FROM cortex.flavor_limits l WHERE l.flavor = p_flavor AND l.what = 'version' AND l.version = e || '/' || p_version;
  -- objects of a kind the target lacks, or another flavor's alone
  RETURN QUERY SELECT 'objects'::text, o.id, 'kind'::text, o.kind, coalesce(l.severity, 'refused'),
      coalesce(l.about, CASE WHEN k.flavor IS NOT NULL AND k.flavor IS DISTINCT FROM p_flavor THEN k.flavor || '''s alone'
                             ELSE 'not in ' || e || ' ' || p_version END), l.source
    FROM cortex.objects o JOIN cortex.object_kinds k ON k.engine = e AND k.kind = o.kind
    LEFT JOIN cortex.flavor_limits l ON l.flavor = p_flavor AND l.what = 'kind' AND l.kind = k.id
      AND (l.since IS NULL OR at >= (SELECT v.position FROM cortex.engine_versions v WHERE v.id = l.since))
      AND (l."until" IS NULL OR at <= (SELECT v.position FROM cortex.engine_versions v WHERE v.id = l."until"))
    WHERE o.design = p_design AND (l.id IS NOT NULL OR k.flavor IS NOT NULL AND k.flavor IS DISTINCT FROM p_flavor
       OR k.since IS NOT NULL AND at < (SELECT v.position FROM cortex.engine_versions v WHERE v.id = k.since)
       OR k."until" IS NOT NULL AND at > (SELECT v.position FROM cortex.engine_versions v WHERE v.id = k."until"));
  -- a value of a part's own column the flavor lacks (CockroachDB's deferrable constraints)
  FOR p IN SELECT DISTINCT l.part FROM cortex.flavor_limits l WHERE l.flavor = p_flavor AND l.what = 'field' LOOP
    RETURN QUERY EXECUTE format($q$
      SELECT %1$L::text, r.id, 'field'::text, l.field || ' = ' || l.value::text, l.severity, l.about, l.source
        FROM cortex.%1$I r JOIN cortex.flavor_limits l ON l.flavor = $2 AND l.what = 'field' AND l.part = %1$L
       WHERE r.design = $1 AND to_jsonb(r) -> l.field = l.value$q$, p) USING p_design, p_flavor;
  END LOOP;
  -- every option of every part: one the target version does not have, another flavor's alone, or one the flavor lacks
  FOR p IN SELECT DISTINCT d.part FROM cortex.option_declarations d WHERE d.engine = e LOOP
    RETURN QUERY EXECUTE format($q$
      SELECT %1$L::text, r.id, CASE WHEN l.what = 'value' THEN 'value' ELSE 'option' END, x.key || CASE WHEN l.what = 'value' THEN ' = ' || x.value::text ELSE '' END,
             coalesce(l.severity, 'refused'),
             coalesce(l.about, CASE WHEN d.id IS NULL THEN 'not declared'
                                    WHEN d.flavor IS NOT NULL AND d.flavor IS DISTINCT FROM $3 THEN d.flavor || '''s alone'
                                    ELSE 'not in ' || $4 || ' ' || $2 END), l.source
        FROM cortex.%1$I r CROSS JOIN LATERAL jsonb_each(r.options) x
        LEFT JOIN cortex.option_declarations d ON d.engine = $4 AND d.part = %1$L AND d.name = x.key
        LEFT JOIN cortex.flavor_limits l ON l.flavor = $3 AND l.option = d.id AND (l.what = 'option' OR l.what = 'value' AND l.value = x.value)
          AND (l.since IS NULL OR $5 >= (SELECT v.position FROM cortex.engine_versions v WHERE v.id = l.since))
          AND (l."until" IS NULL OR $5 <= (SELECT v.position FROM cortex.engine_versions v WHERE v.id = l."until"))
       WHERE r.design = $1 AND (d.id IS NULL OR l.id IS NOT NULL
          OR d.flavor IS NOT NULL AND d.flavor IS DISTINCT FROM $3
          OR d.since IS NOT NULL AND $5 < (SELECT v.position FROM cortex.engine_versions v WHERE v.id = d.since)
          OR d."until" IS NOT NULL AND $5 > (SELECT v.position FROM cortex.engine_versions v WHERE v.id = d."until"))$q$, p)
      USING p_design, p_version, p_flavor, e, at;
  END LOOP;
END $$;
