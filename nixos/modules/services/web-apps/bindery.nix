{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.bindery;

  # Upstream keeps the database and the data directory as two independent
  # variables but defaults both to /config on Linux, so the module collapses
  # them into one state directory.
  inherit (cfg) stateDir;

  # Content directories are not necessarily under stateDir, and ProtectSystem
  # makes everything else read-only, so any configured path outside stateDir
  # has to be declared writable explicitly.
  externalPaths = lib.filter (p: p != null && !lib.hasPrefix stateDir p) [
    cfg.libraryDir
    cfg.audiobookDir
    cfg.downloadDir
    cfg.audiobookDownloadDir
  ];

  # Nullable options are omitted from the environment entirely so upstream's own
  # default applies, rather than encoding a second copy of it here.
  optionalEnvironment = lib.filterAttrs (_: v: v != null) {
    BINDERY_AUDIOBOOK_DIR = cfg.audiobookDir;
    BINDERY_AUDIOBOOK_DOWNLOAD_DIR = cfg.audiobookDownloadDir;
    BINDERY_DOWNLOAD_DIR = cfg.downloadDir;
    BINDERY_OIDC_REDIRECT_BASE_URL = cfg.oidc.redirectBaseUrl;
    BINDERY_OIDC_ADMIN_GROUP = cfg.oidc.adminGroup;
    BINDERY_FRAME_ANCESTORS = cfg.frameAncestors;
    BINDERY_OUTBOUND_PROXY = cfg.outboundProxy;
    BINDERY_CONTACT = cfg.contact;
  };

  environment = {
    BINDERY_PORT = toString cfg.port;
    BINDERY_DB_PATH = "${stateDir}/bindery.db";
    BINDERY_DATA_DIR = stateDir;
    BINDERY_LOG_LEVEL = cfg.logLevel;
    BINDERY_LIBRARY_DIR = cfg.libraryDir;
    BINDERY_DOWNLOAD_PATH_REMAP = lib.concatStringsSep "," cfg.downloadPathRemap;
    BINDERY_IMAGE_CACHE_MAX_MB = toString cfg.imageCacheMaxMB;
    BINDERY_LOG_RETENTION_DAYS = toString cfg.logRetentionDays;
    BINDERY_DOWNLOAD_RETENTION_DAYS = toString cfg.downloadRetentionDays;
    BINDERY_DIR_MODE = cfg.dirMode;
    BINDERY_SHUTDOWN_GRACE = cfg.shutdownGrace;

    BINDERY_LOCAL_AUTH_ENABLED = lib.boolToString cfg.localAuth.enable;
    BINDERY_PROXY_AUTO_PROVISION = lib.boolToString cfg.forwardAuth.autoProvision;
    BINDERY_OIDC_AUTO_PROVISION = lib.boolToString cfg.oidc.autoProvision;
    BINDERY_OIDC_EMAIL_LINK = lib.boolToString cfg.oidc.emailLink;
    BINDERY_OIDC_DEFAULT_ROLE = cfg.oidc.defaultRole;
    BINDERY_OIDC_GROUP_CLAIM = cfg.oidc.groupClaim;

    BINDERY_URL_BASE = cfg.urlBase;
    BINDERY_TRUSTED_PROXY = lib.concatStringsSep "," cfg.trustedProxies;
    BINDERY_ALLOWED_HOSTS = lib.concatStringsSep "," cfg.allowedHosts;
    BINDERY_COOKIE_SECURE = cfg.cookieSecure;
    BINDERY_OUTBOUND_PROXY_BYPASS_LOCAL = lib.boolToString cfg.outboundProxyBypassLocal;
    BINDERY_OUTBOUND_PROXY_NO_PROXY = lib.concatStringsSep "," cfg.outboundProxyNoProxy;

    BINDERY_ENHANCED_HARDCOVER_API = lib.boolToString cfg.enhancedHardcoverApi;
  }
  // lib.optionalAttrs cfg.forwardAuth.enable {
    BINDERY_PROXY_AUTH_HEADER = cfg.forwardAuth.header;
  }
  // lib.optionalAttrs cfg.oidc.allowLanDiscovery {
    BINDERY_ALLOW_LAN_OIDC = "1";
  }
  // lib.optionalAttrs cfg.multiUser {
    BINDERY_ENFORCE_TENANCY = "true";
  }
  // lib.optionalAttrs cfg.ssrf.allowPrivateWebhooks {
    BINDERY_NOTIFICATIONS_ALLOW_PRIVATE = "1";
  }
  // lib.optionalAttrs cfg.ssrf.allowLinkLocalServices {
    BINDERY_ALLOW_LINK_LOCAL_SERVICES = "1";
  }
  // lib.optionalAttrs cfg.ssrf.allowLoopbackDownloads {
    BINDERY_DOWNLOAD_ALLOW_LOOPBACK = "1";
  }
  // {
    # Upstream only accepts the exact lowercase string "true" here, and it is
    # a disabled-flag rather than an enabled-flag, so `telemetry.enable = true`
    # has to write "false" to override the package wrapper's disabled default.
    BINDERY_TELEMETRY_DISABLED = if cfg.telemetry.enable then "false" else "true";
  }
  // optionalEnvironment
  // cfg.extraEnvironment;
in
{
  options.services.bindery = {
    enable = lib.mkEnableOption "Bindery, a self-hosted ebook and audiobook manager";

    package = lib.mkPackageOption pkgs "bindery" { };

    user = lib.mkOption {
      type = lib.types.str;
      default = "bindery";
      description = "User account under which Bindery runs.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "bindery";
      description = "Group under which Bindery runs.";
    };

    stateDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/bindery";
      description = ''
        Directory holding both the SQLite database and the data directory
        (backups, covers and the image cache). Upstream calls these
        `BINDERY_DB_PATH` and `BINDERY_DATA_DIR` and defaults both to `/config`;
        the module keeps them together, as upstream does on Linux.

        Must be a direct child of `/var/lib` so it can be expressed as a
        systemd `StateDirectory`.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8787;
      description = ''
        TCP port the web interface listens on.

        Upstream binds all interfaces and has no bind-address option, so this
        cannot be restricted to a single interface by configuration.
      '';
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Open the port in the firewall. Note that opening it also exposes the
        unauthenticated `/metrics` endpoint, which upstream mounts before its
        authentication middleware and does not guard with the API key.

        Prefer a reverse proxy on the same host over opening this port.
      '';
    };

    dirMode = lib.mkOption {
      type = lib.types.enum [
        "0700"
        "0750"
        "0755"
      ];
      default = "0750";
      description = ''
        Mode for the library directories the importer creates (author, book and
        audiobook folders, metadata sidecars, drop-folder handoff).

        Upstream accepts only these three values and silently keeps the default
        for anything else.
      '';
    };

    shutdownGrace = lib.mkOption {
      type = lib.types.str;
      default = "10s";
      description = ''
        Grace period for draining in-flight HTTP requests on shutdown, as a
        systemd-style duration.

        Upstream adds a further background-job drain, `BINDERY_JOBS_DRAIN_GRACE`,
        defaulting to `15s`, so the total termination budget is the sum of the
        two unless `TimeoutStopSec` is raised to match. Both drain serially.
      '';
    };

    extraEnvironment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        BINDERY_JOBS_DRAIN_GRACE = "30s";
      };
      description = ''
        Extra environment variables for the service, for upstream variables this
        module does not model. These take precedence over the module's own
        values.
      '';
    };

    libraryDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/bindery/library";
      description = ''
        Root of the ebook library. Upstream defaults to `/books`.
      '';
    };

    audiobookDir = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Root of the audiobook library. When unset, upstream routes audiobooks to
        {option}`libraryDir`, and a per-author root folder override still takes
        precedence over either.
      '';
    };

    downloadDir = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Directory the download client writes into. When unset, upstream falls
        back to `/downloads`, which does not exist on NixOS; set this in
        practice.

        Upstream does not validate this path at startup, so a wrong value only
        surfaces when a download or import fails.
      '';
    };

    audiobookDownloadDir = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Audiobook download directory. When unset, upstream falls back to
        {option}`downloadDir`.
      '';
    };

    downloadPathRemap = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "/downloads:/mnt/downloads" ];
      description = ''
        `from:to` pairs applied to paths returned by the download client, for
        when it and Bindery see the same storage at different paths. Joined into
        upstream's comma-separated `BINDERY_DOWNLOAD_PATH_REMAP`.
      '';
    };

    imageCacheMaxMB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2048;
      description = ''
        Size cap, in MiB, for the proxied cover cache under {option}`stateDir`.
        Upstream clamps this to 1 TiB.
      '';
    };

    logRetentionDays = lib.mkOption {
      type = lib.types.ints.positive;
      default = 14;
      description = "Days of application log rows to keep.";
    };

    downloadRetentionDays = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 90;
      description = ''
        Days a finished download row is kept before it is trimmed. `0` keeps
        every row. History and the blocklist are never trimmed by this.
      '';
    };

    localAuth.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether local password authentication is available. Disabling it also
        disables the first-run setup page, so an identity provider must already
        be configured or the instance cannot be logged into.
      '';
    };

    forwardAuth = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Trust an authentication proxy in front of Bindery, which passes the
          authenticated user name in {option}`forwardAuth.header`.

          Upstream refuses to start in this mode when
          {option}`trustedProxies` is empty, because any client could forge the
          header.
        '';
      };

      header = lib.mkOption {
        type = lib.types.str;
        default = "X-Forwarded-User";
        description = "Header carrying the authenticated user name.";
      };

      autoProvision = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Create a Bindery account for users the proxy reports.";
      };
    };

    oidc = {
      redirectBaseUrl = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "https://books.example.com";
        description = ''
          Absolute http(s) URL Bindery is reached at, used to build the OIDC
          redirect URI. Upstream treats an unparseable value as fatal. Without
          it, the callback is derived from the request Host header, which is
          wrong behind a proxy.
        '';
      };

      autoProvision = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Create accounts for identity-provider users on first login.";
      };

      emailLink = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Link accounts with a matching email address automatically.";
      };

      defaultRole = lib.mkOption {
        type = lib.types.enum [
          "admin"
          "user"
          "requester"
        ];
        default = "user";
        description = ''
          Role assigned to a newly provisioned identity-provider user. Upstream
          silently coerces anything it does not recognise to `user`.
        '';
      };

      adminGroup = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Group in the group claim that grants the admin role. When set, the
          identity provider becomes authoritative: users without the group are
          demoted to `user` on every login.
        '';
      };

      groupClaim = lib.mkOption {
        type = lib.types.str;
        default = "groups";
        description = "Claim in the ID token holding the user's groups.";
      };

      allowLanDiscovery = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Let the OIDC discovery probe reach loopback addresses (`127.0.0.0/8`,
          `::1`). Upstream already permits RFC 1918 addresses by default; this
          additionally allows an identity provider running on the Bindery host
          itself. Link-local and cloud metadata stay blocked.
        '';
      };
    };

    multiUser = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Scope queue, history, pending and OPDS resources to their owning user.
        Enabled is upstream's `BINDERY_ENFORCE_TENANCY=true`; disabled leaves
        ownership checks a no-op, which suits a single-user instance.
      '';
    };

    rateLimit = {
      maxFailures = lib.mkOption {
        type = lib.types.ints.positive;
        default = 5;
        description = "Failed logins per IP before throttling.";
      };

      windowMinutes = lib.mkOption {
        type = lib.types.ints.positive;
        default = 15;
        description = "Sliding window, in minutes, for the login throttle.";
      };
    };

    urlBase = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "/bindery";
      description = ''
        Path prefix the whole application is served under, including the health
        and metrics routes. Empty serves at the root.
      '';
    };

    trustedProxies = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "127.0.0.1" ];
      description = ''
        Addresses (IPs or CIDRs) whose `X-Forwarded-For` and
        `X-Forwarded-Proto` headers are believed. Joined into upstream's
        comma-separated list.

        Required for {option}`forwardAuth.enable`, and needed behind a reverse
        proxy for correct client IPs and cookie security. Do not use
        `0.0.0.0/0`: upstream accepts it but warns that it defeats the login
        rate limiter.
      '';
    };

    allowedHosts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "books.example.com" ];
      description = ''
        Additional host names accepted by upstream's DNS-rebinding check. A bare
        `*` disables the check entirely.
      '';
    };

    cookieSecure = lib.mkOption {
      type = lib.types.enum [
        "auto"
        "always"
        "never"
      ];
      default = "auto";
      description = ''
        When to set the `Secure` flag on session cookies. `auto` trusts TLS or
        `X-Forwarded-Proto`; `never` on a TLS-terminating proxy leaks cookies
        over plaintext.
      '';
    };

    frameAncestors = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "https://organizr.example.com";
      description = ''
        CSP `frame-ancestors` source list, to allow embedding the UI in a
        dashboard. Unset keeps framing blocked entirely.
      '';
    };

    outboundProxy = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "http://proxy.example.com:3128";
      description = ''
        Proxy URL (`http`, `https` or `socks5`) for Bindery's remote-facing
        traffic: indexers, metadata providers, covers and webhooks. Download
        clients and OIDC discovery stay direct by design.

        The two companion settings below are separate top-level options rather
        than attributes of this one, because a NixOS option cannot be both a
        string and a parent of further options.
      '';
    };

    outboundProxyBypassLocal = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Send LAN, loopback and single-label destinations direct.";
    };

    outboundProxyNoProxy = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional hosts, domain suffixes or CIDRs that bypass the proxy.";
    };

    ssrf = {
      allowPrivateWebhooks = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Deliver webhook notifications to RFC 1918 private addresses
          (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`), by relaxing the
          webhook SSRF policy from strict to LAN. Loopback, link-local and cloud
          metadata endpoints remain blocked.
        '';
      };

      allowLinkLocalServices = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Let the service URLs typed into settings (indexers, Prowlarr, download
          client control endpoints, Audiobookshelf, Grimmory, the Calibre
          plugin) reach link-local addresses (`169.254.0.0/16`, `fe80::/10`).
          Needed for rootless Podman with pasta, where the host is only
          reachable at `169.254.1.2`.

          Cloud metadata stays blocked, and URLs chosen by a remote party
          (indexer-provided download links, covers, webhooks) never see
          link-local.
        '';
      };

      allowLoopbackDownloads = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Fetch indexer-provided download links (`.torrent`, `.nzb`) from
          loopback (`127.0.0.0/8`, `::1`), for setups co-locating Prowlarr or an
          indexer on the Bindery host. Link-local and cloud metadata stay
          blocked.

          Off by default because the link is chosen by the indexer's response,
          so a malicious indexer could otherwise reach a service bound to
          Bindery's own loopback.
        '';
      };
    };

    logLevel = lib.mkOption {
      type = lib.types.enum [
        "debug"
        "info"
        "warn"
        "error"
      ];
      default = "info";
      description = "Log verbosity. Unknown values fall back to `info` upstream.";
    };

    telemetry.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Send the anonymous once-at-startup and daily telemetry ping to
        `api.getbindery.dev`. Set to `false` to disable it.

        Upstream expresses this as a disabled-flag that only understands the
        exact lowercase string `true`, so the module writes that literal when
        this option is `false`, and `false` when it is `true` to override the
        package wrapper's disabled default.
      '';
    };

    contact = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "ops@example.com";
      description = ''
        Contact address embedded in the outbound `User-Agent` sent to metadata
        providers, which is a courtesy to the public APIs Bindery uses. An email
        address is rewritten to `mailto:` upstream.
      '';
    };

    enhancedHardcoverApi = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Use Hardcover's enhanced series API for series matching.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion =
          lib.hasPrefix "/var/lib/" stateDir && !(lib.hasInfix "/" (lib.removePrefix "/var/lib/" stateDir));
        message = "services.bindery.stateDir must be a direct child of /var/lib, so it can be a systemd StateDirectory (got ${stateDir}).";
      }
      {
        assertion = !cfg.forwardAuth.enable || cfg.trustedProxies != [ ];
        message = "services.bindery.forwardAuth.enable requires services.bindery.trustedProxies: upstream refuses to start in proxy auth mode without it, since any client could forge the authentication header.";
      }
    ];

    users.users = lib.mkIf (cfg.user == "bindery") {
      bindery = {
        isSystemUser = true;
        inherit (cfg) group;
        home = stateDir;
      };
    };

    users.groups = lib.mkIf (cfg.group == "bindery") {
      bindery = { };
    };

    systemd.services.bindery = {
      description = "Bindery ebook and audiobook manager";
      documentation = [ "https://github.com/vavallee/bindery" ];

      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      inherit environment;

      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        ExecStart = lib.getExe cfg.package;

        # Holds the database, its WAL/SHM files, backups, covers and the image
        # cache. 0700 because none of it is meant to be shared.
        StateDirectory = lib.removePrefix "/var/lib/" stateDir;
        StateDirectoryMode = "0700";

        # 0027 keeps upstream's intended 0640 files and 0750 directories; 0077
        # would silently strip the group-read bit they are created with.
        UMask = "0027";

        Restart = "on-failure";
        RestartSec = "5s";

        # Upstream drains in-flight requests for BINDERY_SHUTDOWN_GRACE and then
        # background jobs for BINDERY_JOBS_DRAIN_GRACE, serially, so the stop
        # timeout has to cover both plus a margin.
        TimeoutStopSec = "40s";

        ReadWritePaths = externalPaths;

        # Hardening. Bindery needs no privileges: it writes only under its state
        # and content directories and binds an unprivileged port.
        #
        # PrivateUsers is deliberately not set: it would map only the service
        # user into the namespace, hiding a library directory that is owned by
        # another user or group.
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        PrivateMounts = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectProc = "invisible";
        ProcSubset = "pid";
        RemoveIPC = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        NoNewPrivileges = true;
        CapabilityBoundingSet = [ "" ];
        DeviceAllow = [ "" ];
        SystemCallArchitectures = "native";
        # @system-service already covers chmod/fchmod through @file-system;
        # there is no @chmod group, and naming one makes systemd ignore it.
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
          "@chown"
        ];
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
          "AF_NETLINK"
        ];
      };
    };

    # StateDirectory creates the state directory but not the library root, and
    # upstream warns at startup when the library directory is missing while
    # still expecting the first import to create it.
    systemd.tmpfiles.rules = [
      "d '${stateDir}' 0700 ${cfg.user} ${cfg.group} -"
      "d '${cfg.libraryDir}' ${cfg.dirMode} ${cfg.user} ${cfg.group} -"
    ]
    ++ lib.optional (
      cfg.audiobookDir != null && cfg.audiobookDir != cfg.libraryDir
    ) "d '${cfg.audiobookDir}' ${cfg.dirMode} ${cfg.user} ${cfg.group} -";

    networking.firewall = lib.mkIf cfg.openFirewall {
      allowedTCPPorts = [ cfg.port ];
    };
  };

  meta.maintainers = with lib.maintainers; [ twstagg ];
}
