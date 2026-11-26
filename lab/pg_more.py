"""PostgreSQL's objects past tables, views, routines, types and sequences (decision kind-parts: 1.0 is every object's
definition), each kind in one place: what is read from the catalog, which of it is the object's options, which objects
it uses (each a dependency as its role when the design holds it, its name otherwise: pg_catalog's int4pl), the lists it
holds, and the statement written back. Measured by pg_dump --schema-only of the whole database (lab/repo_pg_store.py).
"""
import json
import uuid
from collections import Counter, defaultdict

import options_layout as OL

# kind: (scope, option prefix, the catalog query giving key, schema, name, signature, owner, acl, comment, opts, refs, lists)
# Every query names things, never oids: the rebuilt server's oids differ.
FN = "%s::regprocedure::text"
Q = {
    "aggregate": ("namespace", "agg", """SELECT p.oid::regprocedure::text AS key, n.nspname AS schema, p.proname AS name,
        '(' || pg_get_function_identity_arguments(p.oid) || ')' AS signature, pg_get_userbyid(p.proowner) AS owner, p.proacl::text[] AS acl,
        obj_description(p.oid, 'pg_proc') AS comment,
        jsonb_build_object('arguments', pg_get_function_arguments(p.oid), 'stype', format_type(a.aggtranstype, NULL), 'initcond', a.agginitval,
          'kind', a.aggkind::text, 'sspace', a.aggtransspace, 'finalfunc_extra', a.aggfinalextra, 'finalfunc_modify', a.aggfinalmodify::text,
          'parallel', p.proparallel::text) AS opts,
        jsonb_strip_nulls(jsonb_build_object('sfunc', a.aggtransfn::regprocedure::text, 'finalfunc', nullif(a.aggfinalfn, 0)::regprocedure::text,
          'combinefunc', nullif(a.aggcombinefn, 0)::regprocedure::text, 'serialfunc', nullif(a.aggserialfn, 0)::regprocedure::text,
          'deserialfunc', nullif(a.aggdeserialfn, 0)::regprocedure::text, 'sortop', nullif(a.aggsortop, 0)::regoperator::text)) AS refs
      FROM pg_aggregate a JOIN pg_proc p ON p.oid = a.aggfnoid JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = ANY(%(s)s) AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')"""),
    "operator_family": ("namespace", "opf", """SELECT n.nspname || '.' || f.opfname || ' ' || am.amname AS key, n.nspname AS schema, f.opfname AS name,
        ' USING ' || am.amname AS signature, pg_get_userbyid(f.opfowner) AS owner, NULL::text[] AS acl,
        obj_description(f.oid, 'pg_opfamily') AS comment, jsonb_build_object('method', am.amname) AS opts, '{}'::jsonb AS refs
      FROM pg_opfamily f JOIN pg_namespace n ON n.oid = f.opfnamespace JOIN pg_am am ON am.oid = f.opfmethod
      WHERE n.nspname = ANY(%(s)s) AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = f.oid AND d.deptype = 'e')"""),
    "operator": ("namespace", "op", """SELECT o.oid::regoperator::text AS key, n.nspname AS schema, o.oprname AS name,
        '(' || coalesce(format_type(o.oprleft, NULL), 'NONE') || ', ' || format_type(o.oprright, NULL) || ')' AS signature,
        pg_get_userbyid(o.oprowner) AS owner, NULL::text[] AS acl, obj_description(o.oid, 'pg_operator') AS comment,
        jsonb_build_object('leftarg', CASE WHEN o.oprleft <> 0 THEN format_type(o.oprleft, NULL) END, 'rightarg', format_type(o.oprright, NULL),
          'hashes', o.oprcanhash, 'merges', o.oprcanmerge,
          'restrict', nullif(o.oprrest, 0)::regproc::text, 'join', nullif(o.oprjoin, 0)::regproc::text,
          'commutator', nullif(o.oprcom, 0)::regoperator::text, 'negator', nullif(o.oprnegate, 0)::regoperator::text) AS opts,
        jsonb_build_object('function', o.oprcode::regprocedure::text) AS refs
      FROM pg_operator o JOIN pg_namespace n ON n.oid = o.oprnamespace
      WHERE n.nspname = ANY(%(s)s) AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = o.oid AND d.deptype = 'e')"""),
    "operator_class": ("namespace", "opc", """SELECT n.nspname || '.' || c.opcname || ' ' || am.amname AS key, n.nspname AS schema, c.opcname AS name,
        ' USING ' || am.amname AS signature, pg_get_userbyid(c.opcowner) AS owner, NULL::text[] AS acl,
        obj_description(c.oid, 'pg_opclass') AS comment,
        jsonb_build_object('method', am.amname, 'for_type', format_type(c.opcintype, NULL), 'is_default', c.opcdefault,
          'storage', CASE WHEN c.opckeytype <> 0 THEN format_type(c.opckeytype, NULL) END,
          'items', (SELECT jsonb_agg(x ORDER BY x->>'what', (x->>'number')::int) FROM (
             SELECT jsonb_build_object('what', 'operator', 'number', o.amopstrategy, 'name', o.amopopr::regoperator::text) x FROM pg_amop o
              JOIN pg_depend d ON d.classid = 'pg_amop'::regclass AND d.objid = o.oid AND d.refobjid = c.oid AND d.deptype IN ('i', 'a')
             UNION ALL SELECT jsonb_build_object('what', 'function', 'number', p.amprocnum, 'name', p.amproc::regprocedure::text) FROM pg_amproc p
              JOIN pg_depend d ON d.classid = 'pg_amproc'::regclass AND d.objid = p.oid AND d.refobjid = c.oid AND d.deptype IN ('i', 'a')) s)) AS opts,
        jsonb_build_object('family', fn.nspname || '.' || f.opfname || ' ' || am.amname) AS refs
      FROM pg_opclass c JOIN pg_namespace n ON n.oid = c.opcnamespace JOIN pg_am am ON am.oid = c.opcmethod
      JOIN pg_opfamily f ON f.oid = c.opcfamily JOIN pg_namespace fn ON fn.oid = f.opfnamespace
      WHERE n.nspname = ANY(%(s)s) AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = c.oid AND d.deptype = 'e')"""),
    "conversion": ("namespace", "conv", """SELECT n.nspname || '.' || c.conname AS key, n.nspname AS schema, c.conname AS name, '' AS signature,
        pg_get_userbyid(c.conowner) AS owner, NULL::text[] AS acl, obj_description(c.oid, 'pg_conversion') AS comment,
        jsonb_build_object('for_encoding', pg_encoding_to_char(c.conforencoding), 'to_encoding', pg_encoding_to_char(c.contoencoding),
          'is_default', c.condefault) AS opts, jsonb_build_object('function', c.conproc::regprocedure::text) AS refs
      FROM pg_conversion c JOIN pg_namespace n ON n.oid = c.connamespace WHERE n.nspname = ANY(%(s)s)"""),
    "statistics": ("namespace", "stx", """SELECT n.nspname || '.' || s.stxname AS key, n.nspname AS schema, s.stxname AS name, '' AS signature,
        pg_get_userbyid(s.stxowner) AS owner, NULL::text[] AS acl, obj_description(s.oid, 'pg_statistic_ext') AS comment,
        jsonb_build_object('kinds', (SELECT jsonb_agg(k ORDER BY k) FROM unnest(s.stxkind::text[]) k),
          'target', s.stxstattarget, 'definition', pg_get_statisticsobjdef(s.oid)) AS opts,
        jsonb_build_object('table', tn.nspname || '.' || t.relname) AS refs
      FROM pg_statistic_ext s JOIN pg_namespace n ON n.oid = s.stxnamespace JOIN pg_class t ON t.oid = s.stxrelid
      JOIN pg_namespace tn ON tn.oid = t.relnamespace WHERE n.nspname = ANY(%(s)s)"""),
    "ts_template": ("namespace", "tst", """SELECT n.nspname || '.' || t.tmplname AS key, n.nspname AS schema, t.tmplname AS name, '' AS signature,
        NULL AS owner, NULL::text[] AS acl, obj_description(t.oid, 'pg_ts_template') AS comment,
        jsonb_build_object('init', nullif(t.tmplinit, 0)::regproc::text, 'lexize', t.tmpllexize::regproc::text) AS opts, '{}'::jsonb AS refs
      FROM pg_ts_template t JOIN pg_namespace n ON n.oid = t.tmplnamespace WHERE n.nspname = ANY(%(s)s)"""),
    "ts_parser": ("namespace", "tsp", """SELECT n.nspname || '.' || p.prsname AS key, n.nspname AS schema, p.prsname AS name, '' AS signature,
        NULL AS owner, NULL::text[] AS acl, obj_description(p.oid, 'pg_ts_parser') AS comment,
        jsonb_build_object('start', p.prsstart::regproc::text, 'gettoken', p.prstoken::regproc::text, 'end', p.prsend::regproc::text,
          'lextypes', p.prslextype::regproc::text, 'headline', nullif(p.prsheadline, 0)::regproc::text) AS opts, '{}'::jsonb AS refs
      FROM pg_ts_parser p JOIN pg_namespace n ON n.oid = p.prsnamespace WHERE n.nspname = ANY(%(s)s)"""),
    "ts_dictionary": ("namespace", "tsd", """SELECT n.nspname || '.' || d.dictname AS key, n.nspname AS schema, d.dictname AS name, '' AS signature,
        pg_get_userbyid(d.dictowner) AS owner, NULL::text[] AS acl, obj_description(d.oid, 'pg_ts_dict') AS comment,
        jsonb_build_object('init_options', d.dictinitoption) AS opts,
        jsonb_build_object('template', tn.nspname || '.' || t.tmplname) AS refs
      FROM pg_ts_dict d JOIN pg_namespace n ON n.oid = d.dictnamespace JOIN pg_ts_template t ON t.oid = d.dicttemplate
      JOIN pg_namespace tn ON tn.oid = t.tmplnamespace WHERE n.nspname = ANY(%(s)s)"""),
    "ts_configuration": ("namespace", "tsc", """SELECT n.nspname || '.' || c.cfgname AS key, n.nspname AS schema, c.cfgname AS name, '' AS signature,
        pg_get_userbyid(c.cfgowner) AS owner, NULL::text[] AS acl, obj_description(c.oid, 'pg_ts_config') AS comment,
        jsonb_build_object('mappings', (SELECT jsonb_agg(jsonb_build_object('token', t.alias, 'dictionaries',
            (SELECT jsonb_agg(dn.nspname || '.' || d.dictname ORDER BY m.mapseqno) FROM pg_ts_config_map m JOIN pg_ts_dict d ON d.oid = m.mapdict
              JOIN pg_namespace dn ON dn.oid = d.dictnamespace WHERE m.mapcfg = c.oid AND m.maptokentype = t.tokid)) ORDER BY t.tokid)
          FROM ts_token_type(c.cfgparser) t WHERE EXISTS (SELECT 1 FROM pg_ts_config_map m WHERE m.mapcfg = c.oid AND m.maptokentype = t.tokid))) AS opts,
        jsonb_build_object('parser', pn.nspname || '.' || p.prsname) AS refs
      FROM pg_ts_config c JOIN pg_namespace n ON n.oid = c.cfgnamespace JOIN pg_ts_parser p ON p.oid = c.cfgparser
      JOIN pg_namespace pn ON pn.oid = p.prsnamespace WHERE n.nspname = ANY(%(s)s)"""),
    "foreign_data_wrapper": ("database", "fdw", """SELECT w.fdwname AS key, NULL AS schema, w.fdwname AS name, '' AS signature,
        pg_get_userbyid(w.fdwowner) AS owner, w.fdwacl::text[] AS acl, obj_description(w.oid, 'pg_foreign_data_wrapper') AS comment,
        jsonb_build_object('handler', nullif(w.fdwhandler, 0)::regproc::text, 'validator', nullif(w.fdwvalidator, 0)::regproc::text,
          'fdw_options', w.fdwoptions) AS opts, '{}'::jsonb AS refs
      FROM pg_foreign_data_wrapper w WHERE NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = w.oid AND d.deptype = 'e')"""),
    "foreign_server": ("database", "srv", """SELECT s.srvname AS key, NULL AS schema, s.srvname AS name, '' AS signature,
        pg_get_userbyid(s.srvowner) AS owner, s.srvacl::text[] AS acl, obj_description(s.oid, 'pg_foreign_server') AS comment,
        jsonb_build_object('type', s.srvtype, 'version', s.srvversion, 'server_options', s.srvoptions, 'wrapper', w.fdwname,
          'user_mappings', (SELECT jsonb_agg(jsonb_build_object('role', CASE WHEN m.umuser = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(m.umuser) END,
              'options', m.umoptions) ORDER BY 1) FROM pg_user_mapping m WHERE m.umserver = s.oid)) AS opts, '{}'::jsonb AS refs
      FROM pg_foreign_server s JOIN pg_foreign_data_wrapper w ON w.oid = s.srvfdw"""),
    "foreign_table": ("namespace", "ft", """SELECT n.nspname || '.' || c.relname AS key, n.nspname AS schema, c.relname AS name, '' AS signature,
        pg_get_userbyid(c.relowner) AS owner, c.relacl::text[] AS acl, obj_description(c.oid, 'pg_class') AS comment,
        jsonb_build_object('table_options', f.ftoptions, 'columns', (SELECT jsonb_agg(jsonb_build_object('name', a.attname,
            'type', format_type(a.atttypid, a.atttypmod), 'not_null', a.attnotnull, 'default', pg_get_expr(d.adbin, d.adrelid),
            'options', a.attfdwoptions) ORDER BY a.attnum) FROM pg_attribute a LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
            WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped)) AS opts,
        jsonb_build_object('server', s.srvname) AS refs
      FROM pg_foreign_table f JOIN pg_class c ON c.oid = f.ftrelid JOIN pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_foreign_server s ON s.oid = f.ftserver WHERE n.nspname = ANY(%(s)s)"""),
    "cast": ("database", "cast", """SELECT format_type(c.castsource, NULL) || ' AS ' || format_type(c.casttarget, NULL) AS key, NULL AS schema,
        format_type(c.castsource, NULL) || ' AS ' || format_type(c.casttarget, NULL) AS name, '' AS signature, NULL AS owner, NULL::text[] AS acl,
        obj_description(c.oid, 'pg_cast') AS comment,
        jsonb_build_object('source', format_type(c.castsource, NULL), 'target', format_type(c.casttarget, NULL), 'method', c.castmethod::text,
          'context', c.castcontext::text) AS opts,
        jsonb_strip_nulls(jsonb_build_object('function', nullif(c.castfunc, 0)::regprocedure::text)) AS refs
      FROM pg_cast c WHERE c.oid >= 16384 AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = c.oid AND d.deptype IN ('e', 'i'))"""),
    "access_method": ("database", "am", """SELECT a.amname AS key, NULL AS schema, a.amname AS name, '' AS signature, NULL AS owner, NULL::text[] AS acl,
        obj_description(a.oid, 'pg_am') AS comment, jsonb_build_object('type', a.amtype::text, 'handler', a.amhandler::regproc::text) AS opts,
        '{}'::jsonb AS refs
      FROM pg_am a WHERE a.oid >= 16384 AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = a.oid AND d.deptype = 'e')"""),
    "publication": ("database", "pub", """SELECT p.pubname AS key, NULL AS schema, p.pubname AS name, '' AS signature,
        pg_get_userbyid(p.pubowner) AS owner, NULL::text[] AS acl, obj_description(p.oid, 'pg_publication') AS comment,
        jsonb_build_object('all_tables', p.puballtables, 'insert', p.pubinsert, 'update', p.pubupdate, 'delete', p.pubdelete,
          'truncate', p.pubtruncate, 'via_root', p.pubviaroot,
          'tables', (SELECT jsonb_agg(jsonb_build_object('table', tn.nspname || '.' || t.relname, 'where', pg_get_expr(r.prqual, r.prrelid),
              'columns', (SELECT jsonb_agg(a.attname ORDER BY k) FROM unnest(r.prattrs) WITH ORDINALITY u(attnum, k)
                          JOIN pg_attribute a ON a.attrelid = r.prrelid AND a.attnum = u.attnum)) ORDER BY 1)
            FROM pg_publication_rel r JOIN pg_class t ON t.oid = r.prrelid JOIN pg_namespace tn ON tn.oid = t.relnamespace WHERE r.prpubid = p.oid),
          'schemas', (SELECT jsonb_agg(sn.nspname ORDER BY 1) FROM pg_publication_namespace pn JOIN pg_namespace sn ON sn.oid = pn.pnnspid
            WHERE pn.pnpubid = p.oid)) AS opts, '{}'::jsonb AS refs
      FROM pg_publication p"""),
    "tablespace": ("server", "spc", """SELECT t.spcname AS key, NULL AS schema, t.spcname AS name, '' AS signature,
        pg_get_userbyid(t.spcowner) AS owner, t.spcacl::text[] AS acl, shobj_description(t.oid, 'pg_tablespace') AS comment,
        jsonb_build_object('location', pg_tablespace_location(t.oid), 'tablespace_options', t.spcoptions) AS opts, '{}'::jsonb AS refs
      FROM pg_tablespace t WHERE t.spcname NOT IN ('pg_default', 'pg_global')"""),
    "language": ("database", "lan", """SELECT l.lanname AS key, NULL AS schema, l.lanname AS name, '' AS signature,
        pg_get_userbyid(l.lanowner) AS owner, l.lanacl::text[] AS acl, obj_description(l.oid, 'pg_language') AS comment,
        jsonb_build_object('trusted', l.lanpltrusted, 'handler', l.lanplcallfoid::regproc::text,
          'inline', nullif(l.laninline, 0)::regproc::text, 'validator', nullif(l.lanvalidator, 0)::regproc::text) AS opts, '{}'::jsonb AS refs
      FROM pg_language l WHERE l.lanispl AND l.oid >= 16384 AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = l.oid AND d.deptype = 'e')"""),
    # a subscription's connection never with its password: anything password= is cut from it as it is read
    "subscription": ("database", "sub", """SELECT s.subname AS key, NULL AS schema, s.subname AS name, '' AS signature,
        pg_get_userbyid(s.subowner) AS owner, NULL::text[] AS acl, shobj_description(s.oid, 'pg_subscription') AS comment,
        jsonb_build_object('connection', regexp_replace(s.subconninfo, '\s*password\s*=\s*(''[^'']*''|\S+)', '', 'gi'),
          'publications', to_jsonb(s.subpublications), 'enabled', s.subenabled, 'binary', s.subbinary, 'slot_name', s.subslotname::text,
          'synchronous_commit', s.subsynccommit, 'stream', s.substream::text, 'two_phase', s.subtwophasestate::text,
          'disable_on_error', s.subdisableonerr) AS opts, '{}'::jsonb AS refs
      FROM pg_subscription s WHERE s.subdbid = (SELECT oid FROM pg_database WHERE datname = current_database())"""),
    "event_trigger": ("database", "evt", """SELECT e.evtname AS key, NULL AS schema, e.evtname AS name, '' AS signature,
        pg_get_userbyid(e.evtowner) AS owner, NULL::text[] AS acl, obj_description(e.oid, 'pg_event_trigger') AS comment,
        jsonb_build_object('event', e.evtevent, 'tags', to_jsonb(e.evttags), 'enabled', e.evtenabled::text) AS opts,
        jsonb_build_object('function', e.evtfoid::regprocedure::text) AS refs
      FROM pg_event_trigger e"""),
}
ORDER = ["tablespace", "language", "access_method", "foreign_data_wrapper", "foreign_server", "foreign_table", "operator_family", "operator", "operator_class",
         "aggregate", "cast", "conversion", "ts_template", "ts_parser", "ts_dictionary", "ts_configuration", "statistics", "publication",
         "event_trigger", "subscription"]
TYPES = {
    ('subscription', 'connection'): 'string',
    ('subscription', 'publications'): 'json',
    ('subscription', 'enabled'): 'boolean',
    ('subscription', 'binary'): 'boolean',
    ('subscription', 'slot_name'): 'string',
    ('subscription', 'synchronous_commit'): 'string',
    ('subscription', 'stream'): 'string',
    ('subscription', 'two_phase'): 'string',
    ('subscription', 'disable_on_error'): 'boolean',
    ('tablespace', 'location'): 'string',
    ('tablespace', 'tablespace_options'): 'json',
    ('language', 'trusted'): 'boolean',
    ('language', 'handler'): 'string',
    ('language', 'inline'): 'string',
    ('language', 'validator'): 'string',
    ('access_method', 'handler'): 'string',
    ('access_method', 'type'): 'string',
    ('aggregate', 'arguments'): 'string',
    ('aggregate', 'combinefunc'): 'string',
    ('aggregate', 'deserialfunc'): 'string',
    ('aggregate', 'finalfunc'): 'string',
    ('aggregate', 'finalfunc_extra'): 'boolean',
    ('aggregate', 'finalfunc_modify'): 'string',
    ('aggregate', 'initcond'): 'string',
    ('aggregate', 'kind'): 'string',
    ('aggregate', 'parallel'): 'string',
    ('aggregate', 'serialfunc'): 'string',
    ('aggregate', 'sfunc'): 'string',
    ('aggregate', 'sortop'): 'string',
    ('aggregate', 'sspace'): 'number',
    ('aggregate', 'stype'): 'string',
    ('cast', 'context'): 'string',
    ('cast', 'function'): 'string',
    ('cast', 'method'): 'string',
    ('cast', 'source'): 'string',
    ('cast', 'target'): 'string',
    ('conversion', 'for_encoding'): 'string',
    ('conversion', 'function'): 'string',
    ('conversion', 'is_default'): 'boolean',
    ('conversion', 'to_encoding'): 'string',
    ('event_trigger', 'enabled'): 'string',
    ('event_trigger', 'event'): 'string',
    ('event_trigger', 'function'): 'string',
    ('event_trigger', 'tags'): 'json',
    ('foreign_data_wrapper', 'fdw_options'): 'json',
    ('foreign_data_wrapper', 'handler'): 'string',
    ('foreign_data_wrapper', 'validator'): 'string',
    ('foreign_server', 'options'): 'string',
    ('foreign_server', 'role'): 'string',
    ('foreign_server', 'server_options'): 'json',
    ('foreign_server', 'type'): 'string',
    ('foreign_server', 'user_mappings'): 'json',
    ('foreign_server', 'version'): 'string',
    ('foreign_server', 'wrapper'): 'string',
    ('foreign_table', 'columns'): 'json',
    ('foreign_table', 'default'): 'string',
    ('foreign_table', 'not_null'): 'string',
    ('foreign_table', 'options'): 'string',
    ('foreign_table', 'server'): 'string',
    ('foreign_table', 'table_options'): 'json',
    ('foreign_table', 'type'): 'string',
    ('operator', 'commutator'): 'string',
    ('operator', 'function'): 'string',
    ('operator', 'hashes'): 'boolean',
    ('operator', 'join'): 'string',
    ('operator', 'leftarg'): 'string',
    ('operator', 'merges'): 'boolean',
    ('operator', 'negator'): 'string',
    ('operator', 'restrict'): 'string',
    ('operator', 'rightarg'): 'string',
    ('operator_class', 'family'): 'string',
    ('operator_class', 'for_type'): 'string',
    ('operator_class', 'function'): 'string',
    ('operator_class', 'i'): 'string',
    ('operator_class', 'is_default'): 'boolean',
    ('operator_class', 'items'): 'json',
    ('operator_class', 'method'): 'string',
    ('operator_class', 'number'): 'string',
    ('operator_class', 'operator'): 'string',
    ('operator_class', 'storage'): 'string',
    ('operator_class', 'what'): 'string',
    ('operator_family', 'method'): 'string',
    ('publication', 'all_tables'): 'boolean',
    ('publication', 'columns'): 'string',
    ('publication', 'delete'): 'boolean',
    ('publication', 'insert'): 'boolean',
    ('publication', 'table'): 'string',
    ('publication', 'schemas'): 'json',
    ('publication', 'tables'): 'json',
    ('publication', 'truncate'): 'boolean',
    ('publication', 'update'): 'boolean',
    ('publication', 'via_root'): 'boolean',
    ('publication', 'where'): 'string',
    ('statistics', 'definition'): 'string',
    ('statistics', 'kinds'): 'json',
    ('statistics', 'table'): 'string',
    ('statistics', 'target'): 'number',
    ('ts_configuration', 'mappings'): 'json',
    ('ts_configuration', 'parser'): 'string',
    ('ts_configuration', 'token'): 'string',
    ('ts_dictionary', 'init_options'): 'string',
    ('ts_dictionary', 'template'): 'string',
    ('ts_parser', 'end'): 'string',
    ('ts_parser', 'gettoken'): 'string',
    ('ts_parser', 'headline'): 'string',
    ('ts_parser', 'lextypes'): 'string',
    ('ts_parser', 'start'): 'string',
    ('ts_template', 'init'): 'string',
    ('ts_template', 'lexize'): 'string',
}
ROLES = {"of_type", "tablespace", "sfunc", "finalfunc", "combinefunc", "serialfunc", "deserialfunc", "sortop", "function", "family", "table", "template", "parser", "server"}


def capture(pg, container, schemas):
    """Every object of these kinds the database holds, as parts: {kind, key, parent, props}."""
    s = "ARRAY[" + ",".join("'" + x.replace("'", "''") + "'" for x in schemas) + "]::name[]"
    out = []
    for kind in ORDER:
        sql = Q[kind][2].replace("%(s)s", s)
        for r in json.loads(pg(container, f"SELECT coalesce(json_agg(x), '[]') FROM ({sql}) x;")):
            out.append({"kind": kind, "key": r["key"], "parent": r["schema"], "props": {k: v for k, v in r.items() if v is not None}})
    return out


def declare():
    """Each kind's options, as the engine's seed declares them: <prefix>_<name>, typed by what the catalog gives."""
    return {kind: Q[kind][1] for kind in ORDER}


def register(types):
    """The options of each kind as the lab's layout carries them: engine_postgresql.<kind>_options rows, moved to cortex.objects."""
    for kind in ORDER:
        t = f"engine_postgresql.{kind}_options"
        prefix = Q[kind][1]
        keys = sorted(f"{prefix}_{k}" for (kk, k) in types if kk == kind)
        if keys:
            OL.MOVED[t] = "cortex.objects"
            OL.KEYS[t] = keys
            for (kk, k), ty in types.items():
                if kk == kind:
                    OL.TYPES[(t, f"{prefix}_{k}")] = ty


def to_design(out, parts, add, role, grant, objects_by_key):
    """The parts as design rows: an object each, its options, its uses (dependencies as their role) or the names of what the
    design does not hold, its owner and grants."""
    ns = {n["name"]: n["id"] for n in out["cortex.namespaces"] if n["parent"]}
    made = {}
    for kind in ORDER:
        scope, prefix, _ = Q[kind]
        for p in (p for p in parts if p["kind"] == kind):
            pr = p["props"]
            i = made[(kind, p["key"])] = str(uuid.uuid7())
            owner = pr.get("owner")
            add("cortex.objects", {"id": i, "namespace": ns.get(pr["schema"]) if scope == "namespace" else None, "kind": kind,
                                   "name": pr["name"], "signature": pr.get("signature") or "", "parent": None,
                                   "position": len(out["cortex.objects"]) + 1, "comment": pr.get("comment"), "notes": None,
                                   "owner": role.get(owner), "owner_name": None if not owner or owner in role else owner})
            opts = {f"{prefix}_{k}": v for k, v in (pr.get("opts") or {}).items()}
            for r, target in (pr.get("refs") or {}).items():
                used = objects_by_key.get(target) or made.get(next((k for k in made if k[1] == target), None))
                if used:
                    d = str(uuid.uuid7())
                    add("cortex.dependencies", {"id": d, "object": i, "uses": used, "position": len(out["cortex.dependencies"]) + 1})
                    add("engine_postgresql.dependency_options", {"id": d, "as": r})
                else:
                    opts[f"{prefix}_{r}"] = target   # what the design does not hold (pg_catalog's), by name
            add(f"engine_postgresql.{kind}_options", {"id": i, **opts})
            if pr.get("acl"):
                grant(pr["acl"], object=i)
    return made


def back(st):
    """Each object of these kinds from the design read back: its name, schema, owner, options and what it uses, by name."""
    objs, ns = st["cortex.objects"], st["cortex.namespaces"]
    uses = defaultdict(dict)
    roles = st.get("engine_postgresql.dependency_options", {})
    for d in st["cortex.dependencies"].values():
        role = roles.get(d["id"], {}).get("as")
        if role:
            u = objs[d["uses"]]
            uses[d["object"]][role] = key_of(u, ns)
    out = []
    for kind in ORDER:
        prefix = Q[kind][1]
        for o in sorted((o for o in objs.values() if o["kind"] == kind), key=lambda o: o["position"]):
            opts = st.get(f"engine_postgresql.{kind}_options", {}).get(o["id"], {})
            pr = {k[len(prefix) + 1:]: v for k, v in opts.items() if k.startswith(prefix + "_")}
            refs = {k: v for k, v in pr.items() if k in ROLES and v}
            refs.update(uses[o["id"]])
            out.append({"kind": kind, "id": o["id"], "schema": ns[o["namespace"]]["name"] if o["namespace"] else None, "name": o["name"],
                        "signature": o["signature"], "owner": objs[o["owner"]]["name"] if o.get("owner") else o.get("owner_name"),
                        "comment": o["comment"], "opts": {k: v for k, v in pr.items() if k not in ROLES}, "refs": refs})
    return out


def key_of(o, ns):
    """How the catalog names an object another uses: a routine as regprocedure, a family as schema.name method, else schema.name."""
    schema = ns[o["namespace"]]["name"] if o.get("namespace") else None
    if o["kind"] in ("function", "procedure", "aggregate"):
        sig = o["signature"].replace(", ", ",")
        return (f"{schema}." if schema and schema != "public" else "") + o["name"] + sig
    if o["kind"] in ("operator_family", "operator_class"):
        return f"{schema}.{o['name']}{o['signature'].replace(' USING', '')}"
    return f"{schema}.{o['name']}" if schema else o["name"]


def qi(x):
    return x if x.replace("_", "").isalnum() and x.islower() and not x[0].isdigit() else '"' + x.replace('"', '""') + '"'


def lit(x):
    return "'" + str(x).replace("'", "''") + "'"


def full(o):
    return f"{qi(o['schema'])}.{qi(o['name'])}" if o["schema"] else qi(o["name"])


def options_clause(opts):
    return "OPTIONS (" + ", ".join(f"{qi(k)} {lit(v)}" for k, v in (o.partition("=")[::2] for o in opts)) + ")" if opts else ""


def write(items):
    """The statements that make these objects, in an order where each finds what it uses."""
    sql = []
    for o in items:
        k, p, r, f = o["kind"], o["opts"], o["refs"], full(o)
        if k == "tablespace":
            sql.append(f"CREATE TABLESPACE {qi(o['name'])} LOCATION {lit(p['location'])}"
                       + (f" WITH ({', '.join(p['tablespace_options'])})" if p.get("tablespace_options") else "") + ";")
        elif k == "language":
            sql.append(f"CREATE {'TRUSTED ' if p.get('trusted') else ''}LANGUAGE {qi(o['name'])} HANDLER {p['handler']}"
                       + (f" INLINE {p['inline']}" if p.get("inline") else "") + (f" VALIDATOR {p['validator']}" if p.get("validator") else "") + ";")
        elif k == "access_method":
            sql.append(f"CREATE ACCESS METHOD {qi(o['name'])} TYPE {'TABLE' if p['type'] == 't' else 'INDEX'} HANDLER {p.get('handler') or r.get('handler')};")
        elif k == "foreign_data_wrapper":
            sql.append(f"CREATE FOREIGN DATA WRAPPER {qi(o['name'])}" + (f" HANDLER {p['handler']}" if p.get("handler") else " NO HANDLER")
                       + (f" VALIDATOR {p['validator']}" if p.get("validator") else " NO VALIDATOR") + (" " + options_clause(p.get("fdw_options")) if p.get("fdw_options") else "") + ";")
        elif k == "foreign_server":
            sql.append(f"CREATE SERVER {qi(o['name'])}" + (f" TYPE {lit(p['type'])}" if p.get("type") else "") + (f" VERSION {lit(p['version'])}" if p.get("version") else "")
                       + f" FOREIGN DATA WRAPPER {qi(p['wrapper'])}" + (" " + options_clause(p.get("server_options")) if p.get("server_options") else "") + ";")
            for m in p.get("user_mappings") or []:
                sql.append(f"CREATE USER MAPPING FOR {'PUBLIC' if m['role'] == 'PUBLIC' else qi(m['role'])} SERVER {qi(o['name'])}"
                           + (" " + options_clause(m["options"]) if m.get("options") else "") + ";")
        elif k == "foreign_table":
            cols = [f"{qi(c['name'])} {c['type']}" + (" " + options_clause(c["options"]) if c.get("options") else "")
                    + (" NOT NULL" if c["not_null"] else "") + (f" DEFAULT {c['default']}" if c.get("default") else "") for c in p.get("columns") or []]
            sql.append(f"CREATE FOREIGN TABLE {f} ({', '.join(cols)}) SERVER {qi(r['server'])}" + (" " + options_clause(p.get("table_options")) if p.get("table_options") else "") + ";")
        elif k == "operator_family":
            sql.append(f"CREATE OPERATOR FAMILY {f} USING {p['method']};")
        elif k == "operator":
            parts = [f"FUNCTION = {r['function'].split('(')[0]}"] + ([f"LEFTARG = {p['leftarg']}"] if p.get("leftarg") else []) + [f"RIGHTARG = {p['rightarg']}"]
            for key, word in (("commutator", "COMMUTATOR"), ("negator", "NEGATOR")):
                if p.get(key):
                    name = p[key].split("(")[0]
                    sch, _, op = name.rpartition(".")
                    parts.append(f"{word} = OPERATOR({sch + '.' if sch else ''}{op})")
            parts += [x for x, on in (("HASHES", p.get("hashes")), ("MERGES", p.get("merges"))) if on]
            parts += [f"{w} = {p[key]}" for key, w in (("restrict", "RESTRICT"), ("join", "JOIN")) if p.get(key)]
            sql.append(f"CREATE OPERATOR {o['schema'] + '.' if o['schema'] else ''}{o['name']} ({', '.join(parts)});")
        elif k == "operator_class":
            fam = r.get("family", "")
            members = [f"OPERATOR {i['number']} {i['name'].split('(')[0]}{'(' + i['name'].split('(')[1] if '(' in i['name'] else ''}" if i["what"] == "operator"
                     else f"FUNCTION {i['number']} {i['name']}" for i in p.get("items") or []]
            fam_name = fam.rsplit(" ", 1)[0]
            sql.append(f"CREATE OPERATOR CLASS {f}{' DEFAULT' if p.get('is_default') else ''} FOR TYPE {p['for_type']} USING {p['method']}"
                       + (f" FAMILY {fam_name}" if fam_name and fam_name.split('.')[-1] != o["name"] else "")
                       + f" AS {', '.join(members)}" + (f", STORAGE {p['storage']}" if p.get("storage") else "") + ";")
        elif k == "aggregate":
            parts = [f"SFUNC = {r['sfunc'].split('(')[0]}", f"STYPE = {p['stype']}"]
            parts += [f"{w} = {r[key].split('(')[0]}" for key, w in (("finalfunc", "FINALFUNC"), ("combinefunc", "COMBINEFUNC"),
                                                                       ("serialfunc", "SERIALFUNC"), ("deserialfunc", "DESERIALFUNC")) if r.get(key)]
            parts += ["FINALFUNC_EXTRA"] if p.get("finalfunc_extra") else []
            parts += [f"INITCOND = {lit(p['initcond'])}"] if p.get("initcond") is not None else []
            parts += [f"SORTOP = {r['sortop'].split('(')[0]}"] if r.get("sortop") else []
            parts += [f"SSPACE = {p['sspace']}"] if p.get("sspace") else []
            parts += [f"PARALLEL = {dict(s='SAFE', r='RESTRICTED').get(p.get('parallel'))}"] if p.get("parallel") in ("s", "r") else []
            sql.append(f"CREATE AGGREGATE {f}({p['arguments']}) ({', '.join(parts)});")
        elif k == "cast":
            how = {"i": "WITH INOUT", "b": "WITHOUT FUNCTION"}.get(p["method"]) or f"WITH FUNCTION {r['function']}"
            sql.append(f"CREATE CAST ({p['source']} AS {p['target']}) {how}" + {"a": " AS ASSIGNMENT", "i": " AS IMPLICIT"}.get(p["context"], "") + ";")
        elif k == "conversion":
            sql.append(f"CREATE {'DEFAULT ' if p.get('is_default') else ''}CONVERSION {f} FOR {lit(p['for_encoding'])} TO {lit(p['to_encoding'])} FROM {r['function'].split('(')[0]};")
        elif k == "ts_template":
            sql.append(f"CREATE TEXT SEARCH TEMPLATE {f} (" + (f"INIT = {p['init']}, " if p.get("init") else "") + f"LEXIZE = {p['lexize']});")
        elif k == "ts_parser":
            sql.append(f"CREATE TEXT SEARCH PARSER {f} (START = {p['start']}, GETTOKEN = {p['gettoken']}, END = {p['end']}, LEXTYPES = {p['lextypes']}"
                       + (f", HEADLINE = {p['headline']}" if p.get("headline") else "") + ");")
        elif k == "ts_dictionary":
            sql.append(f"CREATE TEXT SEARCH DICTIONARY {f} (TEMPLATE = {r['template']}" + (f", {p['init_options']}" if p.get("init_options") else "") + ");")
        elif k == "ts_configuration":
            sql.append(f"CREATE TEXT SEARCH CONFIGURATION {f} (PARSER = {r['parser']});")
            for m in p.get("mappings") or []:
                sql.append(f"ALTER TEXT SEARCH CONFIGURATION {f} ADD MAPPING FOR {m['token']} WITH {', '.join(m['dictionaries'])};")
        elif k == "statistics":
            sql.append(p["definition"] + ";")
            if p.get("target") not in (None, -1):
                sql.append(f"ALTER STATISTICS {f} SET STATISTICS {p['target']};")
        elif k == "publication":
            what = []
            if p.get("all_tables"):
                what = ["FOR ALL TABLES"]
            else:
                targets = [f"TABLE ONLY {t['table']}" + (f" ({', '.join(qi(c) for c in t['columns'])})" if t.get("columns") else "")
                           + (f" WHERE ({t['where']})" if t.get("where") else "") for t in p.get("tables") or []]
                targets += [f"TABLES IN SCHEMA {qi(s)}" for s in p.get("schemas") or []]
                what = ["FOR " + ", ".join(targets)] if targets else []
            publish = ", ".join(w for w in ("insert", "update", "delete", "truncate") if p.get(w))
            sql.append(f"CREATE PUBLICATION {qi(o['name'])} {' '.join(what)} WITH (publish = {lit(publish)}" + (", publish_via_partition_root = true" if p.get("via_root") else "") + ");")
        elif k == "subscription":
            stream = {"f": "off", "t": "on", "p": "parallel"}.get(p.get("stream"), "off")
            withs = ["connect = false", f"enabled = {str(bool(p.get('enabled'))).lower()}", "create_slot = false",
                     f"slot_name = {lit(p['slot_name']) if p.get('slot_name') else 'NONE'}", f"binary = {str(bool(p.get('binary'))).lower()}",
                     f"streaming = {stream}", f"synchronous_commit = {lit(p.get('synchronous_commit') or 'off')}",
                     f"disable_on_error = {str(bool(p.get('disable_on_error'))).lower()}"]
            sql.append(f"CREATE SUBSCRIPTION {qi(o['name'])} CONNECTION {lit(p['connection'])} PUBLICATION {', '.join(qi(x) for x in p['publications'])}"
                       f" WITH ({', '.join(withs)});")
        elif k == "event_trigger":
            sql.append(f"CREATE EVENT TRIGGER {qi(o['name'])} ON {p['event']}" + (f" WHEN TAG IN ({', '.join(lit(t) for t in p['tags'])})" if p.get("tags") else "")
                       + f" EXECUTE FUNCTION {r['function'].split('(')[0]}();")
            state = {"D": "DISABLE", "R": "ENABLE REPLICA", "A": "ENABLE ALWAYS"}.get(p.get("enabled"))
            if state:
                sql.append(f"ALTER EVENT TRIGGER {qi(o['name'])} {state};")
        word = {"tablespace": "TABLESPACE", "language": "LANGUAGE", "access_method": None, "cast": None, "ts_template": None, "ts_parser": None, "foreign_data_wrapper": "FOREIGN DATA WRAPPER",
                "foreign_server": "SERVER", "foreign_table": "FOREIGN TABLE", "operator_family": "OPERATOR FAMILY", "operator_class": "OPERATOR CLASS",
                "aggregate": "AGGREGATE", "conversion": "CONVERSION", "ts_dictionary": "TEXT SEARCH DICTIONARY", "ts_configuration": "TEXT SEARCH CONFIGURATION",
                "statistics": "STATISTICS", "publication": "PUBLICATION", "event_trigger": "EVENT TRIGGER", "operator": "OPERATOR",
                "subscription": "SUBSCRIPTION"}[k]
        if word and o.get("owner"):
            target = f
            if k == "aggregate":
                target = f"{f}{o['signature'].replace(',', ', ') if o['signature'] else '()'}"
            elif k in ("operator_family", "operator_class"):
                target = f"{f}{o['signature']}"
            elif k == "operator":
                target = f"{o['schema'] + '.' if o['schema'] else ''}{o['name']} {o['signature']}"
            sql.append(f"ALTER {word} {target} OWNER TO {qi(o['owner'])};")
    for o in items:
        if o.get("comment") and o["kind"] in ("tablespace", "language", "foreign_data_wrapper", "foreign_server", "publication", "event_trigger", "access_method"):
            word = {"tablespace": "TABLESPACE", "language": "LANGUAGE", "foreign_data_wrapper": "FOREIGN DATA WRAPPER", "foreign_server": "SERVER",
                    "publication": "PUBLICATION", "event_trigger": "EVENT TRIGGER", "access_method": "ACCESS METHOD"}[o["kind"]]
            sql.append(f"COMMENT ON {word} {qi(o['name'])} IS {lit(o['comment'])};")
    return "\n".join(sql) + "\n"


register(TYPES)
OL.MOVED["engine_postgresql.dependency_options"] = "cortex.dependencies"
OL.KEYS["engine_postgresql.dependency_options"] = ["as"]
OL.TYPES[("engine_postgresql.dependency_options", "as")] = "string"
