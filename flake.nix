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

            staticRoot = pkgs.stdenv.mkDerivation {
              name = "membermatters-static";
              inherit (pythonSet.membermatters) src;

              dontConfigure = true;
              dontBuild = true;

              nativeBuildInputs = [
                cfg.venv
              ];

              installPhase = ''
                env MM_LOG_LOCATION=errors.log MM_DB_LOCATION=db.sqlite3 MM_STATIC_LOCATION="$out/static" python manage.py collectstatic
              '';
            };

            membermattersEnv = {
              MM_ENV="Production";
              MM_LOG_LOCATION="errors.log";
              MM_USE_POSTGRES="True";
              POSTGRES_HOST="";
              MM_REDIS_HOST="redis://127.0.0.1:6379/0";
              MM_STATIC_LOCATION="${staticRoot}";
              DJANGO_SETTINGS_MODULE="membermatters.settings";
              PYTHONPATH = "${cfg.venv}/${pythonSet.python.sitePackages}";
            };
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

              hostname = mkOption {
                type = lib.types.str;
                example = "membermatters.example.com";
                description = ''
                  The hostname MemberMatters will be hosted at.
                '';
              };
            };

            config = mkIf cfg.enable {
              services.postgresql = {
                enable = true;
                ensureDatabases = [ "membermatters" ];
                ensureUsers = [
                  {
                    name = "membermatters";
                    ensureDBOwnership = true;
                  }
                ];
              };

              services.redis.servers = {
                membermatters = {
                  enable = true;
                  bind = "0.0.0.0";
                  port = 6379;
                  # user = "membermatters";
                  # unixSocket = "/run/redis-membermatters-caching/socket";
                  # unixSocketPerm = 600;
                };
              };

              systemd.services.membermatters = {
                description = "Django Webapp server";

                after = [
                  "network.target"
                  "postgresql.service"
                ];
                requires = [
                  "postgresql.service"
                ];
                wants = [
                  "membermatters-celery-worker.service"
                  "membermatters-celery-beat.service"
                ];

                environment = membermattersEnv;

                serviceConfig = {
                  ExecStartPre = pkgs.writeShellScript "membermatter-prestart" ''
                    set -euo pipefail
                    ${cfg.venv}/bin/manage migrate
                    ${cfg.venv}/bin/manage loaddata ${pythonSet.membermatters.src}/fixtures/initial.json
                  '';
                  ExecStart = "${cfg.venv}/bin/daphne -b 0.0.0.0 -p 8000 membermatters.asgi:application";
                  Restart = "on-failure";

                  User = "membermatters";
                  Group = "membermatters";

                  StateDirectory = "membermatters";
                  RuntimeDirectory = "membermatters";
                  # LogsDirectory = "membermatters";
                  WorkingDirectory = "/var/lib/membermatters";

                  # BindReadOnlyPaths = [
                  #   "${
                  #     config.environment.etc."ssl/certs/ca-certificates.crt".source
                  #   }:/etc/ssl/certs/ca-certificates.crt"
                  #   builtins.storeDir
                  #   "-/etc/resolv.conf"
                  #   "-/etc/nsswitch.conf"
                  #   "-/etc/hosts"
                  #   "-/etc/localtime"
                  # ];
                };

                wantedBy = [ "multi-user.target" ];
              };

              systemd.services.membermatters-celery-worker = {
                after = [
                  "network.target"
                  "postgresql.service"
                  "membermatters.service"
                ];
                requires = [
                  "postgresql.service"
                  "membermatters.service"
                ];
                environment = membermattersEnv;
                serviceConfig = {
                  Type = "simple";
                  User = "membermatters";
                  Group = "membermatters";
                  StateDirectory = "membermatters-celery-worker";
                  WorkingDirectory = "/var/lib/membermatters-celery-worker";
                  PrivateTmp = true;
                  Restart = "always";
                  ExecStart = "${cfg.venv}/bin/celery --app=membermatters.celeryapp:app worker --pool=prefork -O fair";
                };
              };

              systemd.services.membermatters-celery-beat = {
                after = [
                  "network.target"
                  "postgresql.service"
                  "membermatters.service"
                ];
                requires = [
                  "postgresql.service"
                  "membermatters.service"
                ];
                environment = membermattersEnv;
                serviceConfig = {
                  Type = "simple";
                  User = "membermatters";
                  Group = "membermatters";
                  StateDirectory = "membermatters-celery-beat";
                  WorkingDirectory = "/var/lib/membermatters-celery-beat";
                  PrivateTmp = true;
                  Restart = "always";
                  ExecStart = "${cfg.venv}/bin/celery --app=membermatters.celeryapp:app beat -s /var/lib/membermatters/celerybeat-schedule";
                };
              };

              services.nginx = {
                enable = true;

                # recommendedTlsSettings = true;
                recommendedOptimisation = true;
                recommendedGzipSettings = true;
                recommendedProxySettings = true;

                upstreams.membermatters.servers."localhost:8000" = { };

                virtualHosts.${cfg.hostname} = {
                  root = self.packages.${system}.frontend;
                  locations = {
                    "/".tryFiles = "try_files $uri $uri/ /index.html";
                    "/static" = {
                      root = staticRoot;
                    };
                    "~ ^/(api|admin)".proxyPass = "http://membermatters";
                    # locations."/".extraConfig = ''
                    #   proxy_connect_timeout   300s;
                    # '';
                    "/ws" = {
                      proxyPass = "http://membermatters";
                      proxyWebsockets = true;
                    };
                  };
                };
              };

              users.users.membermatters = {
                group = "membermatters";
                isSystemUser = true;
              };
              users.groups.membermatters = { };

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
                virtualisation.graphics = false;

                imports = [
                  self.nixosModules.membermatters
                ];

                services.membermatters = {
                  enable = true;
                  hostname = "localhost";
                };

                system.stateVersion = "25.11";

                networking.firewall.enable = false;
              };

            testScript = ''
              machine.wait_for_unit("membermatters.service")

              with subtest("Web interface getting ready"):
                  machine.wait_until_succeeds("curl -fs localhost:8000/api/config/")
                  print(machine.succeed("curl -fs localhost:8000/api/config/"))
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
