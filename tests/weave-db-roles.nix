# Checks modules/weave/db-roles.sql and db-roles-database.sql on a real
# PostgreSQL 17 (the major version of the pgvector image). No VM: the server
# runs in the build sandbox on a Unix socket, so the check also runs on
# aarch64-darwin.
#   nix build .#checks.<system>.weave-db-roles
#
# It loads a small schema with the shape of Weave's (an app table, users, the
# Console1984 and Audits1984 tables and console_access_requests), runs the
# roles twice, and checks what weave_app can and cannot do. Then it checks the
# flagged migration path and the superuser lock.
{ pkgs }:
pkgs.runCommand "weave-db-roles"
  {
    nativeBuildInputs = [ pkgs.postgresql_17 ];
    roles = ../modules/weave/db-roles.sql;
    database = ../modules/weave/db-roles-database.sql;
    logMigration1 = ./weave-db-roles-log-migration-1.sql;
    logMigration2 = ./weave-db-roles-log-migration-2.sql;
  }
  ''
    set -euo pipefail
    export PGHOST=$TMPDIR/sock PGDATA=$TMPDIR/data
    mkdir -p $PGHOST
    initdb -U weave -A trust --no-locale -E UTF8 >/dev/null
    pg_ctl -o "-c listen_addresses= -k $PGHOST" -l $TMPDIR/pg.log -w start >/dev/null
    trap 'pg_ctl -m fast -w stop >/dev/null' EXIT

    as() { local role=$1 db=$2; shift 2; psql -X -q -At -v ON_ERROR_STOP=1 -U "$role" -d "$db" -c "$*"; }
    ok() { as "$@" >/dev/null || { echo "FAILED, should work: $*" >&2; exit 1; }; }
    no() {
      if as "$@" >/dev/null 2>&1; then
        echo "WORKED, should fail: $*" >&2
        exit 1
      fi
    }
    is() { local want=$1; shift; local got; got=$(as "$@"); [ "$got" = "$want" ] || { echo "got '$got', want '$want': $*" >&2; exit 1; }; }
    # Fails, and the error names the event trigger of the permanent log.
    pinned() {
      local out
      if out=$(as "$@" 2>&1); then
        echo "WORKED, should fail: $*" >&2
        exit 1
      fi
      case $out in
        *"capture triggers of privileged_attribute_changes cannot change"*) ;;
        *) echo "failed for another reason: $*: $out" >&2; exit 1 ;;
      esac
    }

    # roles <audit_owner> <lock_superuser>: what the module's db_roles does.
    roles() {
      POSTGRES_PASSWORD=app-pw psql -X -q -v ON_ERROR_STOP=1 -U weave -d postgres \
        -v lock_superuser="$2" -f $roles || return 1
      # The return keeps a failure visible also where set -e is off (in an if).
      for db in weave_production weave_production_queue; do
        psql -X -q -v ON_ERROR_STOP=1 -U weave -d $db -v audit_owner="$1" -f $database || return 1
      done
    }

    # A host from before the roles: the superuser owns everything.
    as weave postgres "ALTER ROLE weave PASSWORD 'old-pw'"
    as weave postgres "CREATE DATABASE weave_production"
    as weave postgres "CREATE DATABASE weave_production_queue"
    psql -X -q -v ON_ERROR_STOP=1 -U weave -d weave_production <<'SQL'
    CREATE TABLE schema_migrations (version text PRIMARY KEY);
    CREATE TABLE users (id bigserial PRIMARY KEY, p_id text NOT NULL, first_name text, role integer NOT NULL DEFAULT 0);
    CREATE TABLE things (id bigserial PRIMARY KEY, name text);
    CREATE TABLE console1984_users (id bigserial PRIMARY KEY, username text NOT NULL,
      created_at timestamp NOT NULL DEFAULT now(), updated_at timestamp NOT NULL DEFAULT now());
    CREATE TABLE console1984_sessions (id bigserial PRIMARY KEY, user_id bigint NOT NULL, reason text,
      created_at timestamp NOT NULL DEFAULT now(), updated_at timestamp NOT NULL DEFAULT now());
    CREATE TABLE console1984_sensitive_accesses (id bigserial PRIMARY KEY, session_id bigint, justification text,
      created_at timestamp NOT NULL DEFAULT now(), updated_at timestamp NOT NULL DEFAULT now());
    CREATE TABLE console1984_commands (id bigserial PRIMARY KEY, session_id bigint, sensitive_access_id bigint,
      statements text, created_at timestamp NOT NULL DEFAULT now(), updated_at timestamp NOT NULL DEFAULT now());
    CREATE TABLE audits1984_audits (id bigserial PRIMARY KEY, auditor_id bigint NOT NULL, session_id bigint NOT NULL,
      status integer NOT NULL DEFAULT 0, notes text,
      created_at timestamp NOT NULL DEFAULT now(), updated_at timestamp NOT NULL DEFAULT now());
    CREATE TABLE console_access_requests (id bigserial PRIMARY KEY, status text NOT NULL DEFAULT 'pending',
      user_id bigint, confirmed_at timestamp, confirmed_ip text, claimed_at timestamp,
      created_at timestamp NOT NULL DEFAULT now(), updated_at timestamp NOT NULL DEFAULT now());
    INSERT INTO users (p_id, first_name) VALUES ('PWL1', 'Ada'), ('PWL2', 'Grace');
    INSERT INTO console1984_users (username) VALUES ('Ada Lovelace (PWL1)');
    INSERT INTO console1984_sessions (user_id, reason) VALUES (1, 'test');
    INSERT INTO console1984_commands (session_id, statements) VALUES (1, 'User.count');
    SQL
    P=weave_production

    # Step 1: twice, as each start does before and after db:prepare.
    roles weave_audit false
    roles weave_audit false
    is t weave postgres "SELECT rolpassword IS NOT NULL FROM pg_authid WHERE rolname = 'weave'"
    is f weave postgres "SELECT rolsuper FROM pg_roles WHERE rolname = 'weave_app'"

    # Ownership.
    is weave_app weave $P "SELECT tableowner FROM pg_tables WHERE tablename = 'things'"
    is weave_app weave $P "SELECT tableowner FROM pg_tables WHERE tablename = 'schema_migrations'"
    for t in console1984_users console1984_sessions console1984_commands console1984_sensitive_accesses \
             audits1984_audits audits1984_audit_versions console_access_requests; do
      is weave_audit weave $P "SELECT tableowner FROM pg_tables WHERE tablename = '$t'"
    done

    # App tables: migrations work.
    ok weave_app $P "ALTER TABLE things ADD COLUMN size int"
    ok weave_app $P "CREATE TABLE more_things (id bigserial PRIMARY KEY)"
    ok weave_app $P "INSERT INTO things (name) VALUES ('a')"
    ok weave_app $P "DELETE FROM things"
    ok weave_app $P "INSERT INTO schema_migrations VALUES ('1')"

    # Audit tables: read, add, change only the listed columns.
    ok weave_app $P "SELECT count(*) FROM console1984_commands"
    ok weave_app $P "INSERT INTO console1984_commands (session_id, statements) VALUES (1, 'x')"
    ok weave_app $P "UPDATE console1984_sessions SET updated_at = now()"
    no weave_app $P "UPDATE console1984_commands SET statements = 'hidden'"
    no weave_app $P "UPDATE console1984_users SET username = 'someone else'"
    no weave_app $P "DELETE FROM console1984_commands"
    no weave_app $P "TRUNCATE console1984_commands"
    no weave_app $P "DROP TABLE console1984_commands"
    no weave_app $P "ALTER TABLE console1984_commands ADD COLUMN x int"
    no weave_app $P "ALTER TABLE console1984_commands DISABLE TRIGGER ALL"
    no weave_app $P "CREATE TABLE fk_test (id int REFERENCES console1984_sessions (id))"
    no weave_app $P "CREATE SCHEMA shadow"
    no weave_app $P "CREATE TEMP TABLE console1984_commands (id int)"
    no weave_app $P "CREATE EXTENSION hstore"

    # Nobody audits their own session: Ada (PWL1) ran session 1.
    no weave_app $P "INSERT INTO audits1984_audits (auditor_id, session_id, status) VALUES (1, 1, 1)"
    ok weave_app $P "INSERT INTO audits1984_audits (auditor_id, session_id, status) VALUES (2, 1, 0)"
    is "1|insert|0" weave $P "SELECT count(*), max(operation), max(status) FROM audits1984_audit_versions"
    ok weave_app $P "UPDATE audits1984_audits SET status = 1, notes = 'fine'"
    is "2|0" weave $P "SELECT count(*), max(status) FILTER (WHERE operation = 'update') FROM audits1984_audit_versions"
    no weave_app $P "UPDATE audits1984_audits SET auditor_id = 1"
    no weave_app $P "UPDATE audits1984_audits SET session_id = 2"
    no weave_app $P "INSERT INTO audits1984_audit_versions (audit_id) VALUES (1)"
    no weave_app $P "DELETE FROM audits1984_audit_versions"

    # A new app table moves to weave_app, and a new audit table to weave_audit.
    as weave $P "CREATE TABLE made_by_superuser (id int)"
    roles weave_audit false
    is weave_app weave $P "SELECT tableowner FROM pg_tables WHERE tablename = 'made_by_superuser'"
    is weave_app weave $P "SELECT tableowner FROM pg_tables WHERE tablename = 'more_things'"

    # The flagged migration: weave_app owns the audit tables for one run and
    # can change rows and add columns and foreign keys. The version table
    # stays with weave_audit.
    roles weave_app false
    is weave_app weave $P "SELECT tableowner FROM pg_tables WHERE tablename = 'console1984_commands'"
    is weave_audit weave $P "SELECT tableowner FROM pg_tables WHERE tablename = 'audits1984_audit_versions'"
    ok weave_app $P "ALTER TABLE console1984_sessions ADD COLUMN source text"
    ok weave_app $P "UPDATE console1984_sessions SET source = 'console'"
    ok weave_app $P "UPDATE audits1984_audits SET notes = 'migrated'"
    ok weave_app $P "CREATE TABLE fk_test (id int REFERENCES console1984_sessions (id))"
    no weave_app $P "DELETE FROM audits1984_audit_versions"
    is 3 weave $P "SELECT count(*) FROM audits1984_audit_versions"

    # The next run takes them back.
    roles weave_audit false
    is weave_audit weave $P "SELECT tableowner FROM pg_tables WHERE tablename = 'console1984_sessions'"
    no weave_app $P "DELETE FROM console1984_commands"
    no weave_app $P "UPDATE console1984_sessions SET source = 'changed'"

    # The permanent log. Weave's migrations make it as weave_app in
    # db:prepare, each in one transaction. The event trigger is on, but
    # nothing is pinned yet, so migration 1 works.
    migrate() { psql -X -q -1 -v ON_ERROR_STOP=1 -U weave_app -d $P -f "$1"; }
    is 0 weave $P "SELECT count(*) FROM weave_audit_pinned_capture_triggers"
    migrate $logMigration1
    is weave_app weave $P "SELECT tableowner FROM pg_tables WHERE tablename = 'privileged_attribute_changes'"
    # A locked run between the two migrations takes the log and pins the
    # users trigger. Migration 2 then fails without the flag and changes
    # nothing (it changes the log and drops the users trigger).
    roles weave_audit false
    is 1 weave $P "SELECT count(*) FROM weave_audit_pinned_capture_triggers"
    if migrate $logMigration2 >/dev/null 2>&1; then
      echo "WORKED, should fail: migration 2 after a locked run, without the flag" >&2
      exit 1
    fi
    is "" weave $P "SELECT to_regclass('user_roles')"
    # With the flag it works, and the run after it pins the new triggers.
    roles weave_app false
    migrate $logMigration2
    roles weave_audit false
    roles weave_audit false
    is weave_audit weave $P "SELECT tableowner FROM pg_tables WHERE tablename = 'privileged_attribute_changes'"
    is weave_audit weave $P "SELECT relowner::regrole FROM pg_class WHERE relname = 'privileged_attribute_changes_id_seq'"
    for f in log_privileged_attribute_changes refuse_privileged_attribute_change_edits \
             log_user_role_changes refuse_user_role_edits; do
      is "weave_audit|f" weave $P "SELECT proowner::regrole, prosecdef FROM pg_proc WHERE proname = '$f'"
    done
    is weave_app weave $P "SELECT tableowner FROM pg_tables WHERE tablename = 'user_roles'"
    is 4 weave $P "SELECT count(*) FROM weave_audit_pinned_capture_triggers"
    is "" weave $P "SELECT weave_audit_capture_trigger_drift()"
    is O weave $P "SELECT evtenabled FROM pg_event_trigger WHERE evtname = 'weave_audit_keep_capture_triggers'"

    # The capture triggers still write, as weave_app.
    ok weave_app $P "INSERT INTO roles (key, name) VALUES ('board', 'Board')"
    ok weave_app $P "UPDATE users SET role = 2 WHERE id = 1"
    ok weave_app $P "INSERT INTO user_roles (user_id, role_id, scope, granted_at) VALUES (2, 1, 'x', now())"
    ok weave_app $P "UPDATE user_roles SET revoked_at = now(), revoke_reason = 'done'"
    is "role|update|0|2|weave_app" weave $P \
      "SELECT attribute_name, operation, old_value, new_value, db_user FROM privileged_attribute_changes WHERE user_id = 1"
    is "grant,revoke|weave_app|board" weave $P \
      "SELECT string_agg(operation, ',' ORDER BY id), max(db_user), max(role_key) FROM privileged_attribute_changes WHERE user_id = 2"
    ok weave_app $P "SELECT count(*) FROM privileged_attribute_changes"
    is 3 weave $P "SELECT count(*) FROM privileged_attribute_changes"

    # A shadow function in public does not stop the capture: the capture
    # functions run with search_path = pg_catalog.
    ok weave_app $P "CREATE FUNCTION public.to_jsonb(users) RETURNS jsonb LANGUAGE sql AS \$\$ SELECT '{}'::jsonb \$\$"
    ok weave_app $P "UPDATE users SET role = 3 WHERE id = 1"
    is 4 weave $P "SELECT count(*) FROM privileged_attribute_changes WHERE user_id = 1 OR user_id = 2"
    ok weave_app $P "DROP FUNCTION public.to_jsonb(users)"

    # weave_app cannot change or remove log rows.
    no weave_app $P "UPDATE privileged_attribute_changes SET new_value = '0'"
    no weave_app $P "DELETE FROM privileged_attribute_changes"
    no weave_app $P "TRUNCATE privileged_attribute_changes"
    no weave_app $P "DROP TABLE privileged_attribute_changes"
    no weave_app $P "ALTER TABLE privileged_attribute_changes ADD COLUMN x int"
    no weave_app $P "ALTER TABLE privileged_attribute_changes OWNER TO weave_app"
    # Nor turn off or drop its append-only triggers.
    no weave_app $P "ALTER TABLE privileged_attribute_changes DISABLE TRIGGER privileged_attribute_changes_append_only"
    no weave_app $P "ALTER TABLE privileged_attribute_changes DISABLE TRIGGER USER"
    no weave_app $P "DROP TRIGGER privileged_attribute_changes_append_only ON privileged_attribute_changes"
    no weave_app $P "DROP TRIGGER privileged_attribute_changes_no_truncate ON privileged_attribute_changes"
    # Nor replace, drop or take its functions.
    for f in log_privileged_attribute_changes refuse_privileged_attribute_change_edits \
             log_user_role_changes refuse_user_role_edits; do
      no weave_app $P "CREATE OR REPLACE FUNCTION $f() RETURNS trigger LANGUAGE plpgsql AS \$\$ BEGIN RETURN NULL; END \$\$"
      no weave_app $P "DROP FUNCTION $f() CASCADE"
      no weave_app $P "ALTER FUNCTION $f() OWNER TO weave_app"
    done
    no weave_app $P "DELETE FROM weave_audit_pinned_capture_triggers"
    no weave_app $P "ALTER EVENT TRIGGER weave_audit_keep_capture_triggers DISABLE"
    no weave_app $P "CREATE OR REPLACE FUNCTION weave_audit_capture_triggers() RETURNS TABLE (table_name text, trigger_name text, definition text) LANGUAGE sql AS \$\$ SELECT NULL::text, NULL::text, NULL::text WHERE false \$\$"

    # weave_app owns users and user_roles, but the event trigger keeps their
    # capture triggers and the user_roles guards.
    pinned weave_app $P "ALTER TABLE users DISABLE TRIGGER log_privileged_attribute_changes"
    pinned weave_app $P "ALTER TABLE users DISABLE TRIGGER USER"
    pinned weave_app $P "ALTER TABLE users ENABLE REPLICA TRIGGER log_privileged_attribute_changes"
    pinned weave_app $P "DROP TRIGGER log_privileged_attribute_changes ON users"
    pinned weave_app $P "CREATE OR REPLACE TRIGGER log_privileged_attribute_changes AFTER INSERT ON users FOR EACH ROW EXECUTE FUNCTION log_privileged_attribute_changes()"
    pinned weave_app $P "ALTER TRIGGER log_privileged_attribute_changes ON users RENAME TO old_log"
    pinned weave_app $P "ALTER TABLE users RENAME TO old_users"
    pinned weave_app $P "ALTER TABLE users DROP COLUMN role CASCADE"
    pinned weave_app $P "DROP TABLE user_roles"
    pinned weave_app $P "DROP TRIGGER log_user_role_changes ON user_roles"
    pinned weave_app $P "DROP TRIGGER user_roles_append_only ON user_roles"
    pinned weave_app $P "ALTER TABLE user_roles DISABLE TRIGGER user_roles_no_truncate"
    # Also for the superuser, until a flagged run.
    pinned weave $P "DROP TRIGGER log_privileged_attribute_changes ON users"
    no weave_app $P "DELETE FROM user_roles"
    no weave_app $P "TRUNCATE user_roles"
    # Other DDL on these tables still works.
    ok weave_app $P "ALTER TABLE users ADD COLUMN nickname text"
    ok weave_app $P "CREATE INDEX users_nickname ON users (nickname)"
    ok weave_app $P "ALTER TABLE users ADD CONSTRAINT users_nickname_short CHECK (length(nickname) < 50)"
    ok weave_app $P "ALTER TABLE user_roles ADD COLUMN note text"
    ok weave_app $P "CREATE INDEX user_roles_note ON user_roles (note)"
    ok weave_app $P "ALTER TABLE user_roles ADD CONSTRAINT user_roles_granted_by_fk2 FOREIGN KEY (granted_by_id) REFERENCES users (id)"
    ok weave_app $P "CREATE TABLE user_notes (id bigserial PRIMARY KEY, user_id bigint REFERENCES users (id))"
    ok weave_app $P "DROP TABLE user_notes"
    # A new trigger on users or user_roles is refused too, with any name.
    pinned weave_app $P "CREATE TRIGGER other_trigger AFTER UPDATE ON users FOR EACH ROW EXECUTE FUNCTION log_privileged_attribute_changes()"
    # A BEFORE trigger that sets role from another column: AFTER UPDATE OF
    # role does not fire for it, so it would change role with no log row.
    ok weave_app $P "CREATE FUNCTION public.sneak() RETURNS trigger LANGUAGE plpgsql AS \$\$ BEGIN NEW.role := NEW.nickname::int; RETURN NEW; END \$\$"
    pinned weave_app $P "CREATE TRIGGER a_sneak BEFORE UPDATE ON users FOR EACH ROW EXECUTE FUNCTION public.sneak()"
    pinned weave_app $P "CREATE CONSTRAINT TRIGGER a_sneak AFTER UPDATE ON users FOR EACH ROW EXECUTE FUNCTION public.sneak()"
    ok weave_app $P "UPDATE users SET nickname = '9' WHERE id = 1"
    is 3 weave $P "SELECT role FROM users WHERE id = 1"
    # A BEFORE trigger after user_roles_append_only (name order) that turns
    # a revoked row back into an active grant.
    ok weave_app $P "CREATE FUNCTION public.unrevoke() RETURNS trigger LANGUAGE plpgsql AS \$\$ BEGIN NEW.revoked_at := NULL; NEW.revoke_reason := NULL; RETURN NEW; END \$\$"
    pinned weave_app $P "CREATE TRIGGER zzz BEFORE UPDATE ON user_roles FOR EACH ROW EXECUTE FUNCTION public.unrevoke()"
    ok weave_app $P "UPDATE user_roles SET revoked_by_id = NULL"
    is 1 weave $P "SELECT count(*) FROM user_roles WHERE revoked_at IS NOT NULL"
    is "" weave $P "SELECT weave_audit_capture_trigger_drift()"
    is 4 weave $P "SELECT count(*) FROM privileged_attribute_changes"

    # A flagged migration may change the log, its functions and its triggers.
    # The append-only triggers still refuse a DELETE, also for the owner.
    roles weave_app false
    is D weave $P "SELECT evtenabled FROM pg_event_trigger WHERE evtname = 'weave_audit_keep_capture_triggers'"
    is weave_app weave $P "SELECT tableowner FROM pg_tables WHERE tablename = 'privileged_attribute_changes'"
    is weave_app weave $P "SELECT proowner::regrole FROM pg_proc WHERE proname = 'log_privileged_attribute_changes'"
    ok weave_app $P "ALTER TABLE privileged_attribute_changes ADD COLUMN request_id text"
    ok weave_app $P "DROP TRIGGER log_privileged_attribute_changes ON users"
    ok weave_app $P "CREATE TRIGGER log_privileged_attribute_changes AFTER INSERT OR UPDATE OF role, first_name ON users FOR EACH ROW EXECUTE FUNCTION log_privileged_attribute_changes()"
    ok weave_app $P "CREATE TRIGGER added_by_migration AFTER INSERT ON user_roles FOR EACH ROW EXECUTE FUNCTION log_user_role_changes()"
    no weave_app $P "DELETE FROM privileged_attribute_changes"
    # The next run takes it back and pins the new users trigger.
    roles weave_audit false
    is O weave $P "SELECT evtenabled FROM pg_event_trigger WHERE evtname = 'weave_audit_keep_capture_triggers'"
    is weave_audit weave $P "SELECT tableowner FROM pg_tables WHERE tablename = 'privileged_attribute_changes'"
    is weave_audit weave $P "SELECT proowner::regrole FROM pg_proc WHERE proname = 'log_privileged_attribute_changes'"
    is 1 weave $P "SELECT count(*) FROM weave_audit_pinned_capture_triggers WHERE definition LIKE '%UPDATE OF role, first_name%'"
    is 5 weave $P "SELECT count(*) FROM weave_audit_pinned_capture_triggers"
    pinned weave_app $P "DROP TRIGGER added_by_migration ON user_roles"
    pinned weave_app $P "DROP TRIGGER log_privileged_attribute_changes ON users"
    no weave_app $P "DELETE FROM privileged_attribute_changes"
    ok weave_app $P "UPDATE users SET role = 0 WHERE id = 1"
    is 5 weave $P "SELECT count(*) FROM privileged_attribute_changes"
    # A superuser can turn event triggers off for a session. The next locked
    # run then stops at once and names the drifted trigger.
    as weave $P "SET event_triggers = off; DROP TRIGGER added_by_migration ON user_roles"
    if drift_out=$(roles weave_audit false 2>&1); then
      echo "WORKED, should fail: a locked run after drift" >&2
      exit 1
    fi
    case $drift_out in
      *"differ from the pinned ones: user_roles.added_by_migration"*) ;;
      *) echo "drift not named: $drift_out" >&2; exit 1 ;;
    esac
    # A flagged run accepts the triggers as they are.
    roles weave_app false
    roles weave_audit false
    is 4 weave $P "SELECT count(*) FROM weave_audit_pinned_capture_triggers"
    # The queue database has no permanent log and no event trigger.
    is 0 weave weave_production_queue "SELECT count(*) FROM pg_event_trigger"

    # Step 2: the superuser loses its password, and stays without it.
    roles weave_audit true
    roles weave_audit true
    is t weave postgres "SELECT rolpassword IS NULL FROM pg_authid WHERE rolname = 'weave'"
    is t weave postgres "SELECT rolpassword IS NOT NULL FROM pg_authid WHERE rolname = 'weave_app'"

    touch $out
  ''
