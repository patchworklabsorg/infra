-- modules/weave/db-roles-database.sql
-- The per-database part of db-roles.sql. Runs in each Weave database as the
-- bootstrap superuser. Idempotent.

\set ON_ERROR_STOP on

DO $$
DECLARE
  audit_tables text[] := ARRAY[
    'console1984_users', 'console1984_sessions', 'console1984_commands',
    'console1984_sensitive_accesses', 'audits1984_audits', 'console_access_requests'
  ];
  -- The columns the app changes in an audit table. Nothing else can change.
  audit_update_columns jsonb := '{
    "console1984_sessions": ["updated_at"],
    "console1984_commands": ["sensitive_access_id", "updated_at"],
    "audits1984_audits": ["notes", "status", "updated_at"],
    "console_access_requests": ["status", "user_id", "confirmed_at", "confirmed_ip", "claimed_at", "updated_at"]
  }';
  r record;
  seq text;
  cols text;
BEGIN
  -- The schema owner can drop any table in it, so the superuser keeps it.
  ALTER SCHEMA public OWNER TO weave;
  GRANT USAGE, CREATE ON SCHEMA public TO weave_app;

  -- Everything in the public schema goes to weave_app, except the audit
  -- tables. A sequence that belongs to a table moves with its table.
  FOR r IN
    SELECT c.oid, c.relname, c.relkind
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p', 'v', 'm', 'f', 'S')
      AND NOT EXISTS (SELECT FROM pg_depend d WHERE d.objid = c.oid AND d.deptype IN ('a', 'i', 'e'))
  LOOP
    IF r.relname = ANY (audit_tables) THEN
      EXECUTE format('ALTER TABLE public.%I OWNER TO weave_audit', r.relname);
    ELSIF r.relkind = 'S' THEN
      EXECUTE format('ALTER SEQUENCE public.%I OWNER TO weave_app', r.relname);
    ELSIF r.relkind = 'v' THEN
      EXECUTE format('ALTER VIEW public.%I OWNER TO weave_app', r.relname);
    ELSIF r.relkind = 'm' THEN
      EXECUTE format('ALTER MATERIALIZED VIEW public.%I OWNER TO weave_app', r.relname);
    ELSIF r.relkind = 'f' THEN
      EXECUTE format('ALTER FOREIGN TABLE public.%I OWNER TO weave_app', r.relname);
    ELSE
      EXECUTE format('ALTER TABLE public.%I OWNER TO weave_app', r.relname);
    END IF;
  END LOOP;

  -- Enums, domains and functions that are not part of an extension.
  FOR r IN
    SELECT t.oid FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE n.nspname = 'public' AND t.typtype IN ('e', 'd')
      AND NOT EXISTS (SELECT FROM pg_depend d WHERE d.objid = t.oid AND d.deptype = 'e')
  LOOP
    EXECUTE format('ALTER TYPE %s OWNER TO weave_app', r.oid::regtype);
  END LOOP;
  FOR r IN
    SELECT p.oid FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND NOT EXISTS (SELECT FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')
  LOOP
    EXECUTE format('ALTER ROUTINE %s OWNER TO weave_app', r.oid::regprocedure);
  END LOOP;

  -- The audit tables: weave_app may read and add rows, and change only the
  -- listed columns. No DELETE, TRUNCATE or other UPDATE.
  FOR r IN
    SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relname = ANY (audit_tables)
  LOOP
    EXECUTE format('REVOKE ALL ON TABLE public.%I FROM weave_app, PUBLIC', r.relname);
    EXECUTE format('GRANT SELECT, INSERT ON TABLE public.%I TO weave_app', r.relname);
    IF audit_update_columns ? r.relname THEN
      SELECT string_agg(quote_ident(col), ', ') INTO cols
      FROM jsonb_array_elements_text(audit_update_columns -> r.relname) AS col;
      EXECUTE format('GRANT UPDATE (%s) ON TABLE public.%I TO weave_app', cols, r.relname);
    END IF;
    seq := pg_get_serial_sequence(format('public.%I', r.relname), 'id');
    IF seq IS NOT NULL THEN
      EXECUTE format('GRANT USAGE, SELECT ON SEQUENCE %s TO weave_app', seq);
    END IF;
  END LOOP;
END $$;
