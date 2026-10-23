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

-- The event trigger at the end of this file keeps every trigger on users and
-- user_roles as the last locked run pinned it. A flagged run turns it off
-- first, so that the migration can change them. The run after the migration
-- pins them again and turns it on again.
SELECT EXISTS (SELECT FROM pg_event_trigger WHERE evtname = 'weave_audit_keep_capture_triggers') AS has_capture_guard,
       EXISTS (SELECT FROM pg_event_trigger WHERE evtname = 'weave_audit_keep_capture_triggers' AND evtenabled <> 'D') AS capture_guard_on,
       :'audit_owner' = 'weave_audit' AS audit_locked \gset
\if :audit_locked
  -- With the event trigger on, the triggers can differ from the pins only if
  -- a superuser turned event triggers off (SET event_triggers = off). Stop
  -- here and name them. Otherwise the first DDL below fails with a message
  -- that names no trigger.
  \if :capture_guard_on
    DO $$
    DECLARE drift text := public.weave_audit_capture_trigger_drift();
    BEGIN
      IF drift IS NOT NULL THEN
        RAISE EXCEPTION 'permanent log: these triggers differ from the pinned ones: %', drift
          USING HINT = 'Check them. To accept them as they are, start once with allow-audit-migration (modules/weave/default.nix in the infra repo).';
      END IF;
    END $$;
  \endif
\else
  \if :has_capture_guard
    ALTER EVENT TRIGGER weave_audit_keep_capture_triggers DISABLE;
  \endif
\endif

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

-- Every version of an audit row, in the primary database: the new row at
-- INSERT and the old row at each UPDATE. Only its trigger writes to it, and
-- it always belongs to weave_audit, also during a flagged migration.
\if :is_primary
  CREATE TABLE IF NOT EXISTS public.audits1984_audit_versions (
    id bigserial PRIMARY KEY,
    audit_id bigint NOT NULL,
    status integer,
    notes text,
    auditor_id bigint,
    changed_at timestamp(6) NOT NULL DEFAULT now()
  );
  ALTER TABLE public.audits1984_audit_versions ADD COLUMN IF NOT EXISTS operation text;
  ALTER TABLE public.audits1984_audit_versions OWNER TO weave_audit;
\endif

DO $$
DECLARE
  -- audits1984_audit_versions is not in this list: it always belongs to
  -- weave_audit (see above).
  -- privileged_attribute_changes is Weave's permanent log of privileged
  -- attributes (docs/KYC.md in the Weave repo). It has no UPDATE columns:
  -- weave_app may only read it and add rows, as its capture triggers do.
  audit_tables text[] := ARRAY[
    'console1984_users', 'console1984_sessions', 'console1984_commands',
    'console1984_sensitive_accesses', 'audits1984_audits', 'console_access_requests',
    'privileged_attribute_changes'
  ];
  -- The trigger functions of the permanent log, made by Weave's migrations.
  -- They belong to the owner of the audit tables, so weave_app cannot replace
  -- them. They stay SECURITY INVOKER: the log row records CURRENT_USER.
  log_functions text[] := ARRAY[
    'log_privileged_attribute_changes', 'refuse_privileged_attribute_change_edits',
    'log_user_role_changes', 'refuse_user_role_edits'
  ];
  locked boolean := current_setting('weave.audit_owner') = 'weave_audit';
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
    WHERE (c.relname = ANY (audit_tables) OR c.relname = 'audits1984_audit_versions') AND n.nspname <> 'public'
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
    IF r.relname IN ('audits1984_audit_versions', 'weave_audit_pinned_capture_triggers') THEN
      CONTINUE;
    ELSIF r.relname = ANY (audit_tables) THEN
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
  -- weave_audit_* functions below stay with weave_audit, and the log
  -- functions go to the owner of the audit tables.
  FOR r IN
    SELECT t.oid FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE n.nspname = 'public' AND t.typtype IN ('e', 'd')
      AND NOT EXISTS (SELECT FROM pg_depend d WHERE d.objid = t.oid AND d.deptype = 'e')
  LOOP
    EXECUTE format('ALTER TYPE %s OWNER TO weave_app', r.oid::regtype);
  END LOOP;
  FOR r IN
    SELECT p.oid, p.proname, p.pronargs FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname NOT LIKE 'weave\_audit\_%'
      AND NOT EXISTS (SELECT FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')
  LOOP
    IF r.proname = ANY (log_functions) AND r.pronargs = 0 THEN
      EXECUTE format('ALTER ROUTINE %s OWNER TO %I', r.oid::regprocedure, current_setting('weave.audit_owner'));
    ELSE
      EXECUTE format('ALTER ROUTINE %s OWNER TO weave_app', r.oid::regprocedure);
    END IF;
  END LOOP;

  -- weave_app may only read the version table.
  IF to_regclass('public.audits1984_audit_versions') IS NOT NULL THEN
    REVOKE ALL ON TABLE public.audits1984_audit_versions FROM weave_app, PUBLIC;
    GRANT SELECT ON TABLE public.audits1984_audit_versions TO weave_app;
  END IF;

  -- weave_app may read the audit tables and add rows, and change only the
  -- listed columns. No DELETE, TRUNCATE, REFERENCES or other UPDATE. During a
  -- flagged migration weave_app owns them, and an owner keeps every right, so
  -- that a data migration (an UPDATE, a new foreign key) works. The next run
  -- takes them back and sets these grants again.
  FOR r IN
    SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relname = ANY (audit_tables)
      AND locked
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

-- Every audit keeps its versions: the new row at INSERT, and the old row at
-- each change of its status or notes.
CREATE OR REPLACE FUNCTION public.weave_audit_keep_audit_version() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $fn$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO public.audits1984_audit_versions (audit_id, status, notes, auditor_id, operation)
    VALUES (NEW.id, NEW.status, NEW.notes, NEW.auditor_id, 'insert');
  ELSE
    INSERT INTO public.audits1984_audit_versions (audit_id, status, notes, auditor_id, operation)
    VALUES (OLD.id, OLD.status, OLD.notes, OLD.auditor_id, 'update');
  END IF;
  RETURN NEW;
END $fn$;

-- Nobody reviews their own console session. The Console1984 username is
-- "<full name> (<PWL id>)" (ConsoleAccess.username_for in Weave), and the
-- auditor is a users row (find_current_auditor), so the two match on the PWL
-- id. An audit cannot move to another session or auditor either.
CREATE OR REPLACE FUNCTION public.weave_audit_guard_audit() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog AS $fn$
BEGIN
  IF TG_OP = 'UPDATE' AND (NEW.session_id IS DISTINCT FROM OLD.session_id OR NEW.auditor_id IS DISTINCT FROM OLD.auditor_id) THEN
    RAISE EXCEPTION 'an audit cannot change its session or auditor';
  END IF;
  IF EXISTS (
    SELECT FROM public.console1984_sessions s
    JOIN public.console1984_users cu ON cu.id = s.user_id
    JOIN public.users u ON u.id = NEW.auditor_id
    WHERE s.id = NEW.session_id AND u.p_id <> ''
      AND right(cu.username, length(u.p_id) + 2) = '(' || u.p_id || ')'
  ) THEN
    RAISE EXCEPTION 'nobody can audit their own console session';
  END IF;
  RETURN NEW;
END $fn$;

ALTER FUNCTION public.weave_audit_guard_command() OWNER TO weave_audit;
ALTER FUNCTION public.weave_audit_guard_request() OWNER TO weave_audit;
ALTER FUNCTION public.weave_audit_keep_audit_version() OWNER TO weave_audit;
ALTER FUNCTION public.weave_audit_guard_audit() OWNER TO weave_audit;
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
  -- Triggers fire in name order: the guard first, then the version.
  CREATE OR REPLACE TRIGGER weave_audit_guard BEFORE INSERT OR UPDATE ON public.audits1984_audits
    FOR EACH ROW EXECUTE FUNCTION public.weave_audit_guard_audit();
  CREATE OR REPLACE TRIGGER weave_audit_keep_version BEFORE INSERT OR UPDATE ON public.audits1984_audits
    FOR EACH ROW EXECUTE FUNCTION public.weave_audit_keep_audit_version();
\endif

-- The capture triggers of the permanent log are on users and user_roles,
-- which weave_app owns. An owner can disable, drop or replace a trigger on its
-- table, or add its own (a BEFORE trigger that changes role, or that turns a
-- revoked user_roles row back into an active grant, writes no log row). So
-- ownership alone does not keep them. An event trigger does: after each DDL
-- command in the primary database, by any role, it compares every trigger on
-- users and user_roles (not the internal foreign key triggers) with the
-- pinned set. A missing, disabled, changed or new trigger makes it refuse the
-- command. Other DDL on these tables (columns, indexes, constraints) works.
-- A superuser can still turn event triggers off for a session; the check at
-- the top of this file then names the drift at the next locked run.
--
-- Each locked run pins the triggers that exist then, if the log exists.
-- Before the log exists, nothing is pinned and the event trigger checks
-- nothing, so the migration that makes the log can add its triggers. A
-- flagged run turns the event trigger off (top of this file) and does not
-- pin, so the migration can change the triggers. The run after it pins the
-- new set.
\if :is_primary
  CREATE TABLE IF NOT EXISTS public.weave_audit_pinned_capture_triggers (
    table_name text NOT NULL,
    trigger_name text NOT NULL,
    enabled text NOT NULL,
    definition text NOT NULL
  );
  ALTER TABLE public.weave_audit_pinned_capture_triggers OWNER TO weave_audit;
  REVOKE ALL ON TABLE public.weave_audit_pinned_capture_triggers FROM weave_app, PUBLIC;
  GRANT SELECT ON TABLE public.weave_audit_pinned_capture_triggers TO weave_app;

  -- Every trigger on users and user_roles that is not internal, with its
  -- state and definition. The fixed search_path keeps pg_get_triggerdef the
  -- same for every caller.
  CREATE OR REPLACE FUNCTION public.weave_audit_capture_triggers()
  RETURNS TABLE (table_name text, trigger_name text, enabled text, definition text)
  LANGUAGE sql STABLE SET search_path = pg_catalog AS $fn$
    SELECT c.relname::text, t.tgname::text, t.tgenabled::text, pg_get_triggerdef(t.oid)
    FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relname IN ('users', 'user_roles') AND NOT t.tgisinternal
  $fn$;

  -- The triggers that differ from the pins, in either direction, or NULL.
  -- NULL also when nothing is pinned.
  CREATE OR REPLACE FUNCTION public.weave_audit_capture_trigger_drift() RETURNS text
  LANGUAGE sql STABLE SET search_path = pg_catalog AS $fn$
    SELECT string_agg(DISTINCT d.table_name || '.' || d.trigger_name, ', ')
    FROM (
      (SELECT p.table_name, p.trigger_name, p.enabled, p.definition FROM public.weave_audit_pinned_capture_triggers p
       EXCEPT
       SELECT * FROM public.weave_audit_capture_triggers())
      UNION ALL
      (SELECT * FROM public.weave_audit_capture_triggers()
       EXCEPT
       SELECT p.table_name, p.trigger_name, p.enabled, p.definition FROM public.weave_audit_pinned_capture_triggers p)
    ) d
    WHERE EXISTS (SELECT FROM public.weave_audit_pinned_capture_triggers)
  $fn$;

  CREATE OR REPLACE FUNCTION public.weave_audit_keep_capture_triggers() RETURNS event_trigger
  LANGUAGE plpgsql SET search_path = pg_catalog AS $fn$
  DECLARE drift text := public.weave_audit_capture_trigger_drift();
  BEGIN
    IF drift IS NOT NULL THEN
      RAISE EXCEPTION 'the capture triggers of privileged_attribute_changes cannot change: the triggers on users and user_roles are pinned (%)', drift
        USING HINT = 'A migration that changes them needs allow-audit-migration (modules/weave/default.nix in the infra repo).';
    END IF;
  END $fn$;

  ALTER FUNCTION public.weave_audit_capture_triggers() OWNER TO weave_audit;
  ALTER FUNCTION public.weave_audit_capture_trigger_drift() OWNER TO weave_audit;
  ALTER FUNCTION public.weave_audit_keep_capture_triggers() OWNER TO weave_audit;

  \if :audit_locked
    BEGIN;
    DELETE FROM public.weave_audit_pinned_capture_triggers;
    INSERT INTO public.weave_audit_pinned_capture_triggers SELECT * FROM public.weave_audit_capture_triggers()
      WHERE to_regclass('public.privileged_attribute_changes') IS NOT NULL;
    SELECT NOT EXISTS (SELECT FROM pg_event_trigger WHERE evtname = 'weave_audit_keep_capture_triggers') AS create_capture_guard \gset
    \if :create_capture_guard
      CREATE EVENT TRIGGER weave_audit_keep_capture_triggers ON ddl_command_end
        EXECUTE FUNCTION public.weave_audit_keep_capture_triggers();
    \endif
    ALTER EVENT TRIGGER weave_audit_keep_capture_triggers ENABLE;
    COMMIT;

    -- With the log in place, every capture trigger must be there and on.
    DO $$
    DECLARE missing text;
    BEGIN
      IF to_regclass('public.privileged_attribute_changes') IS NOT NULL THEN
        SELECT string_agg(want.t || '.' || want.g, ', ') INTO missing
        FROM (VALUES ('users', 'log_privileged_attribute_changes'), ('user_roles', 'log_user_role_changes'),
                     ('user_roles', 'user_roles_append_only'), ('user_roles', 'user_roles_no_truncate')) AS want (t, g)
        WHERE (want.t = 'users' OR to_regclass('public.user_roles') IS NOT NULL)
          AND NOT EXISTS (SELECT FROM public.weave_audit_pinned_capture_triggers p
                          WHERE p.table_name = want.t AND p.trigger_name = want.g AND p.enabled IN ('O', 'A'));
        IF missing IS NOT NULL THEN
          RAISE WARNING 'permanent log: these triggers are missing or disabled: %', missing;
        END IF;
      END IF;
    END $$;
  \endif
\endif
