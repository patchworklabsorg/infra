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

  # Tiering: the silo, its policies and JIT.
  tiering = org.tiering or null;
  adminSams = map (u: u.sam) (builtins.filter (u: u.kind == "admin") org.users);
  tieringErrors =
    if tiering == null then
      [ ]
    else
      let
        jit = tiering.jit;
        policies = builtins.filter (p: p != null) [
          tiering.userPolicy
          tiering.computerPolicy
          (tiering.servicePolicy or null)
        ];
        policyNames = map (p: p.name) policies;
      in
      lib.optional (dupes (policyNames ++ [ tiering.silo ]) != [ ])
        "tiering: the silo and the policies need different names"
      ++ lib.optional (!builtins.isBool tiering.enforce) "tiering.enforce must be true or false"
      ++ lib.optional (tiering.computerPolicy ? tgtMinutes)
        "tiering.computerPolicy: Microsoft says not to set a TGT lifetime for computers"
      ++ lib.concatMap (
        p:
        lib.optional (
          p ? tgtMinutes && (p.tgtMinutes < 45 || p.tgtMinutes > 600)
        ) "${p.name}: tgtMinutes must be 45 to 600 (AD minimum, domain maximum)"
      ) policies
      ++ lib.optional (!(tiering.userPolicy.deviceInSilo or false))
        "tiering.userPolicy: deviceInSilo must be true, or the silo protects nothing"
      ++ map (u: "tiering.users: ${u} is not an admin account in users") (
        builtins.filter (u: !lib.elem u adminSams) tiering.users
      )
      ++ map (u: "tiering.users: ${u} is the built-in Administrator, which policies never apply to") (
        builtins.filter (u: lib.toLower u == "administrator") tiering.users
      )
      ++ map (c: "tiering.computers: ${c} must be the computer name in capitals, without the $") (
        builtins.filter (c: lib.hasSuffix "$" c || lib.toUpper c != c) tiering.computers
      )
      ++ lib.optional (dupes (tiering.users ++ tiering.computers) != [ ]) "tiering: duplicate silo members"
      ++ lib.optional (jit.group != org.privileged.tier0Group) "tiering.jit.group must be privileged.tier0Group"
      ++ map (g: "tiering.jit: ${g} is not a role group") (
        builtins.filter (g: !lib.elem g roleNames) [
          jit.group
          jit.eligible
        ]
      )
      ++ lib.optional (
        jit.defaultHours < 1 || jit.defaultHours > jit.maxHours || jit.maxHours > 4
      ) "tiering.jit: need 1 <= defaultHours <= maxHours <= 4 (decision 6 in TIERING.md)"
      ++ lib.optional (
        (jit.removeStanding or false) && !jit.enabled
      ) "tiering.jit.removeStanding needs tiering.jit.enabled";

  # Delegation: rights below Domain Admins (converge.ps1 Sync-Delegation).
  delegation = org.delegation or null;
  resourceNames = map (g: g.name) org.resourceGroups;
  rightsTemplates = [
    "user-helpdesk"
    "computer-admin"
  ];
  # True when OU path a is b or below b.
  atOrBelow = a: b: a == b || lib.hasPrefix "${b}/" a;
  delegationErrors =
    if delegation == null then
      [ ]
    else
      let
        inherit (delegation) grants deny noDelegation;
        denyOUs = lib.concatMap (d: d.ous) deny;
        # A deny for principal p on OU m covers n when n is m or below m.
        deniedAt = n: p: lib.any (d: lib.elem p d.principals && lib.any (m: atOrBelow n m) d.ous) deny;
        principals = resourceNames ++ roleNames ++ sams;
        mustProtect = [
          "Admin-Accounts"
          "Service-Accounts"
          "Users/Members"
        ];
      in
      map (g: "delegation.grants: ${g.group} is not a resource group. AGDLP: only domain local groups get rights.") (
        builtins.filter (g: !lib.elem g.group resourceNames) grants
      )
      ++ map (g: "delegation.grants: ${g.group}: unknown rights template ${g.rights}") (
        builtins.filter (g: !lib.elem g.rights rightsTemplates) grants
      )
      ++ lib.concatMap (
        g:
        lib.concatMap (
          ou:
          lib.optional (!lib.elem ou ouPaths) "delegation.grants: ${g.group}: OU ${ou} is not in ous"
          ++ map (n: "delegation.grants: ${g.group} on ${ou} is in or below ${n}, which is in noDelegation") (
            builtins.filter (n: atOrBelow ou n) noDelegation
          )
          ++ map (
            n: "delegation.grants: ${g.group} on ${ou} is inherited by ${n} (noDelegation). Add a deny for ${g.group} on ${n}."
          ) (builtins.filter (n: n != ou && atOrBelow n ou && !(deniedAt n g.group)) noDelegation)
        ) g.ous
      ) grants
      ++ map (ou: "delegation: OU ${ou} is not in ous") (
        builtins.filter (ou: !lib.elem ou ouPaths) (denyOUs ++ noDelegation)
      )
      ++ map (ou: "delegation.deny: ${ou} must also be in noDelegation") (
        builtins.filter (ou: !lib.elem ou noDelegation) denyOUs
      )
      ++ map (ou: "delegation.noDelegation must list ${ou}") (
        builtins.filter (ou: !lib.elem ou noDelegation) mustProtect
      )
      ++ map (p: "delegation.deny: ${p} is not a group or user in org.json") (
        builtins.filter (p: !lib.elem p principals) (lib.concatMap (d: d.principals) deny)
      )
      ++ lib.concatMap (
        k:
        lib.optional (!lib.elem k.principal sams) "delegation.knownAces: ${k.principal} is not a user"
        ++ map (ou: "delegation.knownAces: ${k.principal}: OU ${ou} is not in ous") (
          builtins.filter (ou: !lib.elem ou ouPaths) k.ous
        )
      ) (delegation.knownAces or [ ])
      ++ map (s: "delegation.expectAdminCount: ${s} is not an admin account") (
        builtins.filter (s: !lib.elem s adminSams) (delegation.expectAdminCount or [ ])
      )
      ++ map (u: "${u.sam}: an admin account must be in Admin-Accounts/Tier0, Tier1 or Tier2") (
        builtins.filter (u: u.kind == "admin" && !lib.hasPrefix "Admin-Accounts/Tier" u.ou) org.users
      )
      ++ lib.optionals (tiering != null && tiering ? serverOU) (
        lib.optional (!lib.elem tiering.serverOU ouPaths) "tiering.serverOU ${tiering.serverOU} is not in ous"
        ++ lib.optional (!lib.elem tiering.serverOU noDelegation) "tiering.serverOU must be in delegation.noDelegation"
      );

  errors =
    tieringErrors
    ++ delegationErrors
    ++ map (g: "builtinAdministrator.removeFrom: ${g} is not in privileged.groups") (
      builtins.filter (g: !lib.elem g org.privileged.groups) (org.builtinAdministrator.removeFrom or [ ])
    )
    ++ lib.optional (dupes sams != [ ]) "duplicate users: ${toString (dupes sams)}"
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
