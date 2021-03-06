{- | The module which contains parsing facilities for
     the CLI options passed to this edge node.
-}
module Bcc.Wallet.Server.CLI where

import           Universum

import           Data.Time.Units (Minute)
import           Data.Version (showVersion)
import           Options.Applicative (Parser, auto, execParser, footerDoc,
                     fullDesc, header, help, helper, info, infoOption, long,
                     metavar, option, progDesc, strOption, switch, value)
import           Paths_bcc_sl (version)
import           Pos.Client.CLI (CommonNodeArgs (..))
import qualified Pos.Client.CLI as CLI
import           Pos.Core.NetworkAddress (NetworkAddress, localhost)
import           Pos.Util.CompileInfo (CompileTimeInfo (..), HasCompileInfo,
                     compileInfo)
import           Pos.Web (TlsParams (..))


-- | The options parsed from the CLI when starting up this wallet node.
-- This umbrella data type includes the node-specific options for this edge node
-- plus the wallet backend specific options.
data WalletStartupOptions = WalletStartupOptions {
      wsoNodeArgs            :: !CommonNodeArgs
    , wsoWalletBackendParams :: !WalletBackendParams
    } deriving Show

-- | DB-specific options.
data WalletDBOptions = WalletDBOptions {
      walletDbPath       :: !FilePath
      -- ^ The path for the wallet-backend DB.
    , walletRebuildDb    :: !Bool
      -- ^ Whether or not to wipe and rebuild the DB.
    , walletAcidInterval :: !Minute
      -- ^ The delay between one operation on the acid-state DB and the other.
      -- Such @operation@ entails things like checkpointing the DB.
    , walletFlushDb      :: !Bool
    } deriving Show

-- | The startup parameters for the legacy wallet backend.
-- Named with the suffix `Params` to honour other types of
-- parameters like `NodeParams` or `SscParams`.
data WalletBackendParams = WalletBackendParams
    { enableMonitoringApi :: !Bool
    -- ^ Whether or not to run the monitoring API.
    , monitoringApiPort   :: !Word16
    -- ^ The port the monitoring API should listen to.
    , walletTLSParams     :: !(Maybe TlsParams)
    -- ^ The TLS parameters.
    , walletAddress       :: !NetworkAddress
    -- ^ The wallet address.
    , walletDocAddress    :: !(Maybe NetworkAddress)
    -- ^ The wallet documentation address.
    , walletRunMode       :: !RunMode
    -- ^ The mode this node is running in.
    , walletDbOptions     :: !WalletDBOptions
    -- ^ DB-specific options.
    , forceFullMigration  :: !Bool
    } deriving Show


getWalletDbOptions :: WalletBackendParams -> WalletDBOptions
getWalletDbOptions WalletBackendParams{..} =
    walletDbOptions

getFullMigrationFlag :: WalletBackendParams -> Bool
getFullMigrationFlag WalletBackendParams{..} =
    forceFullMigration

-- | A richer type to specify in which mode we are running this node.
data RunMode = ProductionMode
             -- ^ Run in production mode
             | DebugMode
             -- ^ Run in debug mode
             deriving Show

-- | Converts a @GenesisKeysInclusion@ into a @Bool@.
isDebugMode :: RunMode -> Bool
isDebugMode ProductionMode = False
isDebugMode DebugMode      = True

-- | Parses and returns the @WalletStartupOptions@ from the command line.
getWalletNodeOptions :: HasCompileInfo => IO WalletStartupOptions
getWalletNodeOptions = execParser programInfo
  where
    programInfo = info (helper <*> versionOption <*> walletStartupOptionsParser) $
        fullDesc <> progDesc "Bcc SL edge node w/ wallet."
                 <> header "Bcc SL edge node."
                 <> footerDoc CLI.usageExample

    versionOption = infoOption
        ("bcc-node-" <> showVersion version <>
         ", git revision " <> toString (ctiGitRevision compileInfo))
        (long "version" <> help "Show version.")

-- | The main @Parser@ for the @WalletStartupOptions@
walletStartupOptionsParser :: Parser WalletStartupOptions
walletStartupOptionsParser = WalletStartupOptions <$> CLI.commonNodeArgsParser
                                                  <*> walletBackendParamsParser

-- | The @Parser@ for the @WalletBackendParams@.
walletBackendParamsParser :: Parser WalletBackendParams
walletBackendParamsParser = WalletBackendParams <$> enableMonitoringApiParser
                                                <*> monitoringApiPortParser
                                                <*> tlsParamsParser
                                                <*> addressParser
                                                <*> docAddressParser
                                                <*> runModeParser
                                                <*> dbOptionsParser
                                                <*> forceFullMigrationParser
  where
    enableMonitoringApiParser :: Parser Bool
    enableMonitoringApiParser = switch (long "monitoring-api" <>
                                        help "Activate the node monitoring API."
                                       )

    monitoringApiPortParser :: Parser Word16
    monitoringApiPortParser = CLI.webPortOption 8080 "Port for the monitoring API."

    addressParser :: Parser NetworkAddress
    addressParser = CLI.walletAddressOption $ Just (localhost, 8090)

    docAddressParser :: Parser (Maybe NetworkAddress)
    docAddressParser = CLI.docAddressOption Nothing

    runModeParser :: Parser RunMode
    runModeParser = (\debugMode -> if debugMode then DebugMode else ProductionMode) <$>
        switch (long "wallet-debug" <>
                help "Run wallet with debug params (e.g. include \
                     \all the genesis keys in the set of secret keys)."
               )

    forceFullMigrationParser :: Parser Bool
    forceFullMigrationParser = switch $
                          long "force-full-wallet-migration" <>
                          help "Enforces a non-lenient migration. \
                               \If something fails (for example a wallet fails to decode from the old format) \
                               \migration will stop and the node will crash, \
                               \instead of just logging the error."

tlsParamsParser :: Parser (Maybe TlsParams)
tlsParamsParser = constructTlsParams <$> certPathParser
                                     <*> keyPathParser
                                     <*> caPathParser
                                     <*> (not <$> noClientAuthParser)
                                     <*> disabledParser
  where
    constructTlsParams tpCertPath tpKeyPath tpCaPath tpClientAuth disabled =
        guard (not disabled) $> TlsParams{..}

    certPathParser :: Parser FilePath
    certPathParser = strOption (CLI.templateParser
                                "tlscert"
                                "FILEPATH"
                                "Path to file with TLS certificate"
                                <> value "scripts/tls-files/server.crt"
                               )

    keyPathParser :: Parser FilePath
    keyPathParser = strOption (CLI.templateParser
                               "tlskey"
                               "FILEPATH"
                               "Path to file with TLS key"
                               <> value "scripts/tls-files/server.key"
                              )

    caPathParser :: Parser FilePath
    caPathParser = strOption (CLI.templateParser
                              "tlsca"
                              "FILEPATH"
                              "Path to file with TLS certificate authority"
                              <> value "scripts/tls-files/ca.crt"
                             )

    noClientAuthParser :: Parser Bool
    noClientAuthParser = switch $
                         long "no-client-auth" <>
                         help "Disable TLS client verification. If turned on, \
                              \no client certificate is required to talk to \
                              \the API."

    disabledParser :: Parser Bool
    disabledParser = switch $
                     long "no-tls" <>
                     help "Disable tls. If set, 'tlscert', 'tlskey' \
                          \and 'tlsca' options are ignored"


-- | The parser for the @WalletDBOptions@.
dbOptionsParser :: Parser WalletDBOptions
dbOptionsParser = WalletDBOptions <$> dbPathParser
                                  <*> rebuildDbParser
                                  <*> acidIntervalParser
                                  <*> flushDbParser
  where
    dbPathParser :: Parser FilePath
    dbPathParser = strOption (long  "wallet-db-path" <>
                              help  "Path to the wallet's database." <>
                              value "wallet-db"
                             )

    rebuildDbParser :: Parser Bool
    rebuildDbParser = switch (long "wallet-rebuild-db" <>
                              help "If wallet's database already exists, discard \
                                   \its contents and create a new one from scratch."
                             )

    acidIntervalParser :: Parser Minute
    acidIntervalParser = fromInteger <$>
        option auto (long "wallet-acid-cleanup-interval" <>
                     help "Interval on which to execute wallet cleanup \
                          \action (create checkpoint and archive and \
                          \cleanup archive partially)" <>
                     metavar "MINUTES" <>
                     value 5
                    )

    flushDbParser :: Parser Bool
    flushDbParser = switch (long "flush-wallet-db" <>
                            help "Flushes all blockchain-recoverable data from DB \
                                 \(everything excluding wallets/accounts/addresses, \
                                 \metadata)"
                           )
