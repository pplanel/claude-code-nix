{
  description = "Claude Code's native binary, pinned, plus named per-account instances";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    # programs.claude-code-nix.mesh. Not following nixpkgs, so its build
    # matches the binary cache claude-mesh's CI publishes.
    claude-mesh.url = "github:pplanel/claude-mesh";
  };

  outputs = {
    self,
    nixpkgs,
    ...
  }: let
    systems = ["aarch64-darwin" "aarch64-linux" "x86_64-linux"];
    forAll = f:
      nixpkgs.lib.genAttrs systems (system:
        f (import nixpkgs {
          inherit system;
          config.allowUnfreePredicate = pkg: nixpkgs.lib.getName pkg == "claude-code";
        }));
  in {
    packages = forAll (pkgs: rec {
      claude-code = pkgs.callPackage ./pkgs/claude-code/package.nix {};
      default = claude-code;
    });

    # claude-code-native, so it doesn't shadow nixpkgs' claude-code.
    overlays.default = final: _: {
      claude-code-native = final.callPackage ./pkgs/claude-code/package.nix {};
    };

    homeManagerModules.default = import ./modules/instances.nix self;

    # For nix-darwin with home-manager: every user gets the option.
    darwinModules.default = {
      home-manager.sharedModules = [self.homeManagerModules.default];
    };

    checks = forAll (pkgs: {
      settings-merge = pkgs.callPackage ./tests/settings-merge.nix {};
      handoff-plugin = pkgs.callPackage ./tests/handoff-plugin.nix {
        claude-code = self.packages.${pkgs.stdenv.hostPlatform.system}.claude-code;
      };
      lint = pkgs.callPackage ./tests/lint.nix {src = self;};
    });

    formatter = forAll (pkgs: pkgs.alejandra);
  };
}
