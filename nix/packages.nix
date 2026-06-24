{inputs, ...}: {
  perSystem = {pkgs, ...}: {
    packages = rec {
      default = github-checks-stats;

      github-checks-stats = pkgs.buildZigPackage {
        src = inputs.inclusive.lib.inclusive ../. [
          ../build.zig
          ../build.zig.zon
          ../src
        ];

        zigDepsHash = "sha256-/CZQz6WoPT1VMITX0VRMukJEiblz8TI8u/weMVeRVb4=";
      };
    };
  };
}
