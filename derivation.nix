{ lib
, stdenv
, nodejs
, pkg-config
, callPackage
, runCommand
, remarshal
, xorg
, ...
}:

with builtins; with lib; with callPackage ./lockfile.nix { };
let
  nodePkg = nodejs;
  pkgConfigPkg = pkg-config;
  lndir = "${xorg.lndir}/bin/lndir";
in
{
  mkPnpmPackage =
    { src
    , packageJSON ? "package.json"
    , pnpmLockYaml ? "pnpm-lock.yaml"
    , pnpmWorkspaceYaml ? "pnpm-workspace.yaml"
    , lockOverride ? {}
    , pname ? (fromJSON (readFile ("${src}/${packageJSON}"))).name
    , version ? (fromJSON (readFile ("${src}/${packageJSON}"))).version or null
    , name ? if version != null then "${pname}-${version}" else pname
    , registry ? "https://registry.npmjs.org"
    , script ? "build"
    , distDir ? "dist"
    , installInPlace ? false
    , copyPnpmStore ? true
    , copyNodeModules ? false
    , extraNodeModuleSources ? [ ]
    , extraNativeBuildInputs ? [ ]
    , extraBuildInputs ? [  ]
    , nodejs ? nodePkg
    , pnpm ? nodejs.pkgs.pnpm
    , pkg-config ? pkgConfigPkg
    , ...
    }@attrs:
    let
      attrs' = (builtins.removeAttrs attrs [ "lockOverride" "extraNodeModuleSources" ]);
      parseYaml = yamlFile:
        builtins.fromJSON (readFile
          (runCommand "toJSON" { } "${remarshal}/bin/yaml2json ${yamlFile} $out"));
      lock = lib.recursiveUpdate (parseYaml "${src}/${pnpmLockYaml}") lockOverride;
      lockFile = runCommand "pnpm-lock.yaml" { } "${remarshal}/bin/json2yaml ${
          builtins.toFile "lock.json" (builtins.toJSON lock)
        } $out";
      pnpmWorkspaceYamlSrc = lib.traceValSeq "${src}/${pnpmWorkspaceYaml}";
      workspaces = with lib; traceValSeq (
        [ "." ] ++ (optionals (builtins.pathExists pnpmWorkspaceYamlSrc)
          (parseYaml pnpmWorkspaceYamlSrc).packages));
    in
    stdenv.mkDerivation (
      recursiveUpdate
        (rec {
          inherit src name;

          nativeBuildInputs = [ nodejs pnpm pkg-config ] ++ extraNativeBuildInputs;
          buildInputs = extraBuildInputs;

          configurePhase = ''
            export HOME=$NIX_BUILD_TOP # Some packages need a writable HOME
            export npm_config_nodedir=${nodejs}

            runHook preConfigure

            ${if installInPlace
              then passthru.nodeModules.buildPhase
              else (lib.concatMapStringsSep "\n" (w: ''
                ${if !copyNodeModules
                  then ''
                    mkdir -p ${w}/node_modules
                    ${lndir} ${passthru.nodeModules}/${w}/node_modules ${w}/node_modules
                  ''
                  else ''
                    cp -vr ${passthru.nodeModules}/${w}/node_modules ${w}/node_modules
                  ''
                }
              '') workspaces)
            }

            runHook postConfigure
          '';

          buildPhase = ''
            runHook preBuild

            pnpm run ${script}

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall

            mv ${distDir} $out

            runHook postInstall
          '';

          passthru = {
            inherit attrs;

            pnpmStore = runCommand "${name}-pnpm-store"
              {
                nativeBuildInputs = [ nodejs pnpm ];
              } ''
              mkdir -p $out

              store=$(pnpm store path)
              mkdir -p $(dirname $store)
              ln -s $out $(pnpm store path)

              pnpm store add ${concatStringsSep " " (dependencyTarballs { inherit registry lock; })}
            '';

            nodeModules = stdenv.mkDerivation {
              name = "${name}-node-modules";
              nativeBuildInputs = [ nodejs pnpm pkg-config ] ++ extraNativeBuildInputs;
              buildInputs = extraBuildInputs;
              # Avoid node-gyp fetching headers from internet
              npm_config_nodedir = nodejs;

              unpackPhase = concatStringsSep "\n"
                (
                  map
                    (v:
                      let
                        nv = if isAttrs v then v else { target = "."; source = v; };
                      in ''
                        mkdir -p "${dirOf nv.target}"
                        cp -vr "${nv.source}" "${nv.target}"
                      ''
                    )
                    ([
                      { source = lockFile; target = pnpmLockYaml; }
                    ] ++ (optional (builtins.pathExists pnpmWorkspaceYamlSrc)
                            { source = pnpmWorkspaceYamlSrc; target = pnpmWorkspaceYaml; })
                      ++ (map (w: { source = "${src}/${w}/${packageJSON}"; target = "${w}/${packageJSON}"; }) workspaces)
                      ++ extraNodeModuleSources)
                );

              buildPhase = ''
                export HOME=$NIX_BUILD_TOP # Some packages need a writable HOME

                # pnpm output warnings to stdin, togather with the results.
                # Seriously, pnpm?
                store=$(pnpm store path|tail -n-1)

                # solve pnpm: EACCES: permission denied, copyfile '/build/.pnpm-store
                ${if !copyPnpmStore
                  then ''
                    mkdir -p $store
                    ${lndir} ${passthru.pnpmStore} $store
                  ''
                  else ''
                    mkdir -p $(dirname $store)
                    cp -vRL  ${passthru.pnpmStore} $store
                  ''
                }

                ${lib.optionalString copyPnpmStore "chmod -R +w $store"}

                pnpm install --frozen-lockfile --offline --prod
              '';

              installPhase = lib.concatMapStringsSep "\n"
                (w: ''
                  mkdir -p $out/${w}
                  cp -vr ${w}/node_modules $out/${w}
                '') workspaces;
            };
          };

        }) attrs'
    );
}
