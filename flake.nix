{
  description = "T3 Code - desktop app by Theo (pingdotgg), stable and nightly channels";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      sources = builtins.fromJSON (builtins.readFile ./sources.json);
      releaseUrl = version: name:
        "https://github.com/pingdotgg/t3code/releases/download/v${version}/${name}";
    in
    flake-utils.lib.eachSystem supportedSystems (system:
      let
        pkgs = import nixpkgs { inherit system; };

        # `pname` doubles as the executable, desktop-entry and icon name, so the
        # stable and nightly packages can be installed into the same profile.
        mkPackage = { channel, pname }:
          let
            source = sources.channels.${channel}
              or (throw "t3code: unknown channel ${channel}");
            version = source.version;
            asset = source.assets.${system}
              or (throw "t3code: unsupported system ${system}");
            src = pkgs.fetchurl {
              url = releaseUrl version asset.name;
              sha256 = asset.sha256;
            };

            meta = {
              description = "T3 Code desktop app"
                + (if channel == "stable" then "" else " (${channel} build)");
              homepage = "https://t3.codes";
              mainProgram = pname;
            };

            linuxPackage =
              let
                contents = pkgs.appimageTools.extract {
                  inherit pname src version;
                };
              in
              pkgs.appimageTools.wrapType2 {
                inherit pname src version;

                extraPkgs = p: with p; [ libsecret libgcrypt libnotify ];

                extraInstallCommands = ''
                  icon=""
                  desktopFile=$(find ${contents} -maxdepth 2 -name '*.desktop' | head -n1)
                  if [ -n "$desktopFile" ]; then
                    install -Dm444 "$desktopFile" \
                      "$out/share/applications/${pname}.desktop"
                    icon=$(sed -n 's/^Icon=//p' "$desktopFile" | head -n1)
                    substituteInPlace "$out/share/applications/${pname}.desktop" \
                      --replace-quiet 'Exec=AppRun' "Exec=$out/bin/${pname}"
                    if [ -n "$icon" ]; then
                      substituteInPlace "$out/share/applications/${pname}.desktop" \
                        --replace-quiet "Icon=$icon" "Icon=${pname}"
                    fi
                  fi
                  if [ -d ${contents}/usr/share/icons ]; then
                    cp -r ${contents}/usr/share/icons $out/share/
                    # cp preserves the store's read-only dir modes, which would
                    # block the icon rename below.
                    chmod -R u+w $out/share/icons
                  fi
                  for png in ${contents}/*.png; do
                    [ -f "$png" ] && install -Dm444 "$png" \
                      "$out/share/pixmaps/$(basename "$png")"
                  done
                  # Rename icon files to match pname, so that installing both
                  # channels does not collide on share/icons and share/pixmaps.
                  if [ -n "$icon" ] && [ "$icon" != "${pname}" ]; then
                    find "$out/share" -type f -name "$icon.*" | while read -r f; do
                      mv "$f" "$(dirname "$f")/${pname}.''${f##*.}"
                    done
                  fi
                '';

                meta = meta // { platforms = [ "x86_64-linux" ]; };
              };

            darwinPackage = pkgs.stdenvNoCC.mkDerivation {
              inherit pname version src;

              nativeBuildInputs = [ pkgs.unzip ];

              sourceRoot = ".";

              dontConfigure = true;
              dontBuild = true;
              dontFixup = true;

              unpackPhase = ''
                runHook preUnpack
                mkdir -p extracted
                unzip -q $src -d extracted
                runHook postUnpack
              '';

              # Upstream names the bundles distinctly per channel
              # ("T3 Code (Alpha).app" vs "T3 Code (Nightly).app"), so only the
              # $out/bin symlink needs the pname treatment.
              installPhase = ''
                runHook preInstall
                mkdir -p "$out/Applications"
                appBundle=$(find extracted -maxdepth 2 -name "*.app" -print -quit)
                if [ -z "$appBundle" ]; then
                  echo "error: no .app bundle found in zip"
                  exit 1
                fi
                cp -R "$appBundle" "$out/Applications/"
                bundleName=$(basename "$appBundle")
                binary=$(find "$out/Applications/$bundleName/Contents/MacOS" -maxdepth 1 -type f -perm -u+x | head -n 1)
                if [ -n "$binary" ]; then
                  mkdir -p "$out/bin"
                  ln -s "$binary" "$out/bin/${pname}"
                fi
                runHook postInstall
              '';

              meta = meta // {
                platforms = [ "aarch64-darwin" "x86_64-darwin" ];
              };
            };
          in
          if pkgs.stdenv.isDarwin then darwinPackage else linuxPackage;

        t3code = mkPackage {
          channel = "stable";
          pname = "t3code";
        };
        t3code-nightly = mkPackage {
          channel = "nightly";
          pname = "t3code-nightly";
        };
      in
      {
        packages = {
          inherit t3code t3code-nightly;
          default = t3code;
        };

        apps = {
          default = {
            type = "app";
            program = "${t3code}/bin/t3code";
          };
          t3code = {
            type = "app";
            program = "${t3code}/bin/t3code";
          };
          t3code-nightly = {
            type = "app";
            program = "${t3code-nightly}/bin/t3code-nightly";
          };
        };

        formatter = pkgs.nixpkgs-fmt;
      });
}
