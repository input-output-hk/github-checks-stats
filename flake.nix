{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/release-26.05";
    parts.url = "github:hercules-ci/flake-parts";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    inclusive = {
      url = "github:input-output-hk/nix-inclusive";
      inputs.stdlib.follows = "parts/nixpkgs-lib";
    };
    utils = {
      url = "github:dermetfan/utils.zig";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        parts.follows = "parts";
        treefmt-nix.follows = "treefmt-nix";
        inclusive.follows = "inclusive";
      };
    };
  };

  outputs = inputs:
    inputs.parts.lib.mkFlake {inherit inputs;} {
      systems = ["x86_64-linux"];

      imports = [
        nix/packages.nix
        nix/nixosModules.nix
        nix/formatter.nix
        nix/devShells.nix
      ];

      perSystem = {inputs', ...}: {
        _module.args.pkgs = inputs'.nixpkgs.legacyPackages.appendOverlays [
          inputs.utils.overlays.zig
        ];
      };
    };
}
