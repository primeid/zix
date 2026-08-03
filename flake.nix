{
  description = "ZIX — the Nix expression language, reimplemented in Zig";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      pkgsFor = system: import nixpkgs { inherit system; };
    in
    {
      packages = forAllSystems (system:
        let pkgs = pkgsFor system;
        in {
          default = pkgs.stdenv.mkDerivation {
            pname = "zix";
            version = "0.1.0";
            src = self;
            nativeBuildInputs = [ pkgs.zig ];
            buildPhase = "zig build -Doptimize=ReleaseSafe";
            installPhase = "install -Dm755 zig-out/bin/zix $out/bin/zix";
          };
        });

      devShells = forAllSystems (system:
        let pkgs = pkgsFor system;
        in {
          default = pkgs.mkShell {
            packages = [ pkgs.zig ];
          };
        });
    };
}
