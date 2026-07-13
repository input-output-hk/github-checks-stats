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

        zigDepsHash = "sha256-F2fPX87qyXRfO8ihfGDo28AKsQ5S8e16lwXQQFgZJBM=";

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
