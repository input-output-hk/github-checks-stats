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

        zigDepsHash = "sha256-8ZGMsLRB4sQtHRhCSfULmplXTaDC5Oc0IzwI92VevEs=";

        buildInputs = with pkgs; [
          sqlite.dev
        ];
      };
    };
  };
}
