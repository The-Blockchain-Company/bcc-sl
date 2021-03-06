let
  localLib = import ../lib.nix;
  system = builtins.currentSystem;
  pkgs = import (localLib.fetchNixPkgs) { inherit system config; };
  config = {};
  bcc_sl = pkgs.callPackage ../default.nix { gitrev = "abcdef"; allowCustomConfig = false; };
in
import (pkgs.path + "/nixos/tests/make-test.nix") ({ pkgs, ... }: {
  name = "bcc-node";

  nodes.server = { config, pkgs, ... }: {
    virtualisation = {
      qemu.options = [
        "-cpu Haswell"
        "-device virtio-rng-pci"
      ];
      memorySize = 2048;
    };
    security.rngd.enable = pkgs.lib.mkForce true;
    systemd.services.bcc_node_default = {
      description = "Bcc Node";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      serviceConfig = {
        ExecStart = bcc_sl.connectScripts.staging.wallet;
        Type = "notify";
        NotifyAccess = "all";
        TimeoutStartSec = 600;
      };
    };
    systemd.services.bcc_node_custom_port = {
      description = "Bcc Node";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      serviceConfig = {
        ExecStart = bcc_sl.connectScripts.staging.wallet.override ( { walletListen = "127.0.0.1:8091"; ekgListen = "127.0.0.1:8001"; stateDir = "bcc-state-staging-custom-port"; } );
        Type = "notify";
        NotifyAccess = "all";
        TimeoutStartSec = 600;
      };
    };
  };

  testScript = ''
    $server->waitForUnit("bcc_node_default");
    $server->waitForOpenPort(8090);
    $server->succeed("${pkgs.curl}/bin/curl -f -k https://127.0.0.1:8090/docs/v1/index/");
    $server->succeed("${pkgs.curl}/bin/curl -f -k https://127.0.0.1:8090/api/info");
    $server->succeed("${pkgs.curl}/bin/curl -f -k https://127.0.0.1:8090/api/v1/node-info");
    $server->waitForUnit("bcc_node_custom_port");
    $server->waitForOpenPort(8091);
    $server->succeed("${pkgs.curl}/bin/curl -f -k https://127.0.0.1:8091/api/info");
    $server->succeed("${pkgs.curl}/bin/curl -f -k https://127.0.0.1:8091/api/v1/node-info");
  '';
})
