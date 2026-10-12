# Checks ad/org.json, and runs ad/converge.ps1 against the in-memory directory
# in tests/ad. `hosts` is the list of nixosConfigurations: every NixOS host
# must be in org.json's linuxHosts, so it gets its lnx-<host>-* groups.
{ pkgs, hosts }:
let
  inherit (pkgs) lib;
  org = builtins.fromJSON (builtins.readFile ../ad/org.json);

  ouPaths = map (o: o.path) org.ous;
  sams = map (u: u.sam) org.users;
  roleNames = map (g: g.name) org.roleGroups;
  people = builtins.filter (u: u.kind == "person") org.users;
  disabled = map (u: u.sam) (builtins.filter (u: u.kind == "disabled") org.users);
  dupes = l: lib.unique (builtins.filter (x: lib.count (y: y == x) l > 1) l);

  errors =
    lib.optional (dupes sams != [ ]) "duplicate users: ${toString (dupes sams)}"
    ++ lib.optional (dupes roleNames != [ ]) "duplicate groups: ${toString (dupes roleNames)}"
    ++ lib.concatMap (
      u:
      lib.optional (!lib.elem u.ou ouPaths) "${u.sam}: OU ${u.ou} is not in ous"
      ++ lib.optional (
        u ? manager && u.manager != null && !lib.elem u.manager sams
      ) "${u.sam}: manager ${u.manager} is not a user"
    ) org.users
    ++ lib.concatMap (
      u:
      lib.optional (!(org.divisions ? ${u.division})) "${u.sam}: unknown division ${u.division}"
      ++ lib.optional (
        org.divisions ? ${u.division} && !lib.elem u.department org.divisions.${u.division}
      ) "${u.sam}: ${u.department} is not a department of ${u.division}"
    ) people
    ++ lib.concatMap (
      g:
      map (m: "${g.name}: member ${m} is not a user") (builtins.filter (m: !lib.elem m sams) g.members)
      ++ map (m: "${g.name}: ${m} is disabled and must not be in a group") (
        builtins.filter (m: lib.elem m disabled) g.members
      )
    ) org.roleGroups
    ++ lib.concatMap (
      g:
      map (m: "${g.name}: member ${m} is not a role group") (
        builtins.filter (m: !lib.elem m roleNames) g.members
      )
    ) (org.hostGroups ++ org.resourceGroups)
    ++ map (h: "${h} is in both linuxHosts and retiredHosts") (
      builtins.filter (h: lib.elem h org.linuxHosts) org.retiredHosts
    )
    ++ lib.optional (
      lib.sort lib.lessThan org.linuxHosts != lib.sort lib.lessThan hosts
    ) "linuxHosts (${toString org.linuxHosts}) must match nixosConfigurations (${toString hosts})";
in
if errors != [ ] then
  throw ("ad/org.json:\n  " + lib.concatStringsSep "\n  " errors)
else
  pkgs.runCommand "ad-org"
    {
      nativeBuildInputs = [ pkgs.powershell ];
      src = lib.fileset.toSource {
        root = ../.;
        fileset = lib.fileset.unions [
          ../ad
          ./ad
        ];
      };
    }
    ''
      export HOME=$TMPDIR
      cp -r $src src && chmod -R u+w src
      pwsh -NoProfile -NonInteractive -File src/tests/ad/run.ps1
      touch $out
    ''
