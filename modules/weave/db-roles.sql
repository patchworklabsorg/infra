-- modules/weave/db-roles.sql
-- Database roles for one Weave instance. weave-web runs this file and then
-- db-roles-database.sql (in each app database) before and after
-- `bin/rails db:prepare`, as the bootstrap superuser `weave` over the local
-- socket in the db container (`docker exec ... psql -U weave`). Both files are
-- idempotent.
--
--   weave        bootstrap superuser. No password, so it can sign in only over
--                the local socket inside the db container, never over the
--                network. Only operators with a shell on the host can use it.
--   weave_app    the role the app signs in with. Not a superuser. It owns the
--                app's tables, so migrations work. It does not own the
--                databases or the public schema: an owner of those could drop
--                the audit tables.
--   weave_audit  owns the console audit tables (Console1984, Audits1984 and
--                console_access_requests). NOLOGIN. weave_app may read and add
--                rows there, and change only the columns the app must change,
--                so a console cannot delete or rewrite its own records. See
--                docs/CONSOLE_ACCESS.md in the Weave repo.
--
-- weave_app signs in with POSTGRES_PASSWORD from the instance env file, read
-- here from the db container's environment. Migrations that change an audit
-- table must run as `weave` by hand, because weave_app does not own them.

\set ON_ERROR_STOP on

SELECT NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'weave_app') AS create_app \gset
\if :create_app
  CREATE ROLE weave_app LOGIN;
\endif
ALTER ROLE weave_app WITH LOGIN NOSUPERUSER CREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
\set app_password `printf '%s' "$POSTGRES_PASSWORD"`
ALTER ROLE weave_app PASSWORD :'app_password';
\unset app_password

SELECT NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'weave_audit') AS create_audit \gset
\if :create_audit
  CREATE ROLE weave_audit NOLOGIN;
\endif

-- The app knows POSTGRES_PASSWORD, so the superuser must not accept it.
ALTER ROLE weave PASSWORD NULL;

-- The superuser owns the app's databases (db:prepare may create the queue
-- database as weave_app on a new host). weave_app may connect and create
-- objects. db-roles-database.sql then runs in each database.
DO $$
DECLARE db text;
BEGIN
  FOR db IN SELECT datname FROM pg_database WHERE datname IN ('weave_production', 'weave_production_queue') LOOP
    EXECUTE format('ALTER DATABASE %I OWNER TO weave', db);
    EXECUTE format('GRANT CONNECT, CREATE, TEMPORARY ON DATABASE %I TO weave_app', db);
  END LOOP;
END $$;
