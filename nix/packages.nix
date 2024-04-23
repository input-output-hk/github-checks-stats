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

        zigDepsHash = "sha256-ip40SQ5/ZvYeOg4M45eFatAx7obYJpRCJWTHeest2oc=";
      };
    };
  };
}
