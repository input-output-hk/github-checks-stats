{
  perSystem = {
    config,
    pkgs,
    ...
  }: {
    devShells.default = pkgs.mkShell {
      name = "devShell";
      packages = with pkgs; [
        zls
      ];
      inputsFrom = [
        config.packages.github-checks-stats
      ];
    };
  };
}
