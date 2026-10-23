-- tests/weave-db-roles-log-migration-1.sql
-- What Weave's migration 20261013140100_create_privileged_attribute_changes
-- does to the database. The function and trigger SQL is a copy from the
-- migration, with search_path = pg_catalog and public. table names.
-- tests/weave-db-roles.nix runs this file as weave_app in one transaction, as
-- db:prepare does. The test users table has no boolean role columns, so the
-- users trigger lists only role.

\set ON_ERROR_STOP on

-- 20261013140100_create_privileged_attribute_changes
CREATE TABLE privileged_attribute_changes (
  id bigserial PRIMARY KEY,
  user_id bigint NOT NULL,
  user_p_id varchar,
  attribute_name varchar NOT NULL,
  old_value text,
  new_value text,
  operation varchar NOT NULL,
  changed_at timestamp(6) NOT NULL DEFAULT now(),
  db_user varchar NOT NULL,
  actor_id bigint,
  actor_label varchar
);
CREATE INDEX index_privileged_attribute_changes_on_user_id ON privileged_attribute_changes (user_id);
CREATE INDEX index_privileged_attribute_changes_on_changed_at ON privileged_attribute_changes (changed_at);

CREATE FUNCTION log_privileged_attribute_changes() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE
  column_name text;
  old_text text;
  new_text text;
  actor_id_text text := nullif(current_setting('weave.actor_id', true), '');
  actor_label_text text := nullif(current_setting('weave.actor_label', true), '');
BEGIN
  FOREACH column_name IN ARRAY ARRAY['role'] LOOP
    new_text := to_jsonb(NEW) ->> column_name;
    IF TG_OP = 'INSERT' THEN
      old_text := NULL;
      CONTINUE WHEN new_text IS NULL OR new_text IN ('false', '0');
    ELSE
      old_text := to_jsonb(OLD) ->> column_name;
      CONTINUE WHEN old_text IS NOT DISTINCT FROM new_text;
    END IF;

    INSERT INTO public.privileged_attribute_changes
      (user_id, user_p_id, attribute_name, old_value, new_value, operation, changed_at, db_user, actor_id, actor_label)
    VALUES
      (NEW.id, NEW.p_id, column_name, old_text, new_text, lower(TG_OP), now(), CURRENT_USER,
       CASE WHEN actor_id_text ~ '^[0-9]+$' THEN actor_id_text::bigint END, actor_label_text);
  END LOOP;
  RETURN NULL;
END;
$$;

CREATE FUNCTION refuse_privileged_attribute_change_edits() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog AS $$
BEGIN
  RAISE EXCEPTION 'privileged_attribute_changes is append-only: % is not allowed', TG_OP;
END;
$$;

CREATE TRIGGER log_privileged_attribute_changes
AFTER INSERT OR UPDATE OF role ON users
FOR EACH ROW EXECUTE FUNCTION log_privileged_attribute_changes();

CREATE TRIGGER privileged_attribute_changes_append_only
BEFORE UPDATE OR DELETE ON privileged_attribute_changes
FOR EACH ROW EXECUTE FUNCTION refuse_privileged_attribute_change_edits();

CREATE TRIGGER privileged_attribute_changes_no_truncate
BEFORE TRUNCATE ON privileged_attribute_changes
FOR EACH STATEMENT EXECUTE FUNCTION refuse_privileged_attribute_change_edits();

