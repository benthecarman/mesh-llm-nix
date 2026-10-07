{
  lib,
  stdenvNoCC,
  glibc,
  makeBinaryWrapper,
  mesh-llm-unwrapped,
  meshLlmVersion,
  nativeRuntime,
  pname ? "mesh-llm",
  programs ? [
    "mesh-llm"
    "skippy"
  ],
}:

# A release-shaped product: the host binaries with a native runtime bundle at
# <prefix>/lib/mesh-llm/native-runtimes, where both hosts look for one beside
# their own executable. The binaries are copied, not linked, because the hosts
# resolve that location from their canonical executable path.
#
# The hosts compare a runtime's minimum glibc against `getconf` from PATH,
# which reports the system's glibc rather than the store glibc that the Nix
# build links. The wrapper reports the linked glibc instead. Likewise, the
# hosts look for a CUDA toolkit in the system loader's search path, while a
# Nix CUDA runtime resolves its toolkit libraries through its own RPATH.
let
  wrapperArgs = [
    "--set-default"
    "MESH_LLM_GLIBC_VERSION"
    (lib.versions.majorMinor glibc.version)
  ]
  ++ lib.optionals (nativeRuntime.cudaMajor != null) [
    "--set-default"
    "MESH_LLM_CUDA_TOOLKIT_MAJOR"
    nativeRuntime.cudaMajor
  ];
in
stdenvNoCC.mkDerivation {
  inherit pname;
  version = meshLlmVersion;

  dontUnpack = true;

  nativeBuildInputs = [ makeBinaryWrapper ];
  dontStrip = true;
  dontPatchELF = true;

  installPhase = ''
    runHook preInstall

    for program in ${lib.escapeShellArgs programs}; do
      install -Dm755 "${mesh-llm-unwrapped}/bin/$program" "$out/bin/.$program-wrapped"
      makeBinaryWrapper "$out/bin/.$program-wrapped" "$out/bin/$program" \
        ${lib.escapeShellArgs wrapperArgs}
    done

    # Discovery canonicalizes this root but skips symlinked entries inside it,
    # so link the whole directory rather than the individual runtime.
    mkdir -p "$(dirname "$out/${nativeRuntime.runtimesDir}")"
    ln -s "${nativeRuntime}/${nativeRuntime.runtimesDir}" "$out/${nativeRuntime.runtimesDir}"

    runHook postInstall
  '';

  passthru = {
    inherit mesh-llm-unwrapped nativeRuntime;
  };

  meta = mesh-llm-unwrapped.meta // {
    description = "MeshLLM with the ${nativeRuntime.backend} native runtime";
    mainProgram = lib.head programs;
    platforms = lib.platforms.linux;
  };
}
