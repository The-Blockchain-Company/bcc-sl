-- | Command line options of purescript generator.

module PSOptions
       ( Args (..)
       , getPSOptions
       ) where

import           Universum

import           Data.Version (showVersion)
import           Options.Applicative.Simple (Parser, help, long, metavar,
                     simpleOptions, strOption, value)

import           Paths_bcc_sl_explorer (version)


newtype Args = Args
    { bridgePath :: FilePath
    }
  deriving Show

argsParser :: Parser Args
argsParser =
    Args <$>
    strOption
        (long "bridge-path" <> metavar "FILEPATH" <> value "Generated" <>
        help "Path where to dump generated modules")

getPSOptions :: IO Args
getPSOptions = do
    (res, ()) <-
        simpleOptions
            ("bcc-explorer-hs2purs-" <> showVersion version)
            "BccSL explorer ps datatypes generator"
            "BccSL explorer ps datatypes generator."
            argsParser
            empty
    return res
