{
  lib,
  stdenv,
  addDriverRunpath,
  cmake,
  cudaPackages,
  ninja,
  patchelf,
  python3,
  shaderc,
  spirv-headers,
  vulkan-headers,
  vulkan-loader,
  llama-cpp-skippy,
  meshLlmSrc,
  backend ? "cpu",
  # CUDA: a CMake architecture list such as "86;120". Defaults to the
  # package set's cudaCapabilities.
  cudaArchitectures ? cudaPackages.flags.cmakeCudaArchitecturesString,
  extraCmakeFlags ? [ ],
}:

assert lib.elem backend [
  "cpu"
  "cuda"
  "vulkan"
];

let
  isCuda = backend == "cuda";
  isVulkan = backend == "vulkan";
  effectiveStdenv = if isCuda then cudaPackages.backendStdenv else stdenv;
  hostPlatform = effectiveStdenv.hostPlatform;

  releaseVersion = lib.trim (
    builtins.readFile "${meshLlmSrc}/skippy/crates/skippy-native-runtime/RUNTIME_VERSION"
  );
  arch = hostPlatform.parsed.cpu.name;
  target = "${arch}-unknown-linux-gnu";
  platform = "linux-${arch}";
  flavor = if isCuda then "cuda${cudaPackages.cudaMajorVersion}" else backend;
  runtimeId = "meshllm-native-runtime-${platform}-${flavor}";

  # nvcc flags for cudaArchitectures, in CMAKE_CUDA_ARCHITECTURES syntax.
  # Without them nvcc embeds only PTX for its default architecture, which a
  # driver older than the toolkit cannot JIT-compile.
  cudaGencodeFlags = lib.concatMap (
    arch:
    let
      real = lib.removeSuffix "-real" arch;
      virtual = lib.removeSuffix "-virtual" arch;
    in
    if arch == "" then
      [ ]
    else if lib.elem arch [
      "native"
      "all"
      "all-major"
    ] then
      [ "-arch=${arch}" ]
    else if real != arch then
      [ "--generate-code=arch=compute_${real},code=sm_${real}" ]
    else if virtual != arch then
      [ "--generate-code=arch=compute_${virtual},code=compute_${virtual}" ]
    else
      [ "--generate-code=arch=compute_${arch},code=[compute_${arch},sm_${arch}]" ]
  ) (lib.splitString ";" cudaArchitectures);
in
effectiveStdenv.mkDerivation {
  pname = "mesh-llm-native-runtime-${flavor}";
  version = releaseVersion;

  src = llama-cpp-skippy;

  nativeBuildInputs = [
    cmake
    ninja
    patchelf
    python3
  ]
  ++ lib.optionals isCuda [ cudaPackages.cuda_nvcc ]
  ++ lib.optionals isVulkan [ shaderc ];

  buildInputs =
    lib.optionals isCuda (
      with cudaPackages;
      [
        cuda_cccl
        cuda_cudart
        libcublas
      ]
    )
    ++ lib.optionals isVulkan [
      spirv-headers
      vulkan-headers
      vulkan-loader
    ];

  # The source has no .git, so record the pin in llama.cpp's build info.
  postPatch = ''
    substituteInPlace cmake/build-info.cmake \
      --replace-fail 'set(BUILD_COMMIT "unknown")' \
        'set(BUILD_COMMIT "${builtins.substring 0 7 llama-cpp-skippy.llamaCppPin}")'
  '';

  # Matches skippy/scripts/build-llama.sh for LLAMA_STAGE_LINK_MODE=dynamic.
  cmakeFlags = [
    (lib.cmakeBool "BUILD_SHARED_LIBS" true)
    (lib.cmakeBool "GGML_NATIVE" false)
    (lib.cmakeBool "GGML_CCACHE" false)
    (lib.cmakeBool "LLAMA_OPENSSL" false)
    (lib.cmakeBool "LLAMA_CURL" false)
    (lib.cmakeBool "LLAMA_BUILD_EXAMPLES" false)
    (lib.cmakeBool "LLAMA_BUILD_SERVER" false)
    (lib.cmakeBool "LLAMA_BUILD_TESTS" false)
    (lib.cmakeBool "LLAMA_STAGE_BUILD_TESTS" false)
    (lib.cmakeBool "CMAKE_POSITION_INDEPENDENT_CODE" true)
    (lib.cmakeBool "MTMD_VIDEO" false)
    (lib.cmakeBool "GGML_METAL" false)
  ]
  ++ lib.optionals isCuda [
    (lib.cmakeBool "GGML_CUDA" true)
    # Upstream keeps staged runtimes off the CUDA graph path.
    (lib.cmakeBool "GGML_CUDA_GRAPHS" false)
    (lib.cmakeFeature "CMAKE_CUDA_ARCHITECTURES" cudaArchitectures)
  ]
  ++ lib.optionals isVulkan [ (lib.cmakeBool "GGML_VULKAN" true) ]
  ++ extraCmakeFlags;

  buildPhase = ''
    runHook preBuild
    cmake --build . --parallel "$NIX_BUILD_CORES" --target llama llama-common mtmd
    runHook postBuild
  '';

  # Library and tool contents are checksummed into manifest.json during
  # installation; later fixup must not rewrite them.
  dontStrip = true;
  dontPatchELF = true;

  installPhase = ''
    runHook preInstall

    buildDir="$PWD"
    runtimeDir="$out/lib/mesh-llm/native-runtimes/${runtimeId}"
    mkdir -p "$runtimeDir/lib"

    # Same selection and order as package-native-runtime.sh: every built
    # shared library sorted by path, with libllama.so last.
    libraries=()
    primary=""
    while IFS= read -r library; do
      name="$(basename "$library")"
      if [[ "$name" == libllama.so ]]; then
        primary="$library"
      else
        libraries+=("$library")
      fi
    done < <(find "$buildDir" \( -type f -o -type l \) -name '*.so*' ! -path '*/CMakeFiles/*' | sort)
    if [[ -z "$primary" ]]; then
      echo "libllama.so was not built" >&2
      exit 1
    fi
    libraries+=("$primary")

    libraryArgs=()
    for library in "''${libraries[@]}"; do
      name="$(basename "$library")"
      cp -P "$library" "$runtimeDir/lib/$name"
      libraryArgs+=(--library "lib/$name")
    done

    # Resolve siblings from the bundle and everything else from the store.
    # CUDA's link-time driver stub must never win over the real driver.
    fixRpath() {
      local file="$1" origin="$2" old entry
      local -a keep=("$origin" ${lib.optionalString isCuda ''"${addDriverRunpath.driverLink}/lib"''})
      old="$(patchelf --print-rpath "$file")"
      IFS=: read -r -a entries <<< "$old"
      for entry in "''${entries[@]}"; do
        [[ "$entry" == "$NIX_STORE"/* && "$entry" != */stubs && "$entry" != "$out"/* ]] && keep+=("$entry")
      done
      patchelf --set-rpath "$(IFS=:; echo "''${keep[*]}")" "$file"
    }
    for library in "$runtimeDir"/lib/*; do
      [[ -L "$library" ]] || fixRpath "$library" '$ORIGIN'
    done

    toolArgs=()
    ${lib.optionalString isCuda ''
      mkdir -p "$runtimeDir/tools"
      nvcc -O3 -std=c++17 -cudart shared ${lib.escapeShellArgs cudaGencodeFlags} \
        "${meshLlmSrc}/skippy/crates/skippy-gpu-bench/native/cuda/membench-fingerprint.cu" \
        -o "$runtimeDir/tools/mesh-llm-gpu-benchmark"
      fixRpath "$runtimeDir/tools/mesh-llm-gpu-benchmark" '$ORIGIN/../lib'
      toolArgs+=(--tool tools/mesh-llm-gpu-benchmark)
    ''}

    python3 ${./write-runtime-manifest.py} \
      --root "$runtimeDir" \
      --id ${runtimeId} \
      --release-version ${releaseVersion} \
      --ffi-lib-rs "${meshLlmSrc}/skippy/crates/skippy-ffi/src/lib.rs" \
      --os linux \
      --arch ${arch} \
      --target ${target} \
      --platform ${platform} \
      --backend ${backend} \
      ${lib.optionalString isCuda ''
        --cuda-major ${cudaPackages.cudaMajorVersion} \
        --cuda-arches "${cudaArchitectures}" \
      ''} \
      --primary-library "lib/libllama.so" \
      "''${libraryArgs[@]}" \
      "''${toolArgs[@]}" \
      --llama-upstream-sha "$(cat "$src/.mesh-llm-upstream-sha")" \
      --llama-patch-digest "$(cat "$src/.mesh-llm-patch-digest")"

    runHook postInstall
  '';

  passthru = {
    inherit backend runtimeId releaseVersion;
    cudaMajor = if isCuda then cudaPackages.cudaMajorVersion else null;
    runtimesDir = "lib/mesh-llm/native-runtimes";
  };

  meta = {
    description = "MeshLLM ${flavor} native runtime (patched llama.cpp with the Skippy ABI)";
    homepage = "https://github.com/Mesh-LLM/mesh-llm";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
