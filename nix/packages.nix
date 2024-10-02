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

        zigDepsHash = "sha256-3HD3un8GrSi9oXNZo/35Hl2jNT3eMRQ/NeKF8KC2v1s=";
      };
    };
  };
}
