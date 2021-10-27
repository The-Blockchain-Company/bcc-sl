{ system, compiler, flags, pkgs, hsPkgs, pkgconfPkgs, ... }:
  {
    flags = {};
    package = {
      specVersion = "1.10";
      identifier = { name = "bcc-sl-infra"; version = "3.2.0"; };
      license = "Apache-2.0";
      copyright = "2021 The-Blockchain-Company";
      maintainer = "hi@serokell.io";
      author = "Serokell";
      homepage = "";
      url = "";
      synopsis = "Bcc SL - infrastructural";
      description = "Bcc SL - infrastructural";
      buildType = "Simple";
      };
    components = {
      "library" = {
        depends = [
          (hsPkgs.aeson)
          (hsPkgs.async)
          (hsPkgs.base)
          (hsPkgs.base64-bytestring)
          (hsPkgs.bytestring)
          (hsPkgs.bcc-sl-binary)
          (hsPkgs.bcc-sl-chain)
          (hsPkgs.bcc-sl-core)
          (hsPkgs.bcc-sl-crypto)
          (hsPkgs.bcc-sl-db)
          (hsPkgs.bcc-sl-networking)
          (hsPkgs.bcc-sl-util)
          (hsPkgs.clock)
          (hsPkgs.conduit)
          (hsPkgs.containers)
          (hsPkgs.directory)
          (hsPkgs.dns)
          (hsPkgs.ekg-core)
          (hsPkgs.ekg-statsd)
          (hsPkgs.ekg-wai)
          (hsPkgs.ether)
          (hsPkgs.exceptions)
          (hsPkgs.filepath)
          (hsPkgs.formatting)
          (hsPkgs.hashable)
          (hsPkgs.http-client)
          (hsPkgs.http-client-tls)
          (hsPkgs.iproute)
          (hsPkgs.lens)
          (hsPkgs.megaparsec)
          (hsPkgs.mtl)
          (hsPkgs.network-info)
          (hsPkgs.network-transport)
          (hsPkgs.network-transport-tcp)
          (hsPkgs.lzma-conduit)
          (hsPkgs.optparse-applicative)
          (hsPkgs.safe-exceptions)
          (hsPkgs.serokell-util)
          (hsPkgs.stm)
          (hsPkgs.tar)
          (hsPkgs.time)
          (hsPkgs.tagged)
          (hsPkgs.vector)
          (hsPkgs.text)
          (hsPkgs.time-units)
          (hsPkgs.network-transport)
          (hsPkgs.universum)
          (hsPkgs.unliftio)
          (hsPkgs.unordered-containers)
          (hsPkgs.yaml)
          ] ++ (pkgs.lib).optional (!system.isWindows) (hsPkgs.unix);
        build-tools = [
          (hsPkgs.buildPackages.cpphs or (pkgs.buildPackages.cpphs))
          ];
        };
      tests = {
        "infra-test" = {
          depends = [
            (hsPkgs.QuickCheck)
            (hsPkgs.async)
            (hsPkgs.aeson)
            (hsPkgs.base)
            (hsPkgs.bytestring)
            (hsPkgs.bcc-sl-binary-test)
            (hsPkgs.bcc-sl-chain)
            (hsPkgs.bcc-sl-chain-test)
            (hsPkgs.bcc-sl-core)
            (hsPkgs.bcc-sl-core-test)
            (hsPkgs.bcc-sl-crypto)
            (hsPkgs.bcc-sl-crypto-test)
            (hsPkgs.bcc-sl-infra)
            (hsPkgs.bcc-sl-networking)
            (hsPkgs.bcc-sl-util-test)
            (hsPkgs.containers)
            (hsPkgs.dns)
            (hsPkgs.generic-arbitrary)
            (hsPkgs.hedgehog)
            (hsPkgs.hspec)
            (hsPkgs.iproute)
            (hsPkgs.universum)
            (hsPkgs.yaml)
            ];
          };
        };
      };
    } // rec { src = (pkgs.lib).mkDefault ../.././infra; }