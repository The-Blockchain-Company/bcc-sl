let
  bccPkgs = import ../default.nix {};
  cfgFiles = bccPkgs.pkgs.runCommand "cfg" {} ''
    mkdir $out
    cd $out
    cp ${../lib/configuration.yaml} configuration.yaml
    cp ${../lib/mainnet-genesis.json} mainnet-genesis.json
    cp ${../lib/testnet-genesis.json} testnet-genesis.json
    cp ${../lib/mainnet-genesis-dryrun-with-stakeholders.json} mainnet-genesis-dryrun-with-stakeholders.json
  '';
  makeHelper = cfg: bccPkgs.pkgs.writeScriptBin "test-gui-${cfg.name}" ''
    #!/bin/sh

    BIN=$(realpath dist/build/testcases/testcases)

    mkdir -pv states/script-runner/stack-gui-${cfg.name}
    cd states/script-runner/stack-gui-${cfg.name}

    SCRIPT=none $BIN --configuration-file ${cfgFiles}/configuration.yaml --configuration-key ${cfg.key} --log-console-off --db-path db --keyfile secret.key --log-config ${./log-config.yaml} --logs-prefix logs --topology ${./. + "/topology-${cfg.name}.yaml"}
  '';
  mainnet = makeHelper { name = "mainnet"; key = "mainnet_full"; };
  testnet = makeHelper { name = "testnet"; key = "testnet_full"; };
  staging = makeHelper { name = "staging"; key = "mainnet_dryrun_full"; };
in
  bccPkgs.bcc-sl-script-runner.env.overrideAttrs (drv: {
    buildInputs = drv.buildInputs ++ [ bccPkgs.bcc-sl-node-static bccPkgs.bcc-sl-tools mainnet testnet staging ];
  })
