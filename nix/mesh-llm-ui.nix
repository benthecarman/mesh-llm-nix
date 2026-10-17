{
  stdenvNoCC,
  fetchPnpmDeps,
  nodejs_24,
  pnpm_10,
  # nixos-26.05 marks its pnpm_10 (10.34.0) insecure and ships the fixed
  # release as pnpm_10_latest; nixos-unstable's pnpm_10 is already fixed.
  pnpm_10_latest ? pnpm_10,
  pnpmConfigHook,
  meshLlmSrc,
  meshLlmVersion,
  uiPnpmDepsHash,
}:

# The React console embedded in the mesh-llm binary (mesh/scripts/build-ui.sh).
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "mesh-llm-ui";
  version = meshLlmVersion;

  src = "${meshLlmSrc}/mesh/crates/mesh-llm-ui";

  nativeBuildInputs = [
    nodejs_24
    pnpm_10_latest
    pnpmConfigHook
  ];

  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs) pname version src;
    pnpm = pnpm_10_latest;
    fetcherVersion = 3;
    hash = uiPnpmDepsHash;
  };

  env = {
    # Release builds hide the console's debug surfaces.
    VITE_MESH_LLM_DEBUG_UI = "false";
    ONNXRUNTIME_NODE_INSTALL_CUDA = "skip";
  };

  buildPhase = ''
    runHook preBuild
    pnpm run build
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    cp -r dist "$out"
    runHook postInstall
  '';
})
