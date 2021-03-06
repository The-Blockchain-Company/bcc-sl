module Bcc.Wallet.API
       ( -- * Wallet API Top-Level Representations
         WalletAPI
       , walletAPI
       , WalletDoc
       , walletDoc
       , walletDocAPI

         -- * Components Representations
       , V1API
       , v1API
       , InternalAPI
       , internalAPI
       ) where

import           Bcc.Wallet.API.Types (WalletLoggingConfig)
import           Pos.Util.Servant (LoggingApi)
import           Servant ((:<|>), (:>), Proxy (..))
import           Servant.Swagger.UI (SwaggerSchemaUI)

import qualified Bcc.Wallet.API.Internal as Internal
import qualified Bcc.Wallet.API.V1 as V1

-- | The complete API, qualified by its versions. For backward compatibility's
-- sake, we still expose the old API under @/api/@. Specification is split under
-- separate modules.
--
-- Unsurprisingly:
--
-- * 'Bcc.Wallet.API.V1' hosts the full specification of the V1 API;
--
-- This project uses Servant, which means the logic is separated from the
-- implementation (i.e. the Server). Such server, together with all its web
-- handlers lives in an executable which contains the aptly-named modules:
--
-- * 'Bcc.Wallet.Server' contains the main server;
-- * 'Bcc.Wallet.API.V1.Handlers' contains all the @Handler@s serving the V1 API;
-- * 'Bcc.Wallet.API.Internal.Handlers' contains all the @Handler@s serving the Internal API;

type WalletAPI = LoggingApi WalletLoggingConfig (V1API :<|> InternalAPI)
walletAPI :: Proxy WalletAPI
walletAPI = Proxy

type WalletDoc = "docs" :> "v1" :> SwaggerSchemaUI "index" "swagger.json"
walletDoc :: Proxy WalletDoc
walletDoc = Proxy
walletDocAPI :: Proxy (V1API :<|> InternalAPI)
walletDocAPI = Proxy


type V1API = "api" :> "v1" :> V1.API
v1API :: Proxy V1API
v1API = Proxy

type InternalAPI = "api" :> "internal" :> Internal.API
internalAPI :: Proxy InternalAPI
internalAPI = Proxy
