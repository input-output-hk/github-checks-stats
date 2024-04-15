{
  perSystem = {
    inputs',
    config,
    pkgs,
    ...
  }: {
    devShells.default = pkgs.mkShell {
      name = "devShell";
      packages = [
        inputs'.cizero.packages.zls
      ];
      inputsFrom = [
        config.packages.github-checks-stats
      ];

      shellHook = ''
        # Set to `/build/tmp.XXXXXXXXXX` by the zig hook.
        unset ZIG_GLOBAL_CACHE_DIR
      '';
    };
  };
}
