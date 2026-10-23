# The one switch for Krater production. Read by ./krater.nix (the units and
# nginx on weft), ../alastor/edge.nix (the public routes) and
# ../central-db-schema.nix (the `krater` role and schema on skein), so the
# three always change together.
#
# Before you set this to true, do the "Turn on production" checklist in
# ./krater.nix. With it true and the Weave client id still empty, the weft
# build fails on purpose.
{
  enable = false;
}
