{ lib
, fetchurl
, ...
}:

with lib;
let
  splitVersion = name: splitString "@" (head (splitString "(" name));
  getVersion = name: last (splitVersion name);
  withoutVersion = name: concatStringsSep "@" (init (splitVersion name));
in
{
  dependencyTarballs = { registry, lock }:
    unique (
      mapAttrsToList
        (n: v:
          let
            name = withoutVersion n;
            baseName = last (splitString "/" (withoutVersion n));
            version = getVersion n;
            url = if v.resolution?tarball then
                    v.resolution.tarball
                  else
                    "${registry}/${name}/-/${baseName}-${version}.tgz";
            name' = if (hasSuffix ".tgz" url) then
                    builtins.baseNameOf url
                  else
                    "${builtins.baseNameOf url}.tgz";
          in
          fetchurl {
            inherit url;
            name = name';
            sha512 = v.resolution.integrity;
          }
        )
        lock.packages
    );

}
