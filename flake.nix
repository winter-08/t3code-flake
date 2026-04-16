{
  description = "T3 Code - a fork of VS Code by Theo (pingdotgg)";

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
      releaseUrl = name:
        "https://github.com/pingdotgg/t3code/releases/download/v${sources.version}/${name}";
    in
    flake-utils.lib.eachSystem supportedSystems (system:
      let
        pkgs = import nixpkgs { inherit system; };
        asset = sources.assets.${system} or (throw "t3code: unsupported system ${system}");
        src = pkgs.fetchurl {
          url = releaseUrl asset.name;
          sha256 = asset.sha256;
        };

        linuxPackage =
          let
            pname = "t3code";
            contents = pkgs.appimageTools.extract {
              inherit pname src;
              version = sources.version;
            };
          in
          pkgs.appimageTools.wrapType2 {
            inherit pname src;
            version = sources.version;

            extraPkgs = p: with p; [ libsecret libgcrypt libnotify ];

            extraInstallCommands = ''
              desktopFile=$(find ${contents} -maxdepth 2 -name '*.desktop' | head -n1)
              if [ -n "$desktopFile" ]; then
                install -Dm444 "$desktopFile" \
                  "$out/share/applications/$(basename "$desktopFile")"
                substituteInPlace "$out/share/applications/$(basename "$desktopFile")" \
                  --replace-quiet 'Exec=AppRun' "Exec=$out/bin/${pname}"
              fi
              if [ -d ${contents}/usr/share/icons ]; then
                cp -r ${contents}/usr/share/icons $out/share/
              fi
              for png in ${contents}/*.png; do
                [ -f "$png" ] && install -Dm444 "$png" \
                  "$out/share/pixmaps/$(basename "$png")"
              done
            '';

            meta = {
              description = "T3 Code desktop app";
              homepage = "https://t3.codes";
              platforms = [ "x86_64-linux" ];
              mainProgram = pname;
            };
          };

        darwinPackage = pkgs.stdenvNoCC.mkDerivation {
          pname = "t3code";
          version = sources.version;
          inherit src;

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
              ln -s "$binary" "$out/bin/t3code"
            fi
            runHook postInstall
          '';

          meta = {
            description = "T3 Code desktop app";
            homepage = "https://t3.codes";
            platforms = [ "aarch64-darwin" "x86_64-darwin" ];
            mainProgram = "t3code";
          };
        };

        t3code =
          if pkgs.stdenv.isDarwin then darwinPackage else linuxPackage;
      in
      {
        packages = {
          inherit t3code;
          default = t3code;
        };

        apps.default = {
          type = "app";
          program = "${t3code}/bin/t3code";
        };

        formatter = pkgs.nixpkgs-fmt;
      });
}
