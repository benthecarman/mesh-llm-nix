{
  lib,
  rustPlatform,
  cmake,
  perl,
  protobuf,
  ldkServerWalletSrc,
}:

# The LDK Server wallet.v1 plugin. The host starts it from a
# [[plugin]] entry whose command is this package's binary.
rustPlatform.buildRustPackage {
  pname = "ldk-server-wallet";
  version =
    (builtins.fromTOML (builtins.readFile "${ldkServerWalletSrc}/Cargo.toml")).package.version;

  src = ldkServerWalletSrc;

  # The mesh-llm SDK and ldk-server-client are git dependencies pinned by
  # revision in the lock file, so the lock file alone fixes every input.
  cargoLock = {
    lockFile = "${ldkServerWalletSrc}/Cargo.lock";
    allowBuiltinFetchGit = true;
  };

  nativeBuildInputs = [
    cmake # aws-lc-sys
    perl
  ];
  dontUseCmakeConfigure = true;

  # The mesh-llm SDK's build scripts run a prebuilt protoc that cannot run on
  # NixOS. Vendored git crates carry no file checksums, so patch them in place.
  postPatch = ''
    for buildScript in $(grep -l protoc_bin_vendored "$cargoDepsCopy"/*/build.rs); do
      substituteInPlace "$buildScript" \
        --replace-fail 'protoc_bin_vendored::protoc_bin_path().expect("vendored protoc")' \
          'std::path::PathBuf::from("${lib.getExe' protobuf "protoc"}")'
    done
  '';

  cargoBuildFlags = [
    "--bin"
    "ldk-server-wallet"
  ];
  # The integration tests need the mesh-llm plugin manager.
  doCheck = false;

  meta = {
    description = "LDK Server wallet plugin for MeshLLM";
    homepage = "https://github.com/benthecarman/ldk-server-wallet";
    license = lib.licenses.asl20;
    mainProgram = "ldk-server-wallet";
  };
}
