# mesh-llm-nix

Nix packages and a NixOS service module for
[MeshLLM](https://github.com/Mesh-LLM/mesh-llm) and its standalone Skippy
server.

This repository has only the packaging. Nix fetches the MeshLLM source
from the `mesh-llm-src` flake input. You can point that input at any MeshLLM
commit, and the rest of the build follows the source:

- Rust dependencies come from the source's `Cargo.lock`.
- The llama.cpp revision comes from `skippy/llama_cpp/upstream.txt`, and the
  Skippy patch queue comes from `skippy/llama_cpp/patches`.
- The version comes from the workspace `Cargo.toml`.

The console's pnpm dependencies are the only input that needs a hash. See
[Console dependency hash](#console-dependency-hash).

The packages build on `x86_64-linux` and `aarch64-linux`. Enable the
`nix-command` and `flakes` experimental features before you use the commands
below.

## Packages

| Package | Contents |
|---|---|
| `mesh-llm` (default) | `mesh-llm` and `skippy` with the CPU native runtime |
| `mesh-llm-cuda` | `mesh-llm` and `skippy` with the CUDA native runtime (unfree) |
| `mesh-llm-vulkan` | `mesh-llm` and `skippy` with the Vulkan native runtime |
| `skippy` | `skippy` alone, with the CPU native runtime |
| `mesh-llm-unwrapped` | The host binaries without a native runtime |
| `native-runtime-{cpu,cuda,vulkan}` | One native runtime bundle each |
| `mesh-llm-ui` | The built web console that is embedded in `mesh-llm` |
| `llama-cpp-skippy` | llama.cpp source with the Skippy patches applied |
| `nwc-wallet` | The [Nostr Wallet Connect wallet plugin](https://github.com/benthecarman/nwc-wallet) |

MeshLLM loads its inference engine from a separate native runtime: patched
llama.cpp shared libraries and a `manifest.json`. Upstream release archives
put it next to the binary. These packages put it in
`$out/lib/mesh-llm/native-runtimes`, which the binaries search by default.
Because of this, MeshLLM does not download a runtime at startup.

## Run without installing

```bash
nix run github:benthecarman/mesh-llm-nix -- serve --model Qwen3-8B-Q4_K_M
nix run github:benthecarman/mesh-llm-nix#mesh-llm-cuda -- serve --model Qwen3-8B-Q4_K_M
```

The CUDA package compiles kernels for each architecture in Nixpkgs'
`cudaCapabilities`. To build fewer architectures, which is much faster, see
[Override the build](#override-the-build).

## Choose the MeshLLM source

### From the command line

```bash
nix build .#mesh-llm --override-input mesh-llm-src github:Mesh-LLM/mesh-llm/<rev>
nix build .#mesh-llm --override-input mesh-llm-src path:/home/me/src/mesh-llm
```

To move this repository's own pin to the latest upstream `main`:

```bash
nix flake update mesh-llm-src
```

### From another flake

Declare your own source input and make this flake follow it:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    mesh-llm-src = {
      url = "github:Mesh-LLM/mesh-llm/<rev>";
      flake = false;
    };
    mesh-llm-nix = {
      url = "github:benthecarman/mesh-llm-nix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.mesh-llm-src.follows = "mesh-llm-src";
    };
  };
}
```

`nix flake update mesh-llm-src` in your flake then moves the pin, and
`mesh-llm-nix.packages` and `mesh-llm-nix.nixosModules` build from it.

### From Nix code

`lib.mkPackages` builds the package set from any source tree:

```nix
mesh-llm-nix.lib.mkPackages {
  inherit pkgs;
  src = pkgs.fetchFromGitHub {
    owner = "Mesh-LLM";
    repo = "mesh-llm";
    rev = "<rev>";
    hash = "<hash>";
  };
  rev = "<rev>"; # optional: adds +g<SHA> to the reported version
  uiPnpmDepsHash = "<hash>"; # only for a console lock file not in this repository
}
```

### Console dependency hash

Nix must know the hash of the console's pnpm dependencies in advance.
`nix/ui-pnpm-deps.json` maps the sha256 of each known
`mesh/crates/mesh-llm-ui/pnpm-lock.yaml` to its dependency hash, so a new pin
needs no hash when its console lock file is unchanged.

When the lock file is new, evaluation prints a warning and the
`mesh-llm-ui-pnpm-deps` build fails with the correct hash:

```text
error: hash mismatch in fixed-output derivation '...-mesh-llm-ui-pnpm-deps.drv':
         specified: sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
            got:    sha256-...
```

Pass the `got:` value as `uiPnpmDepsHash`, or add an entry to
`nix/ui-pnpm-deps.json`. The warning shows the key for that entry.

## Deploy on NixOS

```nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.mesh-llm-nix.url = "github:benthecarman/mesh-llm-nix";

  outputs = { nixpkgs, mesh-llm-nix, ... }: {
    nixosConfigurations.my-host = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        mesh-llm-nix.nixosModules.default
        ({ pkgs, ... }: {
          services.mesh-llm = {
            enable = true;
            # Defaults to the CUDA variant when nixpkgs.config.cudaSupport is set.
            package = mesh-llm-nix.packages.${pkgs.stdenv.hostPlatform.system}.mesh-llm-cuda;
            settings.models = [ { model = "Qwen3-8B-Q4_K_M"; } ];
            extraArgs = [ "--publish" ];
            joinFile = "/run/secrets/mesh-llm-invite";
          };
        })
      ];
    };
  };
}
```

Declare startup models in `settings.models`, not with `--model` in
`extraArgs`. A catalog model given on the command line is served under a
content hash such as `local-gguf/sha256-…`; a configured model keeps its
public catalog ID, which is also the name peers see and prices use.

The service runs `mesh-llm serve` as the `mesh-llm` system user. Its home is
`/var/lib/mesh-llm`, so the configuration, node identity, and model cache are
below that directory. Options:

| Option | Default | Description |
|---|---|---|
| `package` | CPU or CUDA variant | The variant decides the inference backend |
| `settings` | `{ }` | Generates `~/.mesh-llm/config.toml`; when set, the file is replaced on every start |
| `logFormat` | `"json"` | One JSON event per journal line; `"pretty"` redraws status panels |
| `port` / `consolePort` | `9337` / `3131` | OpenAI-compatible API and management console |
| `listenAll` | `false` | Bind the API and console on all interfaces |
| `bindPort` | `null` | Fixed UDP port for mesh QUIC traffic |
| `joinFile` | `null` | File with a mesh invite token, reread on every rejoin |
| `environmentFiles` | `[ ]` | systemd environment files, for example with `HF_TOKEN` |
| `extraArgs` | `[ ]` | More `mesh-llm serve` arguments |
| `extraPackages` | `nvidia-smi` when the NVIDIA driver is enabled | Packages on the service's `PATH` |
| `openFirewall` | `false` | Open the TCP ports, and `bindPort` for UDP |
| `dataDir`, `user`, `group` | `/var/lib/mesh-llm`, `mesh-llm` | Service account and state |

For CUDA, the host needs the NVIDIA driver (`hardware.nvidia`) so that
`/run/opengl-driver/lib` has `libcuda.so`. The CUDA runtime finds the driver
there. MeshLLM uses `nvidia-smi` to find the GPUs and their compute
capability, so `extraPackages` puts the driver's `nvidia-smi` on the service's
`PATH` when `services.xserver.videoDrivers` contains `"nvidia"`.

## Plugins and wallets

MeshLLM starts each plugin as a separate process from a `[[plugin]]` entry in
its configuration. The entry's `command` can be a store path, so a packaged
plugin needs no `mesh-llm plugins install`. Paid inference uses a `wallet.v1`
plugin and works on mainnet only.

For example, to use the NWC wallet with the URI in a root-managed secret file
owned by the service user:

```nix
services.mesh-llm.settings = {
  plugin = [
    {
      name = "nwc-wallet";
      command = lib.getExe mesh-llm-nix.packages.${system}.nwc-wallet;
      args = [ "--uri-file" "/run/secrets/mesh-llm-nwc-uri" ];
    }
  ];
  payments.wallet = "nwc-wallet";
};
```

The URI is a spending credential. Keep it out of the Nix store, and make the
file readable only by the service user. Prices and spending policy are not
configuration; set them on the running node with `mesh-llm wallet pricing`
and `mesh-llm wallet policy`. The ledger is in
`/var/lib/mesh-llm/.mesh-llm/payments`.

To build the plugin from another revision, override the `nwc-wallet-src`
input like `mesh-llm-src`, or pass `nwcWalletSrc` to `lib.mkPackages`.

## Override the build

Every package is a normal derivation in a `lib.makeScope` set, so you can use
`override` and `overrideScope`. For example, to build CUDA kernels only for
RTX 5090 (sm_120) and RTX 3090 (sm_86):

```nix
let
  meshPkgs = mesh-llm-nix.lib.mkPackages { inherit pkgs; };
in
meshPkgs.mesh-llm-cuda.override {
  nativeRuntime = meshPkgs.native-runtime-cuda.override { cudaArchitectures = "86;120"; };
}
```

`pkgs` must allow unfree packages for CUDA. `native-runtime.nix` also accepts
`extraCmakeFlags` for llama.cpp.

## Notes

- The `bin/mesh-llm` and `bin/skippy` wrappers set two environment defaults.
  MeshLLM selects a runtime by checking the host's glibc and CUDA toolkit, but
  its probes see the system's libraries, not the Nix store libraries that
  these binaries and runtimes use:
  - `MESH_LLM_GLIBC_VERSION` is the glibc that the binaries link against.
  - `MESH_LLM_CUDA_TOOLKIT_MAJOR` (CUDA variant only) is the toolkit that the
    runtime loads through its RPATH.

- `mesh-llm update` and `--auto-update` replace release-archive installs only.
  They do not change a Nix store path. Use a new pin to upgrade.
- The runtime bundles do not include `skippy-package-builder`. MeshLLM does
  not use it at run time.

## License

The packaging in this repository is licensed under the Apache License,
Version 2.0. See [LICENSE](LICENSE). MeshLLM itself is MIT-licensed upstream.
