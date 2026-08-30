{
  description = "Noctalia v5 Elgato Control plugin (x86_64-linux / lea)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      hidapiLib = "${pkgs.hidapi}/lib/libhidapi-hidraw.so.0";
      python = pkgs.python3;
      elgato-control = pkgs.stdenvNoCC.mkDerivation {
        pname = "elgato-control";
        version = "1.0.0";
        src = ./elgato-control;
        nativeBuildInputs = [ pkgs.makeWrapper ];
        dontBuild = true;
        installPhase = ''
          runHook preInstall
          test -e ${hidapiLib}
          mkdir -p $out/share/elgato-control $out/bin
          cp -r . $out/share/elgato-control/
          makeWrapper ${python}/bin/python3 $out/bin/elgato-control \
            --add-flags "$out/share/elgato-control/bin/elgato-control" \
            --set ELGATO_HIDAPI ${hidapiLib} \
            --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.imagemagick ]}
          runHook postInstall
        '';
        meta = {
          description = "Native Linux HID CLI for Elgato Stream Deck, Pedal, Wave:3, and Key Lights";
          homepage = "https://github.com/luxus/noctalia-elgato-control";
          license = pkgs.lib.licenses.mit;
          platforms = [ system ];
          mainProgram = "elgato-control";
        };
      };
    in {
      nixosModules.default = { ... }: {
        services.udev.extraRules = builtins.readFile ./elgato-control/udev/99-elgato-streamdeck.rules;
      };

      packages.${system} = {
        inherit elgato-control;
        default = elgato-control;
      };

      apps.${system}.default = {
        type = "app";
        program = "${elgato-control}/bin/elgato-control";
        meta.description = "Native Linux HID CLI for Elgato Stream Deck hardware";
      };

      checks.${system}.elgato-control = pkgs.runCommand "elgato-control-check" {
        src = pkgs.lib.cleanSource ./.;
        nativeBuildInputs = [ python pkgs.luau elgato-control ];
      } ''
        cp -r $src src
        chmod -R u+w src
        cd src
        python3 -m unittest discover -s elgato-control/tests -v
        python3 elgato-control/tests/test_streamdeck.py
        for f in elgato-control/*.luau; do
          luau-compile --binary "$f" >/dev/null
        done
        export XDG_CONFIG_HOME="$PWD/tmp-xdg/config"
        export XDG_STATE_HOME="$PWD/tmp-xdg/state"
        export XDG_CACHE_HOME="$PWD/tmp-xdg/cache"
        mkdir -p "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME"
        elgato-control init
        elgato-control status --json > status.json
        python3 -c 'import json; d=json.load(open("status.json")); assert d["running"] is False; assert set(d)=={"running","plus","classic","pedal","profile"}'
        grep -q libhidapi-hidraw.so.0 "$(command -v elgato-control)"
        mkdir "$out"
      '';
    };
}
