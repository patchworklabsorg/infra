# modules/krater/default.nix
# Krater — the Project Ganymede portal (proposal review, compute budgets, gallery, and Krater Compute,
# which rents Vast.ai machines for members) — as Docker containers on a dedicated network. Exported by this
# flake as nixosModules.krater; weft imports it through hosts/weft/krater.nix, which sets the instance
# options (./instance.nix).
#
# Containers (network `krater`, state under /var/lib/krater):
#   krater-storage     SeaweedFS S3 gateway: gallery screenshots, and machines' checkpoints and outputs
#   krater-web         the portal, the runner API rented machines call; runs migrations first   127.0.0.1:<port>
#   krater-worker      procrastinate worker (the compute scheduler, Slack, pricing, events to Quilt)
# plus krater-build (builds the image).
#
# Database: Krater's schema `krater` in patchwork_central (modules/central-db, listed in
# hosts/central-db-schema.nix). The cluster's host dumps it nightly; this module runs no Postgres of its
# own. The role's search_path is `krater`, so Krater's tables, its job queue and alembic_version all live
# in that schema.
#
# Krater Compute is off by default (`compute.enable = false`, KRATER_COMPUTE_MODE=off): Krater launches
# nothing and needs no Vast key. On, the worker rents with the Vast key (`compute.vastKeyFile`), which only the
# worker ever sees; rented machines reach the portal at `compute.runnerUrl` (the public portal hostname) and
# the storage hostname. See Krater's docs/compute/.
#
# No registry: the image is built on this host from source. krater-build fetches one commit of
# `repo` (a full SHA, read from /var/lib/krater/source-rev, falling back to `rev`), builds it with the
# repo's own Dockerfile and tags it krater:<sha>. It skips the build when that tag already exists.
# A deploy is:
#   echo <sha> > /var/lib/krater/source-rev
#   sudo systemctl start krater-build     # old containers keep serving while this runs
#   sudo systemctl restart krater-web     # migrates, then starts; krater-worker follows (partOf)
# krater-web requires krater-build, so a restart alone also builds, but with the site down meanwhile.
#
# Secrets: one env file (`environmentFile`, an agenix secret), split per container at start into
# /run/krater/*.env so each container gets only its own keys. The file must contain:
#   KRATER_DATABASE_URL=postgresql+psycopg://krater:<password>@<central db host>:5432/patchwork_central?sslmode=disable
#                                             # <password> = the value in central-<env>-krater.age
#   KRATER_SECRET_KEY=...                     # >= 32 chars
#   KRATER_WEAVE_CLIENT_SECRET=...
#   KRATER_SLACK_BOT_TOKEN=...
#   KRATER_SLACK_SIGNING_SECRET=...
#   KRATER_S3_ACCESS_KEY_ID=...
#   KRATER_S3_SECRET_ACCESS_KEY=...
# Two more secrets are files of their own (agenix), each read into one container's env only:
#   compute.vastKeyFile      the Vast.ai API key, worker only (KRATER_VAST_API_KEY)
#   projectSecretsKeyFile    Fernet keys for project secrets, one per line, newest first; portal only
#                            (KRATER_PROJECT_SECRETS_KEY). Losing it loses every stored project secret.
# The image runs as a non-root user, so a root-only agenix file can't be mounted in; the env files are root-only
# (0600 in /run/krater, 0700), like the rest.
#
# Two instances, from ./instance.nix, so staging and production can run on one host:
#   patchwork.services.krater             staging: names krater-*, /var/lib/krater, ports 3010/3011
#   patchwork.services.krater-production  production: names krater-prod-*, /var/lib/krater-prod,
#                                         ports 3012/3013, image repository krater-prod
# The names below (krater-web, /var/lib/krater, ...) are the staging instance's. Production's are the
# same with krater-prod in place of krater.
{
  imports = [
    (import ./instance.nix {
      optName = "krater";
      prefix = "krater";
      defaultPort = 3010;
      defaultStoragePort = 3011;
    })
    (import ./instance.nix {
      optName = "krater-production";
      prefix = "krater-prod";
      defaultPort = 3012;
      defaultStoragePort = 3013;
    })
  ];
}
