{
  stdenvNoCC,
  git,
  meshLlmSrc,
  llamaCppPin,
  llamaCppUpstream,
}:

# Upstream llama.cpp at MeshLLM's pin with the Skippy patch queue applied.
# Mirrors skippy/scripts/prepare-llama.sh: numbered patches first, then the
# model support and generated family series in their listed order.
stdenvNoCC.mkDerivation {
  pname = "llama-cpp-skippy";
  version = builtins.substring 0 12 llamaCppPin;

  src = llamaCppUpstream;

  nativeBuildInputs = [ git ];

  patchDir = "${meshLlmSrc}/skippy/llama_cpp/patches";

  dontConfigure = true;
  # Keep the source exactly as patched; consumers build it.
  dontFixup = true;

  buildPhase = ''
    runHook preBuild

    export HOME="$TMPDIR"
    git_identity=(-c user.name="Mesh-LLM CI" -c user.email="ci@mesh-llm.local")

    patches=()
    while IFS= read -r patch; do
      patches+=("$patch")
    done < <(find "$patchDir" -maxdepth 1 -type f -name '*.patch' | sort)
    for series_dir in model_support generated; do
      series="$patchDir/$series_dir/series"
      [[ -f "$series" ]] || continue
      while IFS= read -r name || [[ -n "$name" ]]; do
        name="''${name%$'\r'}"
        [[ -n "$name" ]] && patches+=("$patchDir/$series_dir/$name")
      done < "$series"
    done
    echo "applying ''${#patches[@]} Skippy patches to llama.cpp $llamaCppPin"

    git init -q
    git add -A
    git "''${git_identity[@]}" commit -q --no-gpg-sign -m "llama.cpp $llamaCppPin"
    git "''${git_identity[@]}" -c core.hooksPath=/dev/null am --3way \
      --committer-date-is-author-date --no-gpg-sign "''${patches[@]}"

    # The digest identifies the patch queue in the runtime manifest.
    for patch in "''${patches[@]}"; do
      printf '%s\n%s\n' "''${patch#"$patchDir"/}" "$(sha256sum "$patch" | cut -d' ' -f1)"
    done | sha256sum | cut -d' ' -f1 > .mesh-llm-patch-digest
    printf '%s\n' "$llamaCppPin" > .mesh-llm-upstream-sha

    rm -rf .git

    runHook postBuild
  '';

  inherit llamaCppPin;

  installPhase = ''
    runHook preInstall
    cp -r . "$out"
    runHook postInstall
  '';
}
