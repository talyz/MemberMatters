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

      nixosModules = {
        membermatters =
          {
            config,
            lib,
            pkgs,
            ...
          }:

          let
            cfg = config.services.membermatters;
            inherit (pkgs.stdenv.hostPlatform) system;

            pythonSet = pythonSets.${system};

            inherit (lib)
              mkOption
              mkIf
              toShellVars
              concatStringsSep
              attrNames;


            staticRoot = pkgs.stdenv.mkDerivation {
              name = "membermatters-static";
              inherit (pythonSet.membermatters) src;

              dontConfigure = true;
              dontBuild = true;

              nativeBuildInputs = [
                cfg.venv
              ];

              env = {
                MM_STATIC_LOCATION = "${placeholder "out"}/static";
                MM_LOG_LOCATION = "errors.log";
                MM_DB_LOCATION = "db.sqlite3";
              };

              installPhase = ''
                manage collectstatic
              '';
            };

            membermattersManage = pkgs.writeScriptBin "membermatters" ''
              set -o errexit -o pipefail -o nounset -o errtrace
              shopt -s inherit_errexit

              cd /var/lib/membermatters
              ${toShellVars cfg.config}
              export ${concatStringsSep " " (attrNames cfg.config)}
              sudo -u membermatters --preserve-env=${concatStringsSep "," (attrNames cfg.config)} ${cfg.venv}/bin/manage "$@"
            '';
          in
          {
            options.services.membermatters = {
              enable = mkOption {
                type = lib.types.bool;
                default = false;
                description = ''
                  Enable membermatters.
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

              initialAdminUser = {
                passwordFile = mkOption {
                  type = lib.types.externalPath;
                  example = "/path/to/password_file";
                  description = ''
                    A file containing the initial admin password.
                  '';
                };

                email = mkOption {
                  type = lib.types.str;
                  example = "default@example.com";
                };

                screen_name = mkOption {
                  type = lib.types.str;
                  example = "the_admin";
                };

                first_name = mkOption {
                  type = lib.types.str;
                  example = "Chuck";
                };

                last_name = mkOption {
                  type = lib.types.str;
                  example = "Testa";
                };
              };

              config = mkOption {
                type = with lib.types;
                attrsOf (
                  nullOr (
                    oneOf [
                      bool
                      int
                      port
                      path
                      str
                    ]));
                example = lib.literalExample ''
                  {
                    MM_LANGUAGE_CODE = "en-au";
                    MM_TIME_ZONE = "Australia/Brisbane";
                  }
                '';
                description = ''
                  Variables to set in MemberMatters' environment.
                '';
              };

            };


            config = mkIf cfg.enable {
              services.membermatters.config = {
                MM_ENV = "Production";
                MM_LOG_LOCATION = "errors.log";
                MM_USE_POSTGRES = "True";
                POSTGRES_HOST = "";
                MM_REDIS_HOST = "unix://${config.services.redis.servers.membermatters.unixSocket}";
                MM_CELERY_BROKER_URL = "redis+socket://${config.services.redis.servers.membermatters.unixSocket}";
                MM_STATIC_LOCATION = "${staticRoot}";
                DJANGO_SETTINGS_MODULE = "membermatters.settings";
                PYTHONPATH = "${cfg.venv}/${pythonSet.python.sitePackages}";
              };

              environment.systemPackages = [
                membermattersManage
              ];

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
                  user = "membermatters";
                  unixSocket = "/run/redis-membermatters/socket";
                  unixSocketPerm = 600;
                };
              };

              systemd.services.membermatters = {
                description = "MemberMatters main server application";

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

                environment = cfg.config;

                path = [
                  cfg.venv
                  pkgs.curl
                  pkgs.jq
                ];

                serviceConfig = {
                  ExecStartPre =
                    let
                      makePassword = pkgs.writeText "make-password" ''
                        from django.contrib.auth.hashers import make_password
                        with open("${cfg.initialAdminUser.passwordFile}") as pf:
                            print(make_password(pf.read().strip("\n")))
                      '';
                    in
                    pkgs.writeShellScript "membermatter-startpre" ''
                      set -euo pipefail
                      shopt -s inherit_errexit

                      manage migrate

                      if [[ ! -e /var/lib/membermatters/admin_created ]]; then
                          ${toShellVars cfg.initialAdminUser}
                          export ${concatStringsSep " " (attrNames cfg.initialAdminUser)}

                          password=$(manage shell <${makePassword})
                          export password

                          current_time=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")
                          export current_time

                          jq <${pythonSet.membermatters.src}/fixtures/initial.json >/run/membermatters/admin.json \
                              '.[0].fields.password = ($ENV.password) |
                               .[0].fields.email = ($ENV.email) |
                               .[0].fields.last_login = ($ENV.current_time) |
                               .[1].fields.screen_name = ($ENV.screen_name) |
                               .[1].fields.first_name = ($ENV.first_name) |
                               .[1].fields.last_name = ($ENV.last_name) |
                               .[1].fields.created = ($ENV.current_time) |
                               .[1].fields.modified = ($ENV.current_time) |
                               .[1].fields.last_memberbucks_purchase = ($ENV.current_time)'

                          manage loaddata /run/membermatters/admin.json

                          touch /var/lib/membermatters/admin_created
                      fi
                    '';
                  ExecStart = "${cfg.venv}/bin/daphne -e systemd:domain=UNIX:name=membermatters membermatters.asgi:application";
                  ExecStartPost = pkgs.writeShellScript "membermatter-startpost" ''
                    set -euo pipefail

                    # Wait for app to be running
                    while ! curl -sf --unix-socket /run/membermatters.sock localhost/api/config/; do sleep 1; done

                    # Hack around https://github.com/twisted/twisted/issues/10261
                    chmod o-rwx /run/membermatters.sock
                  '';
                  Restart = "on-failure";

                  User = "membermatters";
                  Group = "membermatters";

                  StateDirectory = "membermatters";
                  RuntimeDirectory = "membermatters";
                  WorkingDirectory = "/var/lib/membermatters";
                };

                wantedBy = [ "multi-user.target" ];
              };
              systemd.sockets.membermatters = {
                wantedBy = [
                  "sockets.target"
                  "membermatters.service"
                ];
                socketConfig = {
                  ListenStream = "/run/membermatters.sock";
                  FileDescriptorName = "membermatters";
                  SocketUser = "membermatters";
                  SocketGroup = "nginx";
                  SocketMode = "0660";
                };
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
                environment = cfg.config;
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
                environment = cfg.config;
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

                upstreams.membermatters.servers."unix://run/membermatters.sock" = { };

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

                environment.etc.membermattersAdminPassword.text = "MemberMatters!";

                services.membermatters = {
                  enable = true;
                  hostname = "localhost";
                  initialAdminUser = {
                    passwordFile = "/etc/membermattersAdminPassword";
                    email = "nix@os.com";
                    screen_name = "the_badmin";
                    first_name = "bad";
                    last_name = "minton";
                  };
                };

                networking.firewall.enable = false;
              };

            testScript = ''
              machine.wait_for_unit("membermatters.service")

              with subtest("Web interface getting ready"):
                  machine.wait_until_succeeds("curl -fs localhost/api/config/")
                  print(machine.succeed("curl -fs localhost/api/config/"))
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
