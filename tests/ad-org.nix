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

  # The UPN that converge.ps1 manages for each user. "upn" is the part
  # before the @ and defaults to "sam". Admin accounts keep the domain.
  creates = u: !(u ? create) || u.create;
  # The suffix: the user's own, else the nearest OU on its path that sets
  # one, else org.upnSuffix. Same rule as Get-UpnSuffixFor in converge.ps1.
  ouSuffix =
    path:
    let
      parts = lib.splitString "/" path;
      prefixes = lib.reverseList (
        lib.genList (i: lib.concatStringsSep "/" (lib.take (i + 1) parts)) (builtins.length parts)
      );
      found = builtins.filter (p: p != null) (
        map (
          p:
          let
            o = lib.findFirst (x: x.path == p && x ? upnSuffix) null org.ous;
          in
          if o == null then null else o.upnSuffix
        ) prefixes
      );
    in
    if found == [ ] then org.upnSuffix else builtins.head found;
  suffixOf = u: u.upnSuffix or (ouSuffix u.ou);
  upnOf =
    u:
    let
      local = u.upn or u.sam;
    in
    if u.kind == "person" || (u.kind == "service" && u ? upn) then
      "${local}@${suffixOf u}"
    else if u.kind == "admin" && creates u then
      "${local}@${org.domain}"
    else
      null;
  upns = builtins.filter (x: x != null) (map upnOf org.users);

  # Password policies. Every account that is not disabled must get a PSO
  # through a role group, so no account falls to the default by mistake.
  psos = org.passwordPolicy.psos;
  psoGroups = lib.concatMap (p: p.appliesTo) psos;
  memberOf = sam: map (g: g.name) (builtins.filter (g: lib.elem sam g.members) org.roleGroups);
  checkPolicy =
    name: p:
    lib.optional (
      p ? lockoutDurationMinutes
      && p ? lockoutObservationWindowMinutes
      && p.lockoutDurationMinutes != 0
      && p.lockoutObservationWindowMinutes > p.lockoutDurationMinutes
    ) "${name}: lockoutObservationWindowMinutes is longer than lockoutDurationMinutes";

  # Names that resolve to well-known security principals. AD refuses them as
  # sAMAccountNames ("The specified account already exists").
  reservedSams = [
    "service"
    "system"
    "network"
    "interactive"
    "batch"
    "anonymous"
    "everyone"
    "administrator"
    "administrators"
    "users"
    "guests"
    "guest"
    "krbtgt"
  ];

  errors =
    lib.optional (dupes sams != [ ]) "duplicate users: ${toString (dupes sams)}"
    ++ map (s: "${s}: the sAMAccountName is a reserved Windows name") (
      builtins.filter (s: lib.elem (lib.toLower s) reservedSams) sams
    )
    ++ lib.optional (dupes roleNames != [ ]) "duplicate groups: ${toString (dupes roleNames)}"
    ++ lib.optional (dupes upns != [ ]) "duplicate UPNs: ${toString (dupes upns)}"
    ++ map (u: "${u.sam}: upn is the part before the @, without the @") (
      builtins.filter (u: u ? upn && lib.hasInfix "@" u.upn) org.users
    )
    ++ map (u: "${u.sam}: upn ${u.upn} is the sam of another user") (
      builtins.filter (u: u ? upn && u.upn != u.sam && lib.elem u.upn sams) org.users
    )
    ++ lib.optional (dupes (map (p: p.name) psos) != [ ]) "duplicate PSOs"
    ++ lib.optional (dupes (map (p: p.precedence) psos) != [ ]) "two PSOs have the same precedence"
    ++ checkPolicy "passwordPolicy.default" org.passwordPolicy.default
    ++ lib.concatMap (p: checkPolicy p.name p) psos
    ++ map (g: "a PSO applies to ${g}, which is not a role group") (
      builtins.filter (g: !lib.elem g roleNames) psoGroups
    )
    ++ map (u: "${u.sam}: no PSO applies. Add it to a group in passwordPolicy.psos.*.appliesTo") (
      builtins.filter (
        u: u.kind != "disabled" && !lib.any (g: lib.elem g psoGroups) (memberOf u.sam)
      ) org.users
    )
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
