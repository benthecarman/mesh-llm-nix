{
  lib,
  rustPlatform,
  protobuf,
  openaiEndpointSrc,
}:

# The external OpenAI-compatible endpoint plugin. The host starts it from a
# [[plugin]] entry whose command is this package's binary and whose url is
# the endpoint's HTTP base URL.
rustPlatform.buildRustPackage {
  pname = "openai-endpoint";
  version =
    (builtins.fromTOML (builtins.readFile "${openaiEndpointSrc}/Cargo.toml")).package.version;

  src = openaiEndpointSrc;

  # The mesh-llm SDK is a git dependency pinned by revision in the lock file,
  # so the lock file alone fixes every input.
  cargoLock = {
    lockFile = "${openaiEndpointSrc}/Cargo.lock";
    allowBuiltinFetchGit = true;
  };

  # The mesh-llm SDK's build scripts run a prebuilt protoc that cannot run on
  # NixOS. Vendored git crates carry no file checksums, so patch them in place.
  postPatch = ''
    for buildScript in $(grep -l protoc_bin_vendored "$cargoDepsCopy"/*/build.rs); do
      substituteInPlace "$buildScript" \
        --replace-fail 'protoc_bin_vendored::protoc_bin_path().expect("vendored protoc")' \
          'std::path::PathBuf::from("${lib.getExe' protobuf "protoc"}")'
    done
  '';

  # The tests start a mesh-llm host.
  doCheck = false;

  meta = {
    description = "External OpenAI-compatible endpoint plugin for MeshLLM";
    homepage = "https://github.com/Mesh-LLM/openai-endpoint";
    license = lib.licenses.asl20;
    mainProgram = "openai-endpoint";
  };
}
