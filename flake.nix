{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = {nixpkgs, ...}: let
    system = "x86_64-linux";
    pkgs = import nixpkgs {inherit system;};
    nativeBuildInputs = with pkgs; [zola just tailwindcss_4];
  in {
    packages.${system}.default = pkgs.stdenv.mkDerivation {
      inherit nativeBuildInputs;
      name = "blog";
      src = ./.;

      buildPhase = ''just build'';
      installPhase = ''cp -r public $out'';
    };

    devShells.${system}.default = pkgs.mkShell {
      packages =
        nativeBuildInputs
        ++ (with pkgs; [
          watchman
          biome
          prettierd
          process-compose
        ]);
    };
  };
}
