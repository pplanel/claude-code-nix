# Claude Code's native binary at the version pinned in manifest.json
# (update.sh bumps it). Modeled on nixpkgs' pkgs/by-name/cl/claude-code, but
# pinned here so we choose when to move, and fetching the plain binary.
{
  lib,
  stdenvNoCC,
  fetchurl,
  makeBinaryWrapper,
  procps,
  ripgrep,
  versionCheckHook,
  writableTmpDirAsHomeHook,
  manifest ? lib.importJSON ./manifest.json,
}: let
  baseUrl = "https://downloads.claude.ai/claude-code-releases";
  platform = stdenvNoCC.hostPlatform;
  platformKey = "${platform.node.platform}-${platform.node.arch}";
  entry = manifest.platforms.${platformKey} or (throw "claude-code: no ${platformKey} in manifest.json");
in
  stdenvNoCC.mkDerivation (finalAttrs: {
    pname = "claude-code";
    inherit (manifest) version;

    src = fetchurl {
      url = "${baseUrl}/${finalAttrs.version}/${platformKey}/${entry.binary}";
      sha256 = entry.checksum;
    };

    dontUnpack = true;
    dontBuild = true;
    # Stripping leaves the bun runtime without the bundled program.
    dontStrip = true;

    nativeBuildInputs = [makeBinaryWrapper];

    installPhase = ''
      runHook preInstall
      install -Dm755 $src $out/bin/claude
      wrapProgram $out/bin/claude \
        --set DISABLE_AUTOUPDATER 1 \
        --set DISABLE_INSTALLATION_CHECKS 1 \
        --set USE_BUILTIN_RIPGREP 0 \
        --set-default DISABLE_TELEMETRY 1 \
        --set-default DISABLE_ERROR_REPORTING 1 \
        --set-default DISABLE_FEEDBACK_COMMAND 1 \
        --set-default CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY 1 \
        --set-default CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC 1 \
        --prefix PATH : ${lib.makeBinPath [procps ripgrep]}
      runHook postInstall
    '';

    doInstallCheck = true;
    nativeInstallCheckInputs = [writableTmpDirAsHomeHook versionCheckHook];
    versionCheckKeepEnvironment = ["HOME"];
    versionCheckProgramArg = "--version";

    passthru.manifest = manifest;

    meta = {
      description = "Claude Code, Anthropic's agentic coding CLI (native binary, pinned)";
      homepage = "https://code.claude.com";
      license = lib.licenses.unfree;
      sourceProvenance = [lib.sourceTypes.binaryNativeCode];
      platforms = ["aarch64-darwin" "aarch64-linux" "x86_64-linux"];
      mainProgram = "claude";
    };
  })
