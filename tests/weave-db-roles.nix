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

    # roles <audit_owner> <lock_superuser>: what the module's db_roles does.
    roles() {
      POSTGRES_PASSWORD=app-pw psql -X -q -v ON_ERROR_STOP=1 -U weave -d postgres \
        -v lock_superuser="$2" -f $roles
      for db in weave_production weave_production_queue; do
        psql -X -q -v ON_ERROR_STOP=1 -U weave -d $db -v audit_owner="$1" -f $database
      done
    }

    # A host from before the roles: the superuser owns everything.
    as weave postgres "ALTER ROLE weave PASSWORD 'old-pw'"
    as weave postgres "CREATE DATABASE weave_production"
    as weave postgres "CREATE DATABASE weave_production_queue"
    psql -X -q -v ON_ERROR_STOP=1 -U weave -d weave_production <<'SQL'
    CREATE TABLE schema_migrations (version text PRIMARY KEY);
    CREATE TABLE users (id bigserial PRIMARY KEY, p_id text NOT NULL, first_name text);
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

    # Step 2: the superuser loses its password, and stays without it.
    roles weave_audit true
    roles weave_audit true
    is t weave postgres "SELECT rolpassword IS NULL FROM pg_authid WHERE rolname = 'weave'"
    is t weave postgres "SELECT rolpassword IS NOT NULL FROM pg_authid WHERE rolname = 'weave_app'"

    touch $out
  ''
