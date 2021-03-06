module Bcc.Wallet.API.V1.LegacyHandlers.Settings where

import           Universum

import           Bcc.Wallet.API.Response (WalletResponse, single)
import           Bcc.Wallet.API.V1.Migration
import           Bcc.Wallet.API.V1.Types as V1
import qualified Data.Text as T
import           Paths_bcc_sl_wallet_new (version)

import           Pos.Chain.Update (curSoftwareVersion)
import qualified Pos.Node.API as Node
import           Pos.Util.CompileInfo (compileInfo, ctiGitRevision)
import           Pos.Wallet.WalletMode (MonadBlockchainInfo,
                     blockchainSlotDuration)
import           Servant

-- | All the @Servant@ handlers for settings-specific operations.
handlers :: ( HasConfigurations
            , HasCompileInfo
            )
         => ServerT Node.SettingsAPI MonadV1
handlers = getSettings

-- Returns the @static@ settings for this wallet node,
-- like the slot duration or the current 'SoftwareVersion'.
getSettings :: (HasConfigurations, HasCompileInfo, MonadBlockchainInfo m)
            => m (WalletResponse NodeSettings)
getSettings = do
    settings <- NodeSettings <$> (V1.mkSlotDuration . fromIntegral <$> blockchainSlotDuration)
                             <*> pure (V1 curSoftwareVersion)
                             <*> pure version
                             <*> pure (T.replace "\n" mempty $ ctiGitRevision compileInfo)
    return $ single settings
