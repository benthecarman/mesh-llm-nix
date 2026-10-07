{
  description = "Nix packages and a NixOS module for MeshLLM";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # The MeshLLM source pin. Override it from a consuming flake with
    #   inputs.mesh-llm-nix.inputs.mesh-llm-src.follows = "my-mesh-llm-src";
    # or on the command line with
    #   --override-input mesh-llm-src github:Mesh-LLM/mesh-llm/<rev>
    mesh-llm-src = {
      url = "github:Mesh-LLM/mesh-llm";
      flake = false;
    };
    # The NWC wallet plugin, overridable the same way.
    nwc-wallet-src = {
      url = "github:benthecarman/nwc-wallet";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      mesh-llm-src,
      nwc-wallet-src,
    }:
    let
      inherit (nixpkgs) lib;
      supportedSystems = [
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAllSystems = lib.genAttrs supportedSystems;

      # Build a package set from any MeshLLM source tree. Cargo and llama.cpp
      # inputs follow the source's own lock and pin files; only the console's
      # pnpm dependency hash can need an explicit value (see README).
      mkPackages =
        {
          pkgs,
          src ? mesh-llm-src,
          rev ? src.rev or null,
          uiPnpmDepsHash ? null,
          nwcWalletSrc ? nwc-wallet-src,
        }:
        pkgs.callPackage ./nix {
          inherit
            src
            rev
            uiPnpmDepsHash
            nwcWalletSrc
            ;
        };

      pkgsFor = system: nixpkgs.legacyPackages.${system};
      # CUDA is unfree; only the CUDA variant's package set accepts it.
      cudaPkgsFor =
        system:
        import nixpkgs {
          inherit system;
          config = {
            allowUnfree = true;
            cudaSupport = true;
          };
        };
    in
    {
      lib = { inherit mkPackages; };

      overlays.default = final: _prev: {
        mesh-llm-packages = mkPackages { pkgs = final; };
        mesh-llm = final.mesh-llm-packages.mesh-llm;
      };

      packages = forAllSystems (
        system:
        let
          meshPkgs = mkPackages { pkgs = pkgsFor system; };
          cudaMeshPkgs = mkPackages { pkgs = cudaPkgsFor system; };
        in
        {
          default = meshPkgs.mesh-llm;
          inherit (meshPkgs)
            mesh-llm
            mesh-llm-vulkan
            mesh-llm-unwrapped
            mesh-llm-ui
            skippy
            llama-cpp-skippy
            native-runtime-cpu
            native-runtime-vulkan
            nwc-wallet
            ;
          inherit (cudaMeshPkgs) mesh-llm-cuda native-runtime-cuda;
        }
      );

      apps = forAllSystems (system: {
        default = self.apps.${system}.mesh-llm;
        mesh-llm = {
          type = "app";
          program = "${self.packages.${system}.mesh-llm}/bin/mesh-llm";
          meta.description = "Run MeshLLM with the CPU native runtime";
        };
        mesh-llm-cuda = {
          type = "app";
          program = "${self.packages.${system}.mesh-llm-cuda}/bin/mesh-llm";
          meta.description = "Run MeshLLM with the CUDA native runtime";
        };
        skippy = {
          type = "app";
          program = "${self.packages.${system}.skippy}/bin/skippy";
          meta.description = "Run the standalone Skippy server";
        };
      });

      checks = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          inherit (self.packages.${system}) mesh-llm skippy;
          nixos-module = pkgs.testers.runNixOSTest (
            import ./nix/tests/module.nix {
              meshLlmModule = self.nixosModules.mesh-llm;
            }
          );
        }
      );

      nixosModules = {
        default = self.nixosModules.mesh-llm;
        mesh-llm =
          { lib, pkgs, ... }:
          {
            imports = [ ./nix/module.nix ];
            services.mesh-llm.package = lib.mkDefault (mkPackages { inherit pkgs; }).mesh-llm-default;
          };
      };

      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.nixfmt-tree
              pkgs.nix-prefetch-git
            ];
          };
        }
      );

      formatter = forAllSystems (system: (pkgsFor system).nixfmt-tree);
    };
}
