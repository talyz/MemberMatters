{
  description = "hello world application using uv2nix";

  inputs = {
    nixpkgs.url = "github:adisbladis/nixpkgs/importnpmlock-dist-tags";

    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      pyproject-nix,
      uv2nix,
      pyproject-build-systems,
      ...
    }:
    let
      inherit (nixpkgs) lib;
      forAllSystems = lib.genAttrs lib.systems.flakeExposed;

      workspace = uv2nix.lib.workspace.loadWorkspace { workspaceRoot = ./memberportal; };

      overlay = workspace.mkPyprojectOverlay {
        sourcePreference = "wheel";
      };

      editableOverlay = workspace.mkEditablePyprojectOverlay {
        root = "$REPO_ROOT";
      };

      pythonSets = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          python = pkgs.python312;
        in
        (pkgs.callPackage pyproject-nix.build.packages {
          inherit python;
        }).overrideScope
          (
            lib.composeManyExtensions [
              pyproject-build-systems.overlays.wheel
              overlay
              (final: prev: {
                membermatters = prev.membermatters.overrideAttrs(old: {
                  postPatch = ''
                    find .
                    substituteInPlace api_general/views.py \
                      --replace-fail '../package.json' '${./src-frontend/package.json}'
                  '';
                });

                mysqlclient = prev.mysqlclient.overrideAttrs(old: {
                  nativeBuildInputs = old.nativeBuildInputs ++ [
                    pkgs.pkg-config
                  ];
                  buildInputs = (old.buildInputs or [ ]) ++ [
                    pkgs.mariadb-connector-c
                  ];
                });
              })
            ]
          )
      );

    in
    {
      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          pythonSet = pythonSets.${system}.overrideScope editableOverlay;
          virtualenv = pythonSet.mkVirtualEnv "membermatters-dev-env" workspace.deps.all;
        in
        {
          default = pkgs.mkShell {
            packages = [
              virtualenv
              pkgs.uv
            ];
            env = {
              UV_NO_SYNC = "1";
              UV_PYTHON = pythonSet.python.interpreter;
              UV_PYTHON_DOWNLOADS = "never";
            };
            shellHook = ''
              unset PYTHONPATH
              export REPO_ROOT=$(git rev-parse --show-toplevel)
            '';
          };
        }
      );

      nixosModules = let
        # Django static roots grouped per system
        staticRoots = forAllSystems (
          system:
          let
            pkgs = nixpkgs.legacyPackages.${system};
            inherit (pkgs) stdenv;

            pythonSet = pythonSets.${system};

            venv = pythonSet.mkVirtualEnv "membermatters-env" workspace.deps.default;

          in
          stdenv.mkDerivation {
            name = "membermatters-static";
            inherit (pythonSet.membermatters) src;

            dontConfigure = true;
            dontBuild = true;

            nativeBuildInputs = [
              venv
            ];

            installPhase = ''
              env MM_LOG_LOCATION=errors.log MM_DB_LOCATION=db.sqlite3 MM_STATIC_LOCATION="$out" python manage.py collectstatic
            '';
          }
        );
      in {
        membermatters =
          {
            config,
            lib,
            pkgs,
            ...
          }:

          let
            cfg = config.services.membermatters;
            inherit (pkgs) system;

            pythonSet = pythonSets.${system};

            inherit (lib.options) mkOption;
            inherit (lib.modules) mkIf;
          in
          {
            options.services.membermatters = {
              enable = mkOption {
                type = lib.types.bool;
                default = false;
                description = ''
                  Enable membermatters
                '';
              };

              venv = mkOption {
                type = lib.types.package;
                default = pythonSet.mkVirtualEnv "membermatters-env" workspace.deps.default;
                description = ''
                  Django-webapp virtual environment package
                '';
              };

              static-root = mkOption {
                type = lib.types.package;
                default = staticRoots.${system};
                description = ''
                  Django-webapp static root
                '';
              };
            };

            config = mkIf cfg.enable {
              systemd.services.membermatters = {
                description = "Django Webapp server";

                environment = {
                  MM_LOG_LOCATION="errors.log";
                  MM_DB_LOCATION="db.sqlite3";
                  MM_STATIC_LOCATION="${cfg.static-root}";
                  DJANGO_SETTINGS_MODULE="membermatters.settings";
                  PYTHONPATH = "${cfg.venv}/${pythonSet.python.sitePackages}";
                };

                serviceConfig = {
                  ExecStartPre = pkgs.writeShellScript "membermatter-prestart" ''
                    set -euo pipefail
                    ${cfg.venv}/bin/manage migrate
                    ${cfg.venv}/bin/manage loaddata ${pythonSet.membermatters.src}/fixtures/initial.json
                  '';
                  ExecStart = "${cfg.venv}/bin/daphne membermatters.asgi:application";
                  Restart = "on-failure";

                  DynamicUser = true;
                  StateDirectory = "membermatters";
                  RuntimeDirectory = "membermatters";
                  WorkingDirectory = "/var/lib/membermatters";

                  BindReadOnlyPaths = [
                    "${
                      config.environment.etc."ssl/certs/ca-certificates.crt".source
                    }:/etc/ssl/certs/ca-certificates.crt"
                    builtins.storeDir
                    "-/etc/resolv.conf"
                    "-/etc/nsswitch.conf"
                    "-/etc/hosts"
                    "-/etc/localtime"
                  ];
                };

                wantedBy = [ "multi-user.target" ];
              };
            };

          };
      };

      checks = forAllSystems(system: let
        pkgs = nixpkgs.legacyPackages.${system};
      in {
        nixos =
          pkgs.testers.nixosTest {
            name = "membermatters-nixos-test";

            nodes.machine =
              { ... }:
              {
                imports = [
                  self.nixosModules.membermatters
                ];

                services.membermatters = {
                  enable = true;
                };

                system.stateVersion = "25.11";
              };

            testScript = ''
              machine.wait_for_unit("membermatters.service")

              with subtest("Web interface getting ready"):
                  machine.wait_until_succeeds("curl -fs localhost:8000/api/config/")
            '';
          };

      });

      packages = forAllSystems (system: let
        pkgs = nixpkgs.legacyPackages.${system};
        inherit (pkgs) importNpmLock;
      in {
        default = pythonSets.${system}.mkVirtualEnv "membermatters-env" workspace.deps.default;
        frontend = pkgs.buildNpmPackage {
          pname = "membermatters-frontend";
          version = "dev";
          src = ./src-frontend;
          npmDeps = importNpmLock { npmRoot = ./src-frontend; };
          npmConfigHook = importNpmLock.npmConfigHook;

          # @quasar/icongenie pulls in sharp which downloads a libvips binary.
          # Not required for the build anyway.
          npmRebuildFlags = [ "--ignore-scripts" ];

          installPhase = ''
            runHook preInstall
            cp -r dist/spa $out
            runHook postInstall
          '';
        };
      });
    };
}
