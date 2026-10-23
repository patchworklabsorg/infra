# Apps and shared schemas of the two central databases. prod (skein, seam) and
# staging (hem) read this same file, so the environments cannot drift. The one
# exception is `stagingOnlyApps`: apps with no production instance yet.
#
# Add an app: add it here, add its password secret for each environment in
# secrets/secrets.nix, deploy the DB hosts. See modules/central-db for what
# each entry creates.
#
# The file is the schema for the switch in weft/krater-production.nix.
# `schemaFor` gives it for either value of that switch (tests/krater-weft.nix).
let
  # Krater (Project Ganymede portal): proposals, budget ledger, audit log. It stores no personal
  # data, only Patchwork IDs, and reads people through Weave's directory API, so no shared schemas.
  krater = { };

  # kraterProduction: Krater production's one switch. On, krater moves from
  # stagingOnlyApps to apps, so skein creates its role and schema.
  schemaFor = kraterProduction: {
    # patchwork_central — on skein (prod) and hem:5432 (staging).
    central = {
      apps = {
        # Weave is the IDP, so it owns people.* and runs its migrations.
        weave = { };
        selvage.read = [ "people" ];
      }
      // (if kraterProduction then { inherit krater; } else { });
      # Apps on staging (hem) only, until they have a production instance. skein
      # does not create their role or schema. Move an app to `apps` when it goes
      # to production.
      stagingOnlyApps = if kraterProduction then { } else { inherit krater; };
      sharedSchemas = {
        people.owner = "weave";
      };
    };

    # patchwork_central_restricted — on seam (prod) and hem:5433 (staging).
    # Its own cluster on its own VM in prod. No app has access until it is
    # listed here.
    restricted = {
      apps = {
        # Quilt (funding and records). Its own schema only, no shared schemas.
        quilt = { };
      };
      sharedSchemas = { };
    };
  };
in
schemaFor (import ./weft/krater-production.nix).enable // { inherit schemaFor; }
