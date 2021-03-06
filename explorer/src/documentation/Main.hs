{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE OverloadedLists     #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving  #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE TypeOperators       #-}

{-# OPTIONS_GHC -fno-warn-orphans #-}

-- | This program builds Swagger specification for Explorer web API and converts it to JSON.
-- We run this program during CI build.
-- Produced JSON will be used to create online
-- version of wallet web API description at bccdocs.com website
-- (please see 'update_explorer_web_api_docs.sh' for technical details).

module Main
    ( main
    ) where

import           Universum

import           Control.Lens (mapped, (?~))
import           Data.Aeson (encode)
import qualified Data.ByteString.Lazy.Char8 as BSL8
import           Data.Fixed (Fixed (..), Micro)
import           Data.Swagger (NamedSchema (..), Swagger, ToParamSchema (..),
                     ToSchema (..), binarySchema, declareNamedSchema,
                     defaultSchemaOptions, description,
                     genericDeclareNamedSchema, host, info, name, title,
                     version)
import           Data.Typeable (Typeable, typeRep)
import           Data.Version (showVersion)
import           Options.Applicative (execParser, footer, fullDesc, header,
                     help, helper, infoOption, long, progDesc)
import qualified Options.Applicative as Opt
import           Servant ((:>))
import           Servant.Multipart (MultipartForm)
import           Servant.Swagger (HasSwagger (toSwagger))

import qualified Paths_bcc_sl_explorer as CSLE
import qualified Pos.Explorer.Web.Api as A
import qualified Pos.Explorer.Web.ClientTypes as C
import           Pos.Explorer.Web.Error (ExplorerError)


main :: IO ()
main = do
    showProgramInfoIfRequired jsonFile
    BSL8.writeFile jsonFile $ encode swaggerSpecForExplorerApi
    putStrLn $ "Done. See " <> jsonFile <> "."
  where
    jsonFile = "explorer-web-api-swagger.json"

    -- | Showing info for the program.
    showProgramInfoIfRequired :: FilePath -> IO ()
    showProgramInfoIfRequired generatedJSON = void $ execParser programInfo
      where
        programInfo = Opt.info (helper <*> versionOption) $
            fullDesc <> progDesc "Generate Swagger specification for Explorer web API."
                     <> header   "Bcc SL Explorer web API docs generator."
                     <> footer   ("This program runs during 'bcc-sl' building on CI. " <>
                                  "Generated file '" <> generatedJSON <> "' will be used to produce HTML documentation. " <>
                                  "This documentation will be published at bccdocs.com using 'update-explorer-web-api-docs.sh'.")

        versionOption = infoOption
            ("bcc-swagger-" <> showVersion CSLE.version)
            (long "version" <> help "Show version.")

instance HasSwagger api => HasSwagger (MultipartForm a :> api) where
    toSwagger Proxy = toSwagger $ Proxy @api

-- | Instances we need to build Swagger-specification for 'explorerApi':
-- 'ToParamSchema' - for types in parameters ('Capture', etc.),
-- 'ToSchema' - for types in bodies.
instance ToSchema      C.CHash
instance ToParamSchema C.CHash
instance ToSchema      C.CTxId
instance ToParamSchema C.CTxId
instance ToSchema      C.CAddress
instance ToParamSchema C.CAddress
instance ToParamSchema C.EpochIndex
instance ToSchema      C.CTxSummary
instance ToSchema      C.CBlockRange
instance ToSchema      C.CTxEntry
instance ToSchema      C.CTxBrief
instance ToSchema      C.CUtxo
instance ToSchema      C.CBlockSummary
instance ToSchema      C.CBlockEntry
instance ToSchema      C.CAddressType
instance ToSchema      C.CAddressSummary
instance ToSchema      C.CCoin
instance ToSchema      C.CBcc
instance ToSchema      C.CNetworkAddress
instance ToSchema      C.CGenesisSummary
instance ToSchema      C.CGenesisAddressInfo
instance ToSchema      C.Byte
instance ToSchema      ExplorerError
instance ToParamSchema C.CAddressesFilter

deriving instance Generic Micro

instance ToSchema C.CByteString where
  declareNamedSchema _ = return $ NamedSchema (Just "CByteString") binarySchema

-- | Instance for Either-based types (types we return as 'Right') in responses.
-- Due 'typeOf' these types must be 'Typeable'.
-- We need this instance for correct Swagger-specification.
instance {-# OVERLAPPING #-} (Typeable a, ToSchema a) => ToSchema (Either ExplorerError a) where
    declareNamedSchema proxy = genericDeclareNamedSchema defaultSchemaOptions proxy
        & mapped . name ?~ show (typeRep (Proxy @(Either ExplorerError a)))

-- | Build Swagger-specification from 'explorerApi'.
swaggerSpecForExplorerApi :: Swagger
swaggerSpecForExplorerApi = toSwagger A.explorerApi
    & info . title       .~ "Bcc SL Explorer Web API"
    & info . version     .~ toText (showVersion CSLE.version)
    & info . description ?~ "This is an API for Bcc SL Explorer."
    & host               ?~ "bccexplorer.com"
