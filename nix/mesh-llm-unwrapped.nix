{
  lib,
  rustPlatform,
  cmake,
  perl,
  pkg-config,
  protobuf,
  meshLlmSrc,
  meshLlmVersion,
  meshLlmBuildVersion,
  mesh-llm-ui,
}:

# The backend-neutral MeshLLM host and the standalone Skippy server. Neither
# links llama.cpp; both load a native runtime bundle at startup.
rustPlatform.buildRustPackage {
  pname = "mesh-llm-unwrapped";
  version = meshLlmVersion;

  src = meshLlmSrc;

  # Dependencies follow the source's own lock file, so new source pins need
  # no hash update here.
  cargoLock.lockFile = "${meshLlmSrc}/Cargo.lock";

  nativeBuildInputs = [
    cmake # aws-lc-sys
    perl
    pkg-config
  ];
  dontUseCmakeConfigure = true;

  postPatch = ''
    # The repository config adds an sccache wrapper and linker probes that
    # do not apply inside the Nix sandbox.
    rm .cargo/config.toml

    # protoc-bin-vendored ships a prebuilt binary that cannot run on NixOS.
    for buildScript in mesh/crates/mesh-llm-plugin/build.rs skippy/crates/skippy-protocol/build.rs; do
      substituteInPlace "$buildScript" \
        --replace-fail 'protoc_bin_vendored::protoc_bin_path().expect("vendored protoc")' \
          'std::path::PathBuf::from("${lib.getExe' protobuf "protoc"}")'
    done

    cp -r ${mesh-llm-ui} mesh/crates/mesh-llm-ui/dist
  '';

  env.MESH_LLM_BUILD_VERSION = meshLlmBuildVersion;

  # Same features as scripts/build-host.sh and the skippy-cli recipes.
  cargoBuildFlags = [
    "-p"
    "mesh-llm"
    "--bin"
    "mesh-llm"
    "-p"
    "skippy-cli"
    "--bin"
    "skippy"
    "--features"
    "mesh-llm/web-ui,mesh-llm/dynamic-native-runtime,mesh-llm/payments,skippy-cli/dynamic-native-runtime"
  ];

  # The workspace test suites need models, networking, and native runtimes.
  doCheck = false;

  meta = {
    description = "MeshLLM host and Skippy server without a bundled native runtime";
    homepage = "https://github.com/Mesh-LLM/mesh-llm";
    license = lib.licenses.mit;
    mainProgram = "mesh-llm";
  };
}
