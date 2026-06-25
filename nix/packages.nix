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

        zigDepsHash = "sha256-Rg/EAVtez/tJdHXZ9m97N5wtDwWyGKc5B6EWmWLG9TA=";

        buildInputs = with pkgs; [
          sqlite.dev
        ];
      };
    };
  };
}
