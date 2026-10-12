# NixOS VM test for modules/central-db: the access model in the module header.
#   nix build .#checks.<system>.central-db
{ pkgs, ... }:
pkgs.testers.runNixOSTest {
  name = "central-db";

  nodes.db =
    { pkgs, ... }:
    {
      imports = [ ../modules/central-db ];
      patchwork.centralDb = {
        enable = true;
        database = "patchwork_central";
        apps = {
          weave = { };
          selvage.read = [ "people" ];
          writer.write = [ "people" ];
        };
        sharedSchemas.people.owner = "weave";
        passwordDir = "/etc/central-db-pw";
        allowedCIDRs = [ "127.0.0.1/32" ];
        firewallInterfaces = [ ];
        backup.enable = false;
      };
      environment.etc = {
        "central-db-pw/weave".text = "weave-pw";
        "central-db-pw/selvage".text = "selvage-pw";
        "central-db-pw/writer".text = "writer-pw";
      };
      environment.systemPackages = [ pkgs.postgresql_18 ];
    };

  testScript = ''
    def sql(user, pw, query):
        return f"PGPASSWORD={pw} psql -h 127.0.0.1 -U {user} -d patchwork_central -v ON_ERROR_STOP=1 -tAc \"{query}\""

    db.wait_for_unit("central-db-setup.service")

    # Apps log in with their passwords and land in their own schema.
    assert db.succeed(sql("selvage", "selvage-pw", "SHOW search_path")).strip() == "selvage"
    db.fail(sql("selvage", "wrong", "SELECT 1"))

    # Each app owns its schema and can create tables there.
    db.succeed(sql("selvage", "selvage-pw", "CREATE TABLE selvage.t (id int)"))

    # Nobody can create in public, or in another app's schema.
    db.fail(sql("selvage", "selvage-pw", "CREATE TABLE public.t (id int)"))
    db.fail(sql("selvage", "selvage-pw", "CREATE TABLE weave.t (id int)"))
    db.fail(sql("selvage", "selvage-pw", "SELECT * FROM selvage.t JOIN weave.nothing ON true"))

    # The owner of a shared schema creates tables; default privileges apply.
    db.succeed(sql("weave", "weave-pw", "CREATE TABLE people.person (id serial primary key, name text)"))
    db.succeed(sql("weave", "weave-pw", "INSERT INTO people.person (name) VALUES ('a')"))

    # A reader reads and cannot write.
    assert db.succeed(sql("selvage", "selvage-pw", "SELECT count(*) FROM people.person")).strip() == "1"
    db.fail(sql("selvage", "selvage-pw", "INSERT INTO people.person (name) VALUES ('b')"))

    # A writer writes rows, including through the sequence, but cannot change the schema.
    db.succeed(sql("writer", "writer-pw", "INSERT INTO people.person (name) VALUES ('c')"))
    db.fail(sql("writer", "writer-pw", "ALTER TABLE people.person ADD COLUMN x int"))
    db.fail(sql("writer", "writer-pw", "SELECT * FROM selvage.t"))

    # The setup is idempotent.
    db.succeed("systemctl restart central-db-setup.service")
    assert db.succeed(sql("selvage", "selvage-pw", "SELECT count(*) FROM people.person")).strip() == "2"
  '';
}
