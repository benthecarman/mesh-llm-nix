{
  lib,
  rustPlatform,
  cmake,
  perl,
  protobuf,
  nwcWalletSrc,
}:

# The Nostr Wallet Connect wallet.v1 plugin. The host starts it from a
# [[plugin]] entry whose command is this package's binary.
rustPlatform.buildRustPackage {
  pname = "nwc-wallet";
  version = (builtins.fromTOML (builtins.readFile "${nwcWalletSrc}/Cargo.toml")).package.version;

  src = nwcWalletSrc;

  # The mesh-llm SDK is a git dependency pinned by revision in the lock file,
  # so the lock file alone fixes every input.
  cargoLock = {
    lockFile = "${nwcWalletSrc}/Cargo.lock";
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
    "nwc-wallet"
  ];
  # The integration tests need the mesh-llm plugin manager and network relays.
  doCheck = false;

  meta = {
    description = "Nostr Wallet Connect wallet plugin for MeshLLM";
    homepage = "https://github.com/benthecarman/nwc-wallet";
    license = lib.licenses.asl20;
    mainProgram = "nwc-wallet";
  };
}
