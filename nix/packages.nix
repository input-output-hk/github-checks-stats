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

        zigDepsHash = "sha256-jWMgnn29T7KfsV6ZpXAv4ImieLB2r6yuNLBh9PSX4L4=";

        nativeBuildInputs = with pkgs; [
          pkg-config
        ];

        buildInputs = with pkgs; [
          sqlite.dev
        ];

        zigTarget = null;
      };
    };
  };
}
