{
  lib,
  newScope,
  config,
  src,
  rev ? null,
  uiPnpmDepsHash ? null,
}:

lib.makeScope newScope (
  self:
  let
    workspace = builtins.fromTOML (builtins.readFile "${src}/Cargo.toml");
    uiLock = "${src}/mesh/crates/mesh-llm-ui/pnpm-lock.yaml";
    uiLockSha256 = builtins.hashFile "sha256" uiLock;
    knownUiHashes = lib.importJSON ./ui-pnpm-deps.json;
  in
  {
    meshLlmSrc = src;
    meshLlmRev = rev;
    meshLlmVersion = workspace.workspace.package.version;
    # The version the host reports. Builds from a commit carry its short SHA,
    # like upstream's non-release builds, so they are not mistaken for a
    # published release.
    meshLlmBuildVersion =
      if rev == null then
        self.meshLlmVersion
      else
        "${self.meshLlmVersion}+g${lib.toUpper (builtins.substring 0 6 rev)}";

    # pnpm dependency hashes are keyed by the lock file, so a new source pin
    # with an unchanged console lock needs no new hash.
    uiPnpmDepsHash =
      if uiPnpmDepsHash != null then
        uiPnpmDepsHash
      else
        knownUiHashes.${uiLockSha256} or (lib.warn ''
          mesh-llm-nix: no pnpm dependency hash is known for this console lock
          file (pnpm-lock.yaml sha256 ${uiLockSha256}). The build will fail and
          print the correct hash. Pass it as uiPnpmDepsHash, or add it to
          nix/ui-pnpm-deps.json.
        '' lib.fakeHash);

    llamaCppPin = lib.trim (builtins.readFile "${src}/skippy/llama_cpp/upstream.txt");
    llamaCppUpstream = builtins.fetchGit {
      url = "https://github.com/ggml-org/llama.cpp";
      rev = self.llamaCppPin;
      shallow = true;
    };

    llama-cpp-skippy = self.callPackage ./llama-cpp-skippy.nix { };
    mesh-llm-ui = self.callPackage ./mesh-llm-ui.nix { };
    mesh-llm-unwrapped = self.callPackage ./mesh-llm-unwrapped.nix { };

    native-runtime-cpu = self.callPackage ./native-runtime.nix { backend = "cpu"; };
    native-runtime-vulkan = self.callPackage ./native-runtime.nix { backend = "vulkan"; };
    native-runtime-cuda = self.callPackage ./native-runtime.nix { backend = "cuda"; };

    mesh-llm = self.callPackage ./product.nix { nativeRuntime = self.native-runtime-cpu; };
    mesh-llm-vulkan = self.callPackage ./product.nix {
      pname = "mesh-llm-vulkan";
      nativeRuntime = self.native-runtime-vulkan;
    };
    mesh-llm-cuda = self.callPackage ./product.nix {
      pname = "mesh-llm-cuda";
      nativeRuntime = self.native-runtime-cuda;
    };
    # The variant matching the package set's configuration.
    mesh-llm-default = if config.cudaSupport or false then self.mesh-llm-cuda else self.mesh-llm;

    skippy = self.callPackage ./product.nix {
      pname = "skippy";
      programs = [ "skippy" ];
      nativeRuntime = self.native-runtime-cpu;
    };
  }
)
