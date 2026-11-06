{
  lib,
  buildNpmPackage,
  nodejs_22,
  makeWrapper,
  bash,
  cacert,
  coreutils,
  ffmpeg-headless,
  fetchPypi,
  openssl,
  python3,
  util-linux,
}:

let
  tpLinkCloudApi = python3.pkgs.buildPythonPackage rec {
    pname = "tplink-cloud-api";
    version = "5.2.2";
    pyproject = true;
    src = fetchPypi {
      pname = "tplink_cloud_api";
      inherit version;
      hash = "sha256-54zjJ7U6GBDvzeMIUt1NGdWv3fJy9msSOvbI1Vuvk7Q=";
    };
    build-system = [ python3.pkgs.setuptools ];
    dependencies = with python3.pkgs; [
      requests
      aiohttp
    ];
    pythonImportsCheck = [
      "tplinkcloud.certs"
      "tplinkcloud.signing"
    ];
  };
  loginPython = python3.withPackages (_: [ tpLinkCloudApi ]);
in
buildNpmPackage {
  pname = "tapo-motion-recorder";
  version = "0.1.0";
  nodejs = nodejs_22;

  # Camera credentials, recordings and developer artifacts must never enter
  # the Nix store, where files are readable by other users on the system.
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./LICENSE
      ./THIRD-PARTY-NOTICES
      ./package.json
      ./package-lock.json
      ./install.sh
      ./src/cli.cjs
      ./src/media.cjs
      ./src/record.cjs
      ./watch_detection.py
      ./scripts/install-credentials.py
      ./scripts/tapo-login.py
    ];
  };

  npmDepsHash = "sha256-lhM7Q4nxhN3+2o1NKW2MrxjexUpSJd/+lSUoU4WnNAI=";
  npmFlags = [ "--ignore-scripts" ];
  npmInstallFlags = [ "--omit=dev" ];
  dontNpmBuild = true;
  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall

    app="$out/lib/tapo-motion-recorder"
    mkdir -p "$app" "$out/bin"
    cp -r src scripts node_modules watch_detection.py install.sh "$app/"
    mkdir -p "$out/share/doc/tapo-motion-recorder"
    cp LICENSE THIRD-PARTY-NOTICES "$out/share/doc/tapo-motion-recorder/"
    makeWrapper ${nodejs_22}/bin/node "$out/bin/tapo-motion-recorder" \
      --add-flags "$app/src/cli.cjs" \
      --prefix PATH : "${lib.makeBinPath [ ffmpeg-headless openssl python3 ]}"
    makeWrapper ${python3}/bin/python3 "$out/bin/tapo-install-credentials" \
      --add-flags "$app/scripts/install-credentials.py"
    makeWrapper ${loginPython}/bin/python3 "$out/bin/tapo-login" \
      --add-flags "$app/scripts/tapo-login.py" \
      --prefix PATH : "${lib.makeBinPath [ openssl ]}" \
      --set-default SSL_CERT_FILE "${cacert}/etc/ssl/certs/ca-bundle.crt"
    makeWrapper ${bash}/bin/bash "$out/bin/tapo-install" \
      --add-flags "$app/install.sh" \
      --set TAPO_INSTALL_PACKAGE "$out" \
      --prefix PATH : "${lib.makeBinPath [ coreutils util-linux python3 ]}"

    runHook postInstall
  '';

  meta = {
    description = "Record Tapo motion clips on the local network";
    mainProgram = "tapo-motion-recorder";
    platforms = lib.platforms.linux;
  };
}
