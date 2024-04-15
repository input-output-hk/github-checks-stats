{
  inputs = {
    cizero.url = github:input-output-hk/cizero;
    nixpkgs.follows = "cizero/nixpkgs";
    parts.follows = "cizero/parts";
    treefmt-nix.follows = "cizero/treefmt-nix";
    inclusive.follows = "cizero/inclusive";
  };

  outputs = inputs:
    inputs.parts.lib.mkFlake {inherit inputs;} {
      systems = ["x86_64-linux"];

      imports = [
        nix/packages.nix
        nix/formatter.nix
        nix/devShells.nix
      ];

      perSystem = {inputs', ...}: {
        _module.args.pkgs = inputs'.nixpkgs.legacyPackages.appendOverlays [
          (_final: _prev: {inherit (inputs'.cizero.packages) zig zls;})
          inputs.cizero.overlays.zig
        ];
      };
    };
}
