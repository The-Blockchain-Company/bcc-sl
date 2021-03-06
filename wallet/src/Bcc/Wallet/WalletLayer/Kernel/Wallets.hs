{-# LANGUAGE LambdaCase #-}
module Bcc.Wallet.WalletLayer.Kernel.Wallets (
      createWallet
    , updateWallet
    , updateWalletPassword
    , deleteWallet
    , getWallet
    , getWallets
    , getWalletUtxos
    , blundToResolvedBlock
    ) where

import           Universum

import           Control.Monad.Except (throwError)
import           Data.Coerce (coerce)

import           Pos.Chain.Txp (Utxo)
import           Pos.Core (mkCoin)
import           Pos.Core.NetworkMagic (NetworkMagic, makeNetworkMagic)
import           Pos.Core.Slotting (Timestamp)
import           Pos.Crypto.Signing

import qualified Bcc.Mnemonic as Mnemonic
import           Bcc.Wallet.API.V1.Types (V1 (..))
import qualified Bcc.Wallet.API.V1.Types as V1
import           Bcc.Wallet.Kernel.Addresses (newHdAddress)
import           Bcc.Wallet.Kernel.DB.AcidState (dbHdWallets)
import qualified Bcc.Wallet.Kernel.DB.HdWallet as HD
import           Bcc.Wallet.Kernel.DB.InDb (fromDb)
import qualified Bcc.Wallet.Kernel.DB.TxMeta.Types as Kernel
import           Bcc.Wallet.Kernel.DB.Util.IxSet (IxSet)
import qualified Bcc.Wallet.Kernel.DB.Util.IxSet as IxSet
import           Bcc.Wallet.Kernel.Internal (walletKeystore, walletMeta,
                     walletProtocolMagic, _wriProgress)
import qualified Bcc.Wallet.Kernel.Internal as Kernel
import qualified Bcc.Wallet.Kernel.Keystore as Keystore
import qualified Bcc.Wallet.Kernel.Read as Kernel
import           Bcc.Wallet.Kernel.Restore (blundToResolvedBlock,
                     restoreWallet)
import           Bcc.Wallet.Kernel.Types (WalletId (..))
import           Bcc.Wallet.Kernel.Util.Core (getCurrentTimestamp)
import qualified Bcc.Wallet.Kernel.Wallets as Kernel
import           Bcc.Wallet.WalletLayer (CreateWallet (..),
                     CreateWalletError (..), DeleteWalletError (..),
                     GetUtxosError (..), GetWalletError (..),
                     UpdateWalletError (..), UpdateWalletPasswordError (..))
import           Bcc.Wallet.WalletLayer.Kernel.Conv

createWallet :: MonadIO m
             => Kernel.PassiveWallet
             -> CreateWallet
             -> m (Either CreateWalletError V1.Wallet)
createWallet wallet newWalletRequest = liftIO $ do
    let nm = makeNetworkMagic $ wallet ^. walletProtocolMagic
    now  <- liftIO getCurrentTimestamp
    case newWalletRequest of
        CreateWallet newWallet@V1.NewWallet{..} ->
            case newwalOperation of
                V1.RestoreWallet -> restore nm newWallet now
                V1.CreateWallet  -> create newWallet now
        ImportWalletFromESK esk mbSpendingPassword ->
            restoreFromESK nm
                           esk
                           (spendingPassword mbSpendingPassword)
                           now
                           "Imported Wallet"
                           HD.AssuranceLevelNormal
  where
    create :: V1.NewWallet -> Timestamp -> IO (Either CreateWalletError V1.Wallet)
    create newWallet@V1.NewWallet{..} now = runExceptT $ do
      root <- withExceptT CreateWalletError $ ExceptT $
                Kernel.createHdWallet wallet
                                      (mnemonic newWallet)
                                      (spendingPassword newwalSpendingPassword)
                                      (fromAssuranceLevel newwalAssuranceLevel)
                                      (HD.WalletName newwalName)
      return (mkRoot newwalName newwalAssuranceLevel now root)

    restore :: NetworkMagic
            -> V1.NewWallet
            -> Timestamp
            -> IO (Either CreateWalletError V1.Wallet)
    restore nm newWallet@V1.NewWallet{..} now = do
        let esk    = snd $ safeDeterministicKeyGen
                             (Mnemonic.mnemonicToSeed (mnemonic newWallet))
                             (spendingPassword newwalSpendingPassword)
        restoreFromESK nm
                       esk
                       (spendingPassword newwalSpendingPassword)
                       now
                       newwalName
                       (fromAssuranceLevel newwalAssuranceLevel)

    restoreFromESK :: NetworkMagic
                   -> EncryptedSecretKey
                   -> PassPhrase
                   -> Timestamp
                   -> Text
                   -> HD.AssuranceLevel
                   -> IO (Either CreateWalletError V1.Wallet)
    restoreFromESK nm esk pwd now walletName hdAssuranceLevel = runExceptT $ do
        let rootId = HD.eskToHdRootId nm esk
            wId    = WalletIdHdRnd rootId

        -- Insert the 'EncryptedSecretKey' into the 'Keystore'
        liftIO $ Keystore.insert wId esk (wallet ^. walletKeystore)

        -- Synchronously restore the wallet balance, and begin to
        -- asynchronously reconstruct the wallet's history.
        let mbHdAddress = newHdAddress nm
                                       esk
                                       pwd
                                       (Kernel.defaultHdAccountId rootId)
                                       (Kernel.defaultHdAddressId rootId)
        case mbHdAddress of
            Nothing -> throwError (CreateWalletError Kernel.CreateWalletDefaultAddressDerivationFailed)
            Just hdAddress -> do
                (root, coins) <- withExceptT (CreateWalletError . Kernel.CreateWalletFailed) $ ExceptT $
                    restoreWallet
                      wallet
                      (pwd /= emptyPassphrase)
                      (Just (hdAddress ^. HD.hdAddressAddress . fromDb))
                      (HD.WalletName walletName)
                      hdAssuranceLevel
                      esk

                -- Return the wallet information, with an updated balance.
                let root' = mkRoot walletName (toAssuranceLevel hdAssuranceLevel) now root
                updateSyncState wallet wId (root' { V1.walBalance = V1 coins })

    mkRoot :: Text -> V1.AssuranceLevel -> Timestamp -> HD.HdRoot -> V1.Wallet
    mkRoot v1WalletName v1AssuranceLevel now hdRoot = V1.Wallet {
          walId                         = walletId
        , walName                       = v1WalletName
        , walBalance                    = V1 (mkCoin 0)
        , walHasSpendingPassword        = hasSpendingPassword
        , walSpendingPasswordLastUpdate = V1 lastUpdate
        , walCreatedAt                  = V1 createdAt
        , walAssuranceLevel             = v1AssuranceLevel
        , walSyncState                  = V1.Synced
        }
      where
        (hasSpendingPassword, mbLastUpdate) =
            case hdRoot ^. HD.hdRootHasPassword of
                 HD.NoSpendingPassword     -> (False, Nothing)
                 HD.HasSpendingPassword lu -> (True, Just (lu ^. fromDb))
        lastUpdate = fromMaybe now mbLastUpdate
        createdAt  = hdRoot ^. HD.hdRootCreatedAt . fromDb
        walletId   = toRootId $ hdRoot ^. HD.hdRootId

    mnemonic (V1.NewWallet (V1.BackupPhrase m) _ _ _ _) = m
    spendingPassword = maybe emptyPassphrase coerce


-- | Updates the 'SpendingPassword' for this wallet.
updateWallet :: MonadIO m
             => Kernel.PassiveWallet
             -> V1.WalletId
             -> V1.WalletUpdate
             -> m (Either UpdateWalletError V1.Wallet)
updateWallet wallet wId (V1.WalletUpdate v1Level v1Name) = runExceptT $ do
    rootId <- withExceptT UpdateWalletWalletIdDecodingFailed $ fromRootId wId
    v1wal <- fmap (uncurry toWallet) $
               withExceptT UpdateWalletError $ ExceptT $ liftIO $
                 Kernel.updateHdWallet wallet rootId newLevel newName
    updateSyncState wallet (WalletIdHdRnd rootId) v1wal
  where
    newLevel = fromAssuranceLevel v1Level
    newName  = HD.WalletName v1Name

-- | Updates the 'SpendingPassword' for this wallet.
updateWalletPassword :: MonadIO m
                     => Kernel.PassiveWallet
                     -> V1.WalletId
                     -> V1.PasswordUpdate
                     -> m (Either UpdateWalletPasswordError V1.Wallet)
updateWalletPassword wallet
                     wId
                     (V1.PasswordUpdate
                       (V1 oldPwd)
                       (V1 newPwd)) = runExceptT $ do
    rootId <- withExceptT UpdateWalletPasswordWalletIdDecodingFailed $
                fromRootId wId
    v1wal <- fmap (uncurry toWallet) $
              withExceptT UpdateWalletPasswordError $ ExceptT $ liftIO $
                Kernel.updatePassword wallet rootId oldPwd newPwd
    updateSyncState wallet (WalletIdHdRnd rootId) v1wal

-- | Deletes a wallet, together with every account & addresses belonging to it.
-- If this wallet was restoring, then the relevant async worker is correctly
-- canceled.
deleteWallet :: MonadIO m
             => Kernel.PassiveWallet
             -> V1.WalletId
             -> m (Either DeleteWalletError ())
deleteWallet wallet wId = runExceptT $ do
    rootId <- withExceptT DeleteWalletWalletIdDecodingFailed $ fromRootId wId
    withExceptT DeleteWalletError $ ExceptT $ liftIO $ do
        let nm = makeNetworkMagic (wallet ^. walletProtocolMagic)
        let walletId = HD.getHdRootId rootId ^. fromDb
        Kernel.removeRestoration wallet (WalletIdHdRnd rootId)
        Kernel.deleteTxMetas (wallet ^. walletMeta) walletId Nothing
        Kernel.deleteHdWallet nm wallet rootId

-- | Gets a specific wallet.
getWallet :: MonadIO m
          => Kernel.PassiveWallet
          -> V1.WalletId
          -> Kernel.DB
          -> m (Either GetWalletError V1.Wallet)
getWallet wallet wId db = runExceptT $ do
    rootId <- withExceptT GetWalletWalletIdDecodingFailed (fromRootId wId)
    v1wal <- fmap (toWallet db) $
                withExceptT GetWalletError $ exceptT $
                    Kernel.lookupHdRootId db rootId
    updateSyncState wallet (WalletIdHdRnd rootId) v1wal

-- | Gets all the wallets known to this edge node.
--
-- NOTE: The wallet sync state is not set here; use 'updateSyncState' to
--       get a correct result.
--
-- TODO: Avoid IxSet creation [CBR-347].
getWallets :: MonadIO m
           => Kernel.PassiveWallet
           -> Kernel.DB
           -> m (IxSet V1.Wallet)
getWallets wallet db =
    fmap IxSet.fromList $ forM (IxSet.toList allRoots) $ \root -> do
        let rootId = root ^. HD.hdRootId
        updateSyncState wallet (WalletIdHdRnd rootId) (toWallet db root)
  where
    allRoots = db ^. dbHdWallets . HD.hdWalletsRoots

-- | Gets Utxos per account of a wallet.
getWalletUtxos
    :: V1.WalletId
    -> Kernel.DB
    -> Either GetUtxosError [(V1.Account, Utxo)]
getWalletUtxos wId db = runExcept $ do
    rootId <- withExceptT GetUtxosWalletIdDecodingFailed $
        fromRootId wId

    withExceptT GetUtxosGetAccountsError $ exceptT $ do
        _rootExists <- Kernel.lookupHdRootId db rootId
        return ()

    let accounts = Kernel.accountsByRootId db rootId

    forM (IxSet.toList accounts) $ \account ->
        withExceptT GetUtxosCurrentAvailableUtxoError $ exceptT $ do
            utxo <- Kernel.currentAvailableUtxo db (account ^. HD.hdAccountId)
            return (toAccount db account, utxo)

updateSyncState :: MonadIO m
                => Kernel.PassiveWallet
                -> WalletId
                -> V1.Wallet
                -> m V1.Wallet
updateSyncState wallet wId v1wal = liftIO $ do
    wss      <- Kernel.lookupRestorationInfo wallet wId
    progress <- traverse _wriProgress wss
    return v1wal { V1.walSyncState = toSyncState progress }
