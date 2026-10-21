# Redirects served from warp. Plain data, read by ./redirects-nginx.nix (nginx
# on warp) and by ../alastor/edge.nix (one alastor route per host to warp).
#
# Each host maps exact paths to target URLs. A path matches with or without a
# trailing slash and gets a temporary (302) redirect, so a target can move
# without browsers holding on to the old one. Any other path on the host,
# the bare domain included, gets a 404.
#
# To add a redirect: add a line here. For a new host, also add a proxied A
# record to alastor in patchworklabsorg/dns.
{
  "forms.patchworklabs.org" = {
    # Project Ganymede application (Tally).
    "/ganymede" = "https://tally.so/r/Np2DyQ";
  };
}
