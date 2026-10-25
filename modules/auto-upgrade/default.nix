# The host follows `main` of this repo. A timer reads the head of the branch
# every few minutes. When it differs from the revision the host runs
# (system.configurationRevision, set in flake.nix), the host builds that
# commit and switches to it. So a merge to main reaches every lab host in
# minutes, with no `deploy` by hand.
#
# The repo is public, so the host needs no key to read it. The flake reference
# names the commit (github:<repo>/<sha>), so nix does not serve a stale
# tarball from its cache.
#
#   - A deploy-rs deploy of another commit or a dirty tree holds only until the
#     next run, which switches back to main. To test a branch on a host for
#     longer, create the hold file first: `sudo touch /var/lib/patchwork-upgrade/hold`.
#     Remove it when done.
#   - A commit that does not build is written to
#     /var/lib/patchwork-upgrade/failed-rev and is not tried again. The unit
#     stays failed until main moves.
#   - A commit that builds but leaves a unit failed stays active. Fix it with a
#     new commit on main.
#
#   journalctl -u patchwork-upgrade     # what the last runs did
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.patchwork.autoUpgrade;
  host = config.networking.hostName;
  stateDir = "/var/lib/patchwork-upgrade";
in
{
  options.patchwork.autoUpgrade = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Follow `branch` of `repo`. Every lab host does.";
    };

    repo = lib.mkOption {
      type = lib.types.str;
      default = "patchworklabsorg/infra";
      description = "The GitHub repository (owner/name) with this flake. Must be public.";
    };

    branch = lib.mkOption {
      type = lib.types.str;
      default = "main";
      description = "The branch the host follows.";
    };

    dates = lib.mkOption {
      type = lib.types.str;
      default = "*:0/5";
      description = "When to check the branch (systemd OnCalendar).";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.patchwork-upgrade = {
      description = "Switch to the head of ${cfg.repo} ${cfg.branch}";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      # The run switches the system, and the switch must not restart the unit
      # that runs it. The same as system.autoUpgrade.
      restartIfChanged = false;
      unitConfig.X-StopOnRemoval = false;
      path = [
        pkgs.coreutils
        pkgs.gnutar
        pkgs.xz.bin
        pkgs.gzip
        pkgs.gitMinimal
        config.nix.package.out
        config.programs.ssh.package
        config.system.build.nixos-rebuild
      ];
      serviceConfig = {
        Type = "oneshot";
        StateDirectory = "patchwork-upgrade";
        TimeoutStartSec = "1h";
      };
      script = ''
        set -euo pipefail
        if [ -e ${stateDir}/hold ]; then
          echo "held: ${stateDir}/hold exists"
          exit 0
        fi
        remote=$(git ls-remote https://github.com/${cfg.repo}.git refs/heads/${cfg.branch} | cut -f1)
        if ! [[ $remote =~ ^[0-9a-f]{40}$ ]]; then
          echo "cannot read the head of ${cfg.repo} ${cfg.branch}" >&2
          exit 1
        fi
        current=$(/run/current-system/sw/bin/nixos-version --configuration-revision 2>/dev/null || true)
        if [ "$remote" = "$current" ]; then
          exit 0
        fi
        if [ "$remote" = "$(cat ${stateDir}/failed-rev 2>/dev/null || true)" ]; then
          echo "$remote did not build before; waiting for a new commit on ${cfg.branch}" >&2
          exit 1
        fi
        echo "switching from ''${current:-an unknown revision} to $remote"
        if ! nixos-rebuild switch --flake "github:${cfg.repo}/$remote#${host}"; then
          # Record it only when the switch did not happen: after a switch, the
          # running revision is $remote, so the next run does nothing anyway.
          if [ "$(/run/current-system/sw/bin/nixos-version --configuration-revision 2>/dev/null || true)" != "$remote" ]; then
            echo "$remote" > ${stateDir}/failed-rev
          fi
          exit 1
        fi
      '';
    };

    systemd.timers.patchwork-upgrade = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.dates;
        RandomizedDelaySec = "1min";
      };
    };
  };
}
