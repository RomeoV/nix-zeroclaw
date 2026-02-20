{
  description = "nix-zeroclaw: declarative ZeroClaw packaging";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zeroclaw-src = {
      url = "github:RomeoV/zeroclaw/a4356f4fba31a9a243a0ed94e3e17469fac808aa";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, flake-utils, zeroclaw-src }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" ] (system:
      let
        pkgs = import nixpkgs { inherit system; };
        zeroclaw = pkgs.callPackage ./nix/package.nix { src = zeroclaw-src; };
      in {
        packages = {
          default = zeroclaw;
          inherit zeroclaw;
        };
      }
    ) // {
      overlays.default = final: prev: {
        zeroclaw = final.callPackage ./nix/package.nix { src = zeroclaw-src; };
      };
      nixosModules.zeroclaw = import ./nix/module.nix;
    };
}
