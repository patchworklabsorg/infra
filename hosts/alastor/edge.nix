# alastor as the public edge for Patchwork apps on the lab app VMs. Exported
# as nixosModules.edge-alastor. alastor terminates TLS and proxies plain HTTP
# over the tailnet to nginx on the app's VM. Same pattern as saker/Sentry in
# jaspermayone/infra.
#
# Weave stays on alastor (nixosModules.weave-alastor), so it has no route
# here. Import this module next to weave-alastor. One VM per app: add a route
# when the app runs on its VM, and remove the app's own alastor module in the
# same change in jaspermayone/infra.
{
  config,
  options,
  lib,
  pkgs,
  ...
}:
let
  tailnet = "wildebeest-stargazer.ts.net";
  kraterProduction = config.patchwork.edge.kraterProduction;

  # Krater's every-minute ping (`krater.services.network_watch` in Krater):
  # an HTTPS request to /healthz/edge over the path its runners report on
  # (Cloudflare, Traefik here, the tailnet to weft). While it arrives,
  # runners can reach Krater; when it stops, Krater holds what it would do
  # about machines whose runners went silent, and alerts. Production only
  # while its routes are on.
  kraterPingUrls = [
    "https://krater-staging.patchworklabs.org/healthz/edge"
  ]
  ++ lib.optional kraterProduction "https://krater.patchworklabs.org/healthz/edge";

  # Slack when a ping keeps failing, and again when it answers. Krater posts
  # its own alerts, so it can't say it's down: this is the one that can. A
  # Slack incoming-webhook URL, alone on one line, in
  # ../../secrets/krater-edge-alert.age; on as soon as that file exists.
  alertSecret = ../../secrets/krater-edge-alert.age;
  haveAlertSecret = builtins.pathExists alertSecret;
  hasAgenix = options ? age;
  webhookFile = config.patchwork.edge.kraterEdgeAlertWebhookFile;
  # Minutes of failed pings before the alert (a deploy or a blip is shorter),
  # and between reminders while it lasts.
  alertAfter = 3;
  remindEvery = 60;

  # <router name> = { backend = "<host>"; hosts = [ "<fqdn>" ... ]; };
  routes = {
    # Not `quilt`/`quilt-staging`: those were the router names of the old
    # Traefik fragment on alastor (quilt.toml), and the same name in two
    # files of the file provider collides.
    quilt-batting = {
      backend = "batting";
      hosts = [ "quilt.patchworklabs.org" ];
    };
    quilt-staging-batting = {
      backend = "batting";
      hosts = [ "quilt-staging.patchworklabs.org" ];
    };
    # Krater staging on weft (../weft/krater.nix): the portal and its S3
    # gateway. Not `krater`/`krater-storage`: the names of Krater's own
    # Traefik fragment, which a host that runs Krater with traefik.enable
    # would add. Production's routes are below, only while it is on.
    krater-staging-weft = {
      backend = "weft";
      hosts = [ "krater-staging.patchworklabs.org" ];
    };
    krater-staging-storage-weft = {
      backend = "weft";
      hosts = [ "krater-staging-storage.patchworklabs.org" ];
    };
    # Stash on hank (../hank/stash.nix): production and staging.
    stash-hank = {
      backend = "hank";
      hosts = [ "stash.patchworklabs.org" ];
    };
    stash-staging-hank = {
      backend = "hank";
      hosts = [ "stash-staging.patchworklabs.org" ];
    };
    # Selvage production on twill (../twill/selvage.nix). nginx on
    # twill passes /slack/, /up, and the admin web UI (/admin, /auth/,
    # /assets/, /cable).
    selvage-twill = {
      backend = "twill";
      hosts = [ "selvage.patchworklabs.org" ];
    };
    # Selvage staging on twill: its own vhost in nginx on twill, with the
    # same public paths as production.
    selvage-staging-twill = {
      backend = "twill";
      hosts = [ "selvage-staging.patchworklabs.org" ];
    };
    # Every host in ../warp/redirects.nix. A new path on an existing host
    # needs no change here.
    redirects = {
      backend = "warp";
      hosts = builtins.attrNames (import ../warp/redirects.nix);
    };
  }
  // lib.optionalAttrs kraterProduction {
    krater-weft = {
      backend = "weft";
      hosts = [ "krater.patchworklabs.org" ];
    };
    krater-storage-weft = {
      backend = "weft";
      hosts = [ "krater-storage.patchworklabs.org" ];
    };
  };
in
{
  # Set from the one switch for Krater production
  # (../weft/krater-production.nix). An option only so that the test can turn
  # the routes on: set the switch file, not this.
  options.patchwork.edge.kraterEdgePing = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Ping Krater's /healthz/edge every minute, so it knows its runners can reach it.";
  };

  options.patchwork.edge.kraterProduction = lib.mkOption {
    type = lib.types.bool;
    default = (import ../weft/krater-production.nix).enable;
    description = "Route krater.patchworklabs.org and krater-storage.patchworklabs.org to weft.";
  };

  options.patchwork.edge.kraterEdgeAlertWebhookFile = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = if haveAlertSecret && hasAgenix then config.age.secrets.krater-edge-alert.path else null;
    description = ''
      A file holding a Slack incoming-webhook URL. When set, krater-edge-ping
      posts there after ${toString alertAfter} failed minutes in a row for a
      URL, every ${toString remindEvery} minutes while it lasts, and once
      when it answers again. Defaults to the agenix secret
      krater-edge-alert.age once that file exists.
    '';
  };

  # The secret only where agenix is: the edge test's bare system has no `age`
  # option. Inside `config`, so that reading `options` here can't recurse.
  config = lib.mkMerge [
    {
      systemd.services.krater-edge-ping = lib.mkIf config.patchwork.edge.kraterEdgePing {
        description = "Tell Krater its runners' path to it works";
        path = [ pkgs.curl ];
        serviceConfig = {
          Type = "oneshot";
          DynamicUser = true;
          # Consecutive failures per URL, kept between runs.
          StateDirectory = "krater-edge-ping";
        }
        // lib.optionalAttrs (webhookFile != null) {
          LoadCredential = [ "webhook:${webhookFile}" ];
        };
        # Every URL, even after one fails: staging and production are separate.
        # A failed Slack post doesn't fail the unit, and doesn't stop the count.
        script = ''
          status=0
          say() {
            [ -n "''${CREDENTIALS_DIRECTORY:-}" ] && [ -r "$CREDENTIALS_DIRECTORY/webhook" ] || return 0
            curl -fsS -o /dev/null --max-time 10 -H 'Content-Type: application/json' \
              --data "{\"text\": \"$1\"}" "$(head -n1 "$CREDENTIALS_DIRECTORY/webhook")" \
              || echo "couldn't post to Slack" >&2
          }
          for url in ${lib.escapeShellArgs kraterPingUrls}; do
            host=''${url#https://}
            host=''${host%%/*}
            file="$STATE_DIRECTORY/$host"
            failed=$(cat "$file" 2>/dev/null || echo 0)
            if curl -fsS -o /dev/null --max-time 20 "$url"; then
              if [ "$failed" -ge ${toString alertAfter} ]; then
                say ":white_check_mark: alastor reaches $host again, after $failed minutes without an answer."
              fi
              echo 0 > "$file"
            else
              echo "no answer from $url" >&2
              status=1
              failed=$((failed + 1))
              echo "$failed" > "$file"
              if [ "$failed" -eq ${toString alertAfter} ]; then
                say ":rotating_light: alastor has had no answer from $host for $failed minutes (krater-edge-ping). Its runners likely can't reach it either. Check weft and the Krater service; the edge-ping runbook is in docs/guides/compute-runbook.md."
              elif [ "$failed" -gt ${toString alertAfter} ] && [ $(( (failed - ${toString alertAfter}) % ${toString remindEvery} )) -eq 0 ]; then
                say ":rotating_light: Still no answer from $host, for $failed minutes now."
              fi
            fi
          done
          exit $status
        '';
      };

      systemd.timers.krater-edge-ping = lib.mkIf config.patchwork.edge.kraterEdgePing {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "minutely";
          AccuracySec = "5s";
        };
      };

      environment.etc."traefik/conf.d/patchwork.toml".source =
        (pkgs.formats.toml { }).generate "patchwork.toml"
          {
            http = {
              routers = lib.mapAttrs (name: r: {
                rule = lib.concatMapStringsSep " || " (h: "Host(`${h}`)") r.hosts;
                entryPoints = [ "websecure" ];
                tls.certResolver = "cloudflare";
                middlewares = [ "hsts" ];
                service = name;
              }) routes;
              services = lib.mapAttrs (_: r: {
                loadBalancer.servers = [ { url = "http://${r.backend}.${tailnet}"; } ];
              }) routes;
            };
          };
    }
    (lib.optionalAttrs hasAgenix {
      age.secrets = lib.mkIf haveAlertSecret {
        krater-edge-alert = {
          file = alertSecret;
          mode = "400";
        };
      };
    })
  ];
}
