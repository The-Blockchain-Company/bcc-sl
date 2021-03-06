{-# LANGUAGE ApplicativeDo   #-}
{-# LANGUAGE CPP             #-}
{-# LANGUAGE RecordWildCards #-}

-- | Module for command-line options and flags

module Pos.Client.CLI.Options
       ( CommonArgs (..)
       , commonArgsParser
       , configurationOptionsParser
       , optionalJSONPath
       , optionalLogPrefix
       , portOption
       , webPortOption
       , walletAddressOption
       , docAddressOption
       , networkAddressOption
       , templateParser

       , nodeIdOption

       , logConfig_L
       , logPrefix_L
       , logConsoleOff_L
       , reportServers_L
       , updateServers_L
       , configurationOptions_L
       ) where

import           Universum

import           Control.Lens (makeLensesWith)
import           Data.Default (def)
import           Data.Time.Units (fromMicroseconds)
import qualified Options.Applicative as Opt
import           Options.Applicative.Builder.Internal (HasMetavar, HasName)
import           Pos.Util (postfixLFields)
import           Pos.Util.OptParse (fromParsec)

import           Pos.Communication (NodeId)
import           Pos.Core (Timestamp (..))
import           Pos.Core.NetworkAddress (NetworkAddress, addrParser,
                     addrParserNoWildcard)
import           Pos.Infra.Util.TimeWarp (addressToNodeId)
import           Pos.Launcher.Configuration (ConfigurationOptions (..))

data CommonArgs = CommonArgs
    { logConfig            :: !(Maybe FilePath)
    , logPrefix            :: !(Maybe FilePath)
    , logConsoleOff        :: !Bool
    , reportServers        :: ![Text]
    , updateServers        :: ![Text]
    , configurationOptions :: !ConfigurationOptions
    } deriving Show

makeLensesWith postfixLFields ''CommonArgs

commonArgsParser :: Opt.Parser CommonArgs
commonArgsParser = do
    logConfig <- optionalLogConfig
    logPrefix <- optionalLogPrefix
    logConsoleOff <- optionalLogConsoleOff
    reportServers <- reportServersOption
    updateServers <- updateServersOption
    configurationOptions <- configurationOptionsParser
    pure CommonArgs{..}

-- To get rid of abiguity in 'toText' from 'Universum', which has type
-- 'ToText a => a -> Text'.
toText_ :: String -> Text
toText_ = toText

-- Note: if you want to change names of these options, please also
-- update bcc-launcher accordingly (grep for these names).
configurationOptionsParser :: Opt.Parser ConfigurationOptions
configurationOptionsParser = do
    cfoFilePath    <- filePathParser
    cfoKey         <- keyParser
    cfoSystemStart <- systemStartParser
    cfoSeed        <- seedParser
    return ConfigurationOptions{..}
  where
    filePathParser :: Opt.Parser FilePath
    filePathParser = Opt.strOption $
        Opt.long    "configuration-file" <>
        Opt.metavar "FILEPATH" <>
        Opt.help    "Path to a yaml configuration file" <>
        Opt.value   (cfoFilePath def)
    keyParser :: Opt.Parser Text
    keyParser = fmap toText_ $ Opt.strOption $
        Opt.long    "configuration-key" <>
        Opt.metavar "TEXT" <>
        Opt.help    "Key within the configuration file to use" <>
        Opt.value   (toString (cfoKey def))
    systemStartParser :: Opt.Parser (Maybe Timestamp)
    systemStartParser = Opt.option (Just . Timestamp . fromMicroseconds . (*) 1000000 <$> Opt.auto) $
        Opt.long    "system-start" <>
        Opt.metavar "TIMESTAMP" <>
        Opt.help    "System start time. Format - seconds since Unix Epoch." <>
        Opt.value   (cfoSystemStart def)
    seedParser :: Opt.Parser (Maybe Integer)
    seedParser = Opt.optional $ Opt.option Opt.auto $
        Opt.long    "configuration-seed" <>
        Opt.metavar "INTEGER" <>
        Opt.help    "Seed for genesis generation. Overrides one from configuration file."

templateParser :: (HasName f, HasMetavar f) => String -> String -> String -> Opt.Mod f a
templateParser long metavar help =
    Opt.long long
    <> Opt.metavar metavar
    <> Opt.help help

networkAddressOption :: String -> String -> Opt.Parser NetworkAddress
networkAddressOption longOption helpMsg =
    Opt.option (fromParsec addrParserNoWildcard) $
        templateParser longOption "HOST:PORT" helpMsg

nodeIdOption :: String -> String -> Opt.Parser NodeId
nodeIdOption longOption helpMsg =
    Opt.option (fromParsec $ addressToNodeId <$> addrParser) $
        templateParser longOption "HOST:PORT" helpMsg

optionalLogConfig :: Opt.Parser (Maybe FilePath)
optionalLogConfig =
    Opt.optional $ Opt.strOption $
        templateParser "log-config" "FILEPATH" "Path to logger configuration."

optionalLogPrefix :: Opt.Parser (Maybe String)
optionalLogPrefix =
    Opt.optional $ Opt.strOption $
        templateParser "logs-prefix" "FILEPATH" "Prefix to logger output path."

optionalLogConsoleOff :: Opt.Parser Bool
optionalLogConsoleOff =
    Opt.switch $
        Opt.long "log-console-off" <>
        Opt.help "Inhibit logging to the console."

optionalJSONPath :: Opt.Parser (Maybe FilePath)
optionalJSONPath =
    Opt.optional $ Opt.strOption $
        templateParser "json-log" "FILEPATH" "Path to JSON log file."

portOption :: Word16 -> Opt.Parser Word16
portOption portNum =
    Opt.option Opt.auto $
        templateParser "port" "PORT" "Port to work on."
        <> Opt.value portNum
        <> Opt.showDefault

reportServersOption :: Opt.Parser [Text]
reportServersOption =
    many $
    toText_ <$>
    Opt.strOption
        (templateParser
             "report-server"
             "URI"
             "Reporting server to send crash/error logs on.")

updateServersOption :: Opt.Parser [Text]
updateServersOption =
    many $
    toText_ <$>
    Opt.strOption
        (templateParser "update-server" "URI" "Server to download updates from.")

webPortOption :: Word16 -> String -> Opt.Parser Word16
webPortOption portNum help =
    Opt.option Opt.auto $
        templateParser "web-port" "PORT" help -- "Port for web server"
        <> Opt.value portNum
        <> Opt.showDefault

walletAddressOption :: Maybe NetworkAddress -> Opt.Parser NetworkAddress
walletAddressOption na =
    Opt.option (fromParsec addrParser) $
            Opt.long "wallet-address"
         <> Opt.metavar "IP:PORT"
         <> Opt.help helpMsg
         <> Opt.showDefault
         <> maybe mempty Opt.value na
  where
    helpMsg = "IP and port for backend wallet API."

docAddressOption :: Maybe NetworkAddress -> Opt.Parser (Maybe NetworkAddress)
docAddressOption na =
    Opt.optional $ Opt.option (fromParsec addrParser) $
            Opt.long "wallet-doc-address"
         <> Opt.metavar "IP:PORT"
         <> Opt.help helpMsg
         <> Opt.showDefault
         <> maybe mempty Opt.value na
  where
    helpMsg = "IP and port for backend wallet API documentation."
