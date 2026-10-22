-- modules/weave/db-roles-database.sql
-- The per-database part of db-roles.sql. Runs in each Weave database as the
-- bootstrap superuser. Idempotent.

\set ON_ERROR_STOP on

-- The owner of the audit tables: weave_audit, or weave_app for the one start
-- that runs a migration on an audit table (see the module header).
\if :{?audit_owner}
\else
  \set audit_owner weave_audit
\endif
SELECT set_config('weave.audit_owner', :'audit_owner', false) AS audit_owner_set \gset

-- weave_app may connect, and nothing more at the database level: no CREATE
-- (no new schema that could put a copy of an audit table in front of public)
-- and no TEMPORARY (no temp table that could do the same).
SELECT format('REVOKE CREATE, TEMPORARY ON DATABASE %I FROM weave_app, PUBLIC', current_database()) \gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO weave_app', current_database()) \gexec

-- The schema owner can drop any table in it, so the superuser keeps it.
ALTER SCHEMA public OWNER TO weave;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE, CREATE ON SCHEMA public TO weave_app;

-- weave_app cannot create extensions now. Make the one that the schema needs,
-- so that db:prepare can load the schema on a new host.
SELECT current_database() = 'weave_production' AS is_primary \gset
\if :is_primary
  CREATE EXTENSION IF NOT EXISTS fuzzystrmatch;
\endif

-- Every old version of an audit row (status and notes), in the primary
-- database. Only its trigger writes to it.
\if :is_primary
  CREATE TABLE IF NOT EXISTS public.audits1984_audit_versions (
    id bigserial PRIMARY KEY,
    audit_id bigint NOT NULL,
    status integer,
    notes text,
    auditor_id bigint,
    changed_at timestamp(6) NOT NULL DEFAULT now()
  );
\endif

DO $$
DECLARE
  audit_tables text[] := ARRAY[
    'console1984_users', 'console1984_sessions', 'console1984_commands',
    'console1984_sensitive_accesses', 'audits1984_audits', 'audits1984_audit_versions',
    'console_access_requests'
  ];
  -- The columns the app changes in an audit table. Nothing else can change.
  -- The triggers below limit how they change.
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
  -- A copy of an audit table outside public could take its place in the
  -- search path. Stop if one exists.
  IF EXISTS (
    SELECT FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relname = ANY (audit_tables) AND n.nspname <> 'public'
  ) THEN
    RAISE EXCEPTION 'an audit table exists outside the public schema';
  END IF;

  -- Everything in the public schema goes to weave_app, except the audit
  -- tables. A sequence that belongs to a table moves with its table.
  FOR r IN
    SELECT c.oid, c.relname, c.relkind
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p', 'v', 'm', 'f', 'S')
      AND NOT EXISTS (SELECT FROM pg_depend d WHERE d.objid = c.oid AND d.deptype IN ('a', 'i', 'e'))
  LOOP
    IF r.relname = ANY (audit_tables) THEN
      EXECUTE format('ALTER TABLE public.%I OWNER TO %I', r.relname, current_setting('weave.audit_owner'));
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

  -- Enums, domains and functions that are not part of an extension. The
  -- weave_audit_* functions below stay with weave_audit.
  FOR r IN
    SELECT t.oid FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE n.nspname = 'public' AND t.typtype IN ('e', 'd')
      AND NOT EXISTS (SELECT FROM pg_depend d WHERE d.objid = t.oid AND d.deptype = 'e')
  LOOP
    EXECUTE format('ALTER TYPE %s OWNER TO weave_app', r.oid::regtype);
  END LOOP;
  FOR r IN
    SELECT p.oid FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname NOT LIKE 'weave\_audit\_%'
      AND NOT EXISTS (SELECT FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')
  LOOP
    EXECUTE format('ALTER ROUTINE %s OWNER TO weave_app', r.oid::regprocedure);
  END LOOP;

  -- weave_app may read the audit tables and add rows, and change only the
  -- listed columns. No DELETE, TRUNCATE, REFERENCES or other UPDATE. It may
  -- only read the version table.
  FOR r IN
    SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relname = ANY (audit_tables)
  LOOP
    EXECUTE format('REVOKE ALL ON TABLE public.%I FROM weave_app, PUBLIC', r.relname);
    IF r.relname = 'audits1984_audit_versions' THEN
      EXECUTE format('GRANT SELECT ON TABLE public.%I TO weave_app', r.relname);
      CONTINUE;
    END IF;
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

-- Guards on the columns that weave_app may change. They allow only the changes
-- that the app makes, so a console cannot rewrite who used a past console or
-- unlink a flagged command. The functions and triggers belong to weave_audit,
-- and weave_app can neither replace nor drop them.

CREATE OR REPLACE FUNCTION public.weave_audit_guard_command() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog AS $fn$
BEGIN
  IF OLD.sensitive_access_id IS NOT NULL AND NEW.sensitive_access_id IS DISTINCT FROM OLD.sensitive_access_id THEN
    RAISE EXCEPTION 'console1984_commands.sensitive_access_id can be set only once';
  END IF;
  RETURN NEW;
END $fn$;

-- A request starts empty and pending. It changes from pending to confirmed or
-- rejected once, and the user, time and IP are set in that change. A
-- confirmed request is claimed once. Later, the user can only become NULL
-- (the foreign key does this when the user is deleted).
CREATE OR REPLACE FUNCTION public.weave_audit_guard_request() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog AS $fn$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'pending' OR NEW.user_id IS NOT NULL OR NEW.confirmed_at IS NOT NULL
       OR NEW.confirmed_ip IS NOT NULL OR NEW.claimed_at IS NOT NULL THEN
      RAISE EXCEPTION 'a console access request must start pending and empty';
    END IF;
    RETURN NEW;
  END IF;

  IF OLD.status = 'pending' THEN
    IF NEW.status = 'pending' THEN
      IF NEW.user_id IS NOT NULL OR NEW.confirmed_at IS NOT NULL OR NEW.confirmed_ip IS NOT NULL OR NEW.claimed_at IS NOT NULL THEN
        RAISE EXCEPTION 'a pending console access request stays empty';
      END IF;
    ELSIF NEW.status NOT IN ('confirmed', 'rejected') OR NEW.claimed_at IS NOT NULL THEN
      RAISE EXCEPTION 'a console access request can only be confirmed or rejected';
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.status IS DISTINCT FROM OLD.status
     OR NEW.confirmed_at IS DISTINCT FROM OLD.confirmed_at
     OR NEW.confirmed_ip IS DISTINCT FROM OLD.confirmed_ip
     OR (NEW.user_id IS DISTINCT FROM OLD.user_id AND NEW.user_id IS NOT NULL)
     OR (OLD.claimed_at IS NOT NULL AND NEW.claimed_at IS DISTINCT FROM OLD.claimed_at)
     OR (OLD.claimed_at IS NULL AND NEW.claimed_at IS NOT NULL AND OLD.status <> 'confirmed') THEN
    RAISE EXCEPTION 'a decided console access request cannot change';
  END IF;
  RETURN NEW;
END $fn$;

-- Every change to an audit (its status or notes) keeps the old version.
CREATE OR REPLACE FUNCTION public.weave_audit_keep_audit_version() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $fn$
BEGIN
  INSERT INTO public.audits1984_audit_versions (audit_id, status, notes, auditor_id)
  VALUES (OLD.id, OLD.status, OLD.notes, OLD.auditor_id);
  RETURN NEW;
END $fn$;

ALTER FUNCTION public.weave_audit_guard_command() OWNER TO weave_audit;
ALTER FUNCTION public.weave_audit_guard_request() OWNER TO weave_audit;
ALTER FUNCTION public.weave_audit_keep_audit_version() OWNER TO weave_audit;
REVOKE ALL ON FUNCTION public.weave_audit_keep_audit_version() FROM PUBLIC;

SELECT to_regclass('public.console1984_commands') IS NOT NULL AS has_commands,
       to_regclass('public.console_access_requests') IS NOT NULL AS has_requests,
       to_regclass('public.audits1984_audits') IS NOT NULL AS has_audits \gset

\if :has_commands
  CREATE OR REPLACE TRIGGER weave_audit_guard BEFORE UPDATE ON public.console1984_commands
    FOR EACH ROW EXECUTE FUNCTION public.weave_audit_guard_command();
\endif
\if :has_requests
  CREATE OR REPLACE TRIGGER weave_audit_guard BEFORE INSERT OR UPDATE ON public.console_access_requests
    FOR EACH ROW EXECUTE FUNCTION public.weave_audit_guard_request();
\endif
\if :has_audits
  CREATE OR REPLACE TRIGGER weave_audit_keep_version BEFORE UPDATE ON public.audits1984_audits
    FOR EACH ROW EXECUTE FUNCTION public.weave_audit_keep_audit_version();
\endif
