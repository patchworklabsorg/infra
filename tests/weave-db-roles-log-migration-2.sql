-- tests/weave-db-roles-log-migration-2.sql
-- What Weave's migration 20261020130000_create_roles does to the database,
-- after migration 1. Copied the same way as weave-db-roles-log-migration-1.sql.

\set ON_ERROR_STOP on

-- 20261020130000_create_roles
CREATE TABLE roles (
  id bigserial PRIMARY KEY,
  key varchar NOT NULL UNIQUE,
  name varchar NOT NULL
);
CREATE TABLE user_roles (
  id bigserial PRIMARY KEY,
  user_id bigint REFERENCES users (id) ON DELETE SET NULL,
  role_id bigint NOT NULL REFERENCES roles (id),
  scope varchar,
  granted_by_id bigint REFERENCES users (id) ON DELETE SET NULL,
  granted_at timestamp(6) NOT NULL,
  reason text,
  identity_governance_proposal_id bigint,
  revoked_at timestamp(6),
  revoked_by_id bigint REFERENCES users (id) ON DELETE SET NULL,
  revoke_reason text,
  created_at timestamp(6) NOT NULL DEFAULT now()
);
ALTER TABLE privileged_attribute_changes ADD COLUMN role_key varchar;
ALTER TABLE privileged_attribute_changes ADD COLUMN role_scope varchar;
ALTER TABLE privileged_attribute_changes ADD COLUMN user_role_id bigint;

-- The users trigger moves to role only. The migration drops and makes it
-- again, so after a locked run it needs the flag (the trigger is pinned).
DROP TRIGGER log_privileged_attribute_changes ON users;
CREATE TRIGGER log_privileged_attribute_changes
AFTER INSERT OR UPDATE OF role ON users
FOR EACH ROW EXECUTE FUNCTION log_privileged_attribute_changes();

CREATE FUNCTION log_user_role_changes() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE
  actor_id_text text := nullif(current_setting('weave.actor_id', true), '');
  actor_label_text text := nullif(current_setting('weave.actor_label', true), '');
  role_key_text text;
  p_id_text text;
  operation_text text;
BEGIN
  IF TG_OP = 'INSERT' THEN
    operation_text := 'grant';
  ELSIF OLD.revoked_at IS NULL AND NEW.revoked_at IS NOT NULL THEN
    operation_text := 'revoke';
  ELSE
    RETURN NULL;
  END IF;

  SELECT key INTO role_key_text FROM public.roles WHERE id = NEW.role_id;
  SELECT p_id INTO p_id_text FROM public.users WHERE id = NEW.user_id;

  INSERT INTO public.privileged_attribute_changes
    (user_id, user_p_id, attribute_name, old_value, new_value, operation, changed_at, db_user, actor_id, actor_label,
     role_key, role_scope, user_role_id)
  VALUES
    (COALESCE(NEW.user_id, 0), p_id_text,
     'role:' || role_key_text || COALESCE('[' || NEW.scope || ']', ''),
     CASE WHEN operation_text = 'grant' THEN 'false' ELSE 'true' END,
     CASE WHEN operation_text = 'grant' THEN 'true' ELSE 'false' END,
     operation_text, now(), CURRENT_USER,
     CASE WHEN actor_id_text ~ '^[0-9]+$' THEN actor_id_text::bigint END, actor_label_text,
     role_key_text, NEW.scope, NEW.id);
  RETURN NULL;
END;
$$;

CREATE FUNCTION refuse_user_role_edits() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog AS $$
BEGIN
  IF TG_OP <> 'UPDATE' THEN
    RAISE EXCEPTION 'user_roles rows are permanent: % is not allowed. Revoke a role by setting revoked_at.', TG_OP;
  END IF;

  IF NEW.id IS DISTINCT FROM OLD.id
     OR NEW.role_id IS DISTINCT FROM OLD.role_id
     OR NEW.scope IS DISTINCT FROM OLD.scope
     OR NEW.granted_at IS DISTINCT FROM OLD.granted_at
     OR NEW.reason IS DISTINCT FROM OLD.reason
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'user_roles: only a revoke can change a row';
  END IF;

  IF (NEW.user_id IS DISTINCT FROM OLD.user_id AND NEW.user_id IS NOT NULL)
     OR (NEW.granted_by_id IS DISTINCT FROM OLD.granted_by_id AND NEW.granted_by_id IS NOT NULL)
     OR (NEW.identity_governance_proposal_id IS DISTINCT FROM OLD.identity_governance_proposal_id
         AND NEW.identity_governance_proposal_id IS NOT NULL) THEN
    RAISE EXCEPTION 'user_roles: only a revoke can change a row';
  END IF;

  IF OLD.revoked_at IS NOT NULL THEN
    IF NEW.revoked_at IS DISTINCT FROM OLD.revoked_at
       OR NEW.revoke_reason IS DISTINCT FROM OLD.revoke_reason
       OR (NEW.revoked_by_id IS DISTINCT FROM OLD.revoked_by_id AND NEW.revoked_by_id IS NOT NULL) THEN
      RAISE EXCEPTION 'user_roles: the role is already revoked';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER log_user_role_changes
AFTER INSERT OR UPDATE OF revoked_at ON user_roles
FOR EACH ROW EXECUTE FUNCTION log_user_role_changes();

CREATE TRIGGER user_roles_append_only
BEFORE UPDATE OR DELETE ON user_roles
FOR EACH ROW EXECUTE FUNCTION refuse_user_role_edits();

CREATE TRIGGER user_roles_no_truncate
BEFORE TRUNCATE ON user_roles
FOR EACH STATEMENT EXECUTE FUNCTION refuse_user_role_edits();
