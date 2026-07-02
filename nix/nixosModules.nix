{moduleWithSystem, ...}: {
  flake.nixosModules.default = moduleWithSystem (perSystem @ {config}: {
    config,
    lib,
    ...
  }: let
    name = "github-checks-stats";

    cfg = config.services.${name};
  in {
    options.services.${name} = {
      enable = lib.mkEnableOption "${name} (in watch mode)";

      package = lib.mkPackageOption perSystem.config.packages name {};

      repositories = lib.mkOption {
        type = with lib.types; listOf str;
        description = "Repositories to scan.";
      };

      settings = lib.mkOption {
        type = with lib.types; attrsOf anything;
      };
    };

    config = lib.mkIf cfg.enable {
      services.${name}.settings = {
        db = "/var/lib/${name}/db.sqlite";
        metrics-listen = lib.mkDefault "127.0.0.1:8778";
      };

      systemd.services.${name} = {
        wantedBy = ["multi-user.target"];
        requisite = ["network-online.target"];
        after = ["network-online.target"];

        path = [cfg.package];

        script = let
          settings =
            cfg.settings
            // lib.optionalAttrs (cfg.settings ? token-file) {
              token-file = "/run/credentials/${name}.service/token";
            };
        in ''
          exec github-checks-stats watch \
            ${lib.cli.toCommandLineShellGNU or lib.cli.toGNUCommandLineShell {} settings} \
            ${lib.escapeShellArgs cfg.repositories}
        '';

        enableStrictShellChecks = true;

        serviceConfig = {
          StateDirectory = name;
          DynamicUser = true;
          LoadCredential = lib.optional (cfg.settings ? token-file) "token:${cfg.settings.token-file}";
        };
      };
    };
  });
}
