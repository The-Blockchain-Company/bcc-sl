{-# LANGUAGE ConstraintKinds     #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections       #-}
{-# LANGUAGE TypeOperators       #-}

-- API server logic

module Pos.Explorer.Web.Server
       ( explorerServeImpl
       , explorerApp
       , explorerHandlers

       -- pure functions
       , getBlockDifficulty
       , roundToBlockPage

       -- api functions
       , getBlocksTotal
       , getBlocksPagesTotal
       , getBlocksPage
       , getEpochSlot
       , getEpochPage

       -- function useful for socket-io server
       , topsortTxsOrFail
       , getMempoolTxs
       , getBlocksLastPage
       , getEpochPagesOrThrow
       , cAddrToAddr
       ) where

import           Universum hiding (id)

import           Control.Lens (at)
import qualified Data.ByteString as BS
import qualified Data.HashMap.Strict as HM
import qualified Data.List.NonEmpty as NE
import           Data.Maybe (fromMaybe)
import qualified Data.Vector as V
import           Formatting (build, int, sformat, (%))
import           Network.Wai (Application)
import           Network.Wai.Middleware.RequestLogger (logStdoutDev)

import qualified Serokell.Util.Base64 as B64
import           Servant.API.Generic (toServant)
import           Servant.Server (Server, ServerT, err405, errReasonPhrase,
                     serve)
import           Servant.Server.Generic (AsServerT)

import           Pos.Crypto (WithHash (..), hash, redeemPkBuild, withHash)

import           Pos.DB.Block (getBlund, resolveForwardLink)
import           Pos.DB.Class (MonadDBRead)

import           Pos.Infra.Diffusion.Types (Diffusion)

import           Pos.Binary.Class (biSize)
import           Pos.Chain.Block (Block, Blund, HeaderHash, MainBlock, Undo,
                     gbHeader, gbhConsensus, mainBlockSlot, mainBlockTxPayload,
                     mcdSlot, headerHash)
import           Pos.Chain.Genesis as Genesis (Config (..), GenesisHash,
                     configEpochSlots)
import           Pos.Chain.Txp (Tx (..), TxAux, TxId, TxIn (..), TxMap,
                     TxOutAux (..), mpLocalTxs, taTx, topsortTxs, txOutAddress,
                     txOutValue, txpTxs, _txOutputs)
import           Pos.Core (AddrType (..), Address (..), Coin, EpochIndex,
                     SlotCount, Timestamp, coinToInteger, difficultyL,
                     getChainDifficulty, isUnknownAddressType,
                     makeRedeemAddress, siEpoch, siSlot, sumCoins,
                     timestampToPosix, unsafeAddCoin, unsafeIntegerToCoin,
                     unsafeSubCoin)
import           Pos.Core.Chrono (NewestFirst (..))
import           Pos.Core.NetworkMagic (NetworkMagic, makeNetworkMagic)
import           Pos.DB.Txp (MonadTxpMem, getFilteredUtxo, getLocalTxs,
                     getMemPool, withTxpLocalData)
import           Pos.Infra.Slotting (MonadSlots (..), getSlotStart)
import           Pos.Util (divRoundUp, maybeThrow)
import           Pos.Util.Wlog (logDebug)
import           Pos.Web (serveImpl)

import           Pos.Explorer.Aeson.ClientTypes ()
import           Pos.Explorer.Core (TxExtra (..))
import           Pos.Explorer.DB (Page)
import qualified Pos.Explorer.DB as ExDB
import           Pos.Explorer.ExplorerMode (ExplorerMode)
import           Pos.Explorer.ExtraContext (HasExplorerCSLInterface (..),
                     HasGenesisRedeemAddressInfo (..))
import           Pos.Explorer.Web.Api (ExplorerApi, ExplorerApiRecord (..),
                     explorerApi)
import           Pos.Explorer.Web.ClientTypes (Byte, CBcc (..), CAddress (..),
                     CAddressSummary (..), CAddressType (..),
                     CAddressesFilter (..), CBlockEntry (..),
                     CBlockSummary (..), CByteString (..),
                     CGenesisAddressInfo (..), CGenesisSummary (..), CHash,
                     CTxBrief (..), CTxEntry (..), CTxId (..), CTxSummary (..), CBlockRange (..),
                     CUtxo (..), TxInternal (..), convertTxOutputs,
                     convertTxOutputsMB, fromCAddress, fromCHash, fromCTxId,
                     getEpochIndex, getSlotIndex, mkCCoin, mkCCoinMB,
                     tiToTxEntry, toBlockEntry, toBlockSummary, toCAddress,
                     toCHash, toCTxId, toTxBrief)
import           Pos.Explorer.Web.Error (ExplorerError (..))

import qualified Data.Map as M
import           Pos.Configuration (explorerExtendedApi)


----------------------------------------------------------------
-- Top level functionality
----------------------------------------------------------------

type MainBlund = (MainBlock, Undo)

explorerServeImpl
    :: ExplorerMode ctx m
    => m Application
    -> Word16
    -> m ()
explorerServeImpl app port = serveImpl loggingApp "*" port Nothing Nothing Nothing
  where
    loggingApp = logStdoutDev <$> app

explorerApp :: ExplorerMode ctx m => m (Server ExplorerApi) -> m Application
explorerApp serv = serve explorerApi <$> serv

----------------------------------------------------------------
-- Handlers
----------------------------------------------------------------

explorerHandlers
    :: forall ctx m. ExplorerMode ctx m
    => Genesis.Config -> Diffusion m -> ServerT ExplorerApi m
explorerHandlers genesisConfig _diffusion =
    toServant (ExplorerApiRecord
        { _totalBcc           = getTotalBcc
        , _blocksPages        = getBlocksPage epochSlots
        , _dumpBlockRange     = getBlockRange genesisConfig
        , _blocksPagesTotal   = getBlocksPagesTotal
        , _blocksSummary      = getBlockSummary genesisConfig
        , _blocksTxs          = getBlockTxs genesisHash
        , _txsLast            = getLastTxs
        , _txsSummary         = getTxSummary genesisHash
        , _addressSummary     = getAddressSummary nm genesisHash
        , _addressUtxoBulk    = getAddressUtxoBulk nm
        , _epochPages         = getEpochPage epochSlots
        , _epochSlots         = getEpochSlot epochSlots
        , _genesisSummary     = getGenesisSummary
        , _genesisPagesTotal  = getGenesisPagesTotal
        , _genesisAddressInfo = getGenesisAddressInfo
        , _statsTxs           = getStatsTxs genesisConfig
        }
        :: ExplorerApiRecord (AsServerT m))
  where
    nm :: NetworkMagic
    nm = makeNetworkMagic $ configProtocolMagic genesisConfig
    --
    epochSlots = configEpochSlots genesisConfig
    --
    genesisHash = configGenesisHash genesisConfig

----------------------------------------------------------------
-- API Functions
----------------------------------------------------------------

getTotalBcc :: ExplorerMode ctx m => m CBcc
getTotalBcc = do
    utxoSum <- ExDB.getUtxoSum
    validateUtxoSum utxoSum
    pure $ CBcc $ fromInteger utxoSum / 1e6
  where
    validateUtxoSum :: ExplorerMode ctx m => Integer -> m ()
    validateUtxoSum n
        | n < 0 = throwM $ Internal $
            sformat ("Internal tracker of utxo sum has a negative value: "%build) n
        | n > coinToInteger (maxBound :: Coin) = throwM $ Internal $
            sformat ("Internal tracker of utxo sum overflows: "%build) n
        | otherwise = pure ()

-- | Get the total number of blocks/slots currently available.
-- Total number of main blocks   = difficulty of the topmost (tip) header.
-- Total number of anchor blocks = current epoch + 1
getBlocksTotal
    :: ExplorerMode ctx m
    => m Integer
getBlocksTotal = do
    -- Get the tip block.
    tipBlock <- getTipBlockCSLI
    pure $ getBlockDifficulty tipBlock


-- | Get last blocks with a page parameter. This enables easier paging on the
-- client side and should enable a simple and thin client logic.
-- Currently the pages are in chronological order.
getBlocksPage
    :: ExplorerMode ctx m
    => SlotCount
    -> Maybe Word -- ^ Page number
    -> Maybe Word -- ^ Page size
    -> m (Integer, [CBlockEntry])
getBlocksPage epochSlots mPageNumber mPageSize = do

    let pageSize = toPageSize mPageSize

    -- Get total pages from the blocks.
    totalPages <- getBlocksPagesTotal mPageSize

    -- Initially set on the last page number if page number not defined.
    let pageNumber = fromMaybe totalPages $ toInteger <$> mPageNumber

    -- Make sure the parameters are valid.
    when (pageNumber <= 0) $
        throwM $ Internal "Number of pages must be greater than 0."

    when (pageNumber > totalPages) $
        throwM $ Internal "Number of pages exceeds total pages number."

    -- TODO: Fix in the future.
    when (pageSize /= fromIntegral ExDB.defaultPageSize) $
        throwM $ Internal "We currently support only page size of 10."

    when (pageSize > 1000) $
        throwM $ Internal "The upper bound for pageSize is 1000."

    -- Get pages from the database
    -- TODO: Fix this Int / Integer thing once we merge repositories
    pageBlocksHH    <- getPageHHsOrThrow $ fromIntegral pageNumber
    blunds          <- forM pageBlocksHH getBlundOrThrow
    cBlocksEntry    <- forM (blundToMainBlockUndo blunds) (toBlockEntry epochSlots)

    -- Return total pages and the blocks. We start from page 1.
    pure (totalPages, reverse cBlocksEntry)
  where
    blundToMainBlockUndo :: [Blund] -> [(MainBlock, Undo)]
    blundToMainBlockUndo blund = [(mainBlock, undo) | (Right mainBlock, undo) <- blund]

    -- Either get the @HeaderHash@es from the @Page@ or throw an exception.
    getPageHHsOrThrow
        :: ExplorerMode ctx m
        => Int
        -> m [HeaderHash]
    getPageHHsOrThrow pageNumber =
        -- Then let's fetch blocks for a specific page from it and raise exception if not
        -- found.
        getPageBlocksCSLI pageNumber >>= maybeThrow (Internal errMsg)
      where
        errMsg :: Text
        errMsg = sformat ("No blocks on page "%build%" found!") pageNumber

-- | Get total pages from blocks. Calculated from
-- pageSize we pass to it.
getBlocksPagesTotal
    :: ExplorerMode ctx m
    => Maybe Word
    -> m Integer
getBlocksPagesTotal mPageSize = do

    let pageSize = toPageSize mPageSize

    -- Get total blocks in the blockchain. Get the blocks total using this mode.
    blocksTotal <- toInteger <$> getBlocksTotal

    -- Make sure the parameters are valid.
    when (blocksTotal < 1) $
        throwM $ Internal "There are currently no block to display."

    when (pageSize < 1) $
        throwM $ Internal "Page size must be greater than 1 if you want to display blocks."

    -- We start from page 1.
    let pagesTotal = roundToBlockPage blocksTotal

    pure pagesTotal


-- | Get the last page from the blockchain. We use the default 10
-- for the page size since this is called from __explorer only__.
getBlocksLastPage
    :: ExplorerMode ctx m
    => SlotCount -> m (Integer, [CBlockEntry])
getBlocksLastPage epochSlots =
    getBlocksPage epochSlots Nothing (Just defaultPageSizeWord)


-- | Get last transactions from the blockchain.
getLastTxs
    :: ExplorerMode ctx m
    => m [CTxEntry]
getLastTxs = do
    mempoolTxs     <- getMempoolTxs
    blockTxsWithTs <- getBlockchainLastTxs

    -- We take the mempool txs first, then topsorted blockchain ones.
    let newTxs      = mempoolTxs <> blockTxsWithTs

    pure $ tiToTxEntry <$> newTxs
  where
    -- Get last transactions from the blockchain.
    getBlockchainLastTxs
        :: ExplorerMode ctx m
        => m [TxInternal]
    getBlockchainLastTxs = do
        mLastTxs     <- ExDB.getLastTransactions
        let lastTxs   = fromMaybe [] mLastTxs
        let lastTxsWH = map withHash lastTxs

        forM lastTxsWH toTxInternal
      where
        -- Convert transaction to TxInternal.
        toTxInternal
            :: (MonadThrow m, MonadDBRead m)
            => WithHash Tx
            -> m TxInternal
        toTxInternal (WithHash tx txId) = do
            extra <- ExDB.getTxExtra txId >>=
                maybeThrow (Internal "No extra info for tx in DB!")
            pure $ TxInternal extra tx


-- | Get block summary.
getBlockSummary
    :: ExplorerMode ctx m
    => Genesis.Config
    -> CHash
    -> m CBlockSummary
getBlockSummary genesisConfig cHash = do
    hh <- unwrapOrThrow $ fromCHash cHash
    mainBlund  <- getMainBlund (configGenesisHash genesisConfig) hh
    toBlockSummary (configEpochSlots genesisConfig) mainBlund


-- | Get transactions from a block.
getBlockTxs
    :: ExplorerMode ctx m
    => GenesisHash
    -> CHash
    -> Maybe Word
    -> Maybe Word
    -> m [CTxBrief]
getBlockTxs genesisHash cHash mLimit mSkip = do
    let limit = fromIntegral $ fromMaybe defaultPageSizeWord mLimit
    let skip = fromIntegral $ fromMaybe 0 mSkip
    txs <- getMainBlockTxs genesisHash cHash

    forM (take limit . drop skip $ txs) $ \tx -> do
        extra <- ExDB.getTxExtra (hash tx) >>=
                 maybeThrow (Internal "In-block transaction doesn't \
                                      \have extra info in DB")
        pure $ makeTxBrief tx extra


-- | Get address summary. Can return several addresses.
-- @PubKeyAddress@, @ScriptAddress@, @RedeemAddress@ and finally
-- @UnknownAddressType@.
getAddressSummary
    :: ExplorerMode ctx m
    => NetworkMagic
    -> GenesisHash
    -> CAddress
    -> m CAddressSummary
getAddressSummary nm genesisHash cAddr = do
    addr <- cAddrToAddr nm cAddr

    when (isUnknownAddressType addr) $
        throwM $ Internal "Unknown address type"

    balance <- mkCCoin . fromMaybe minBound <$> ExDB.getAddrBalance addr
    txIds <- getNewestFirst <$> ExDB.getAddrHistory addr

    let nTxs = length txIds

    -- FIXME [CBR-119] Waiting for design discussion
    when (nTxs > 1000) $
        throwM $ Internal $ "Response too large: no more than 1000 transactions"
            <> " can be returned at once. This issue is known and being worked on"

    transactions <- forM txIds $ \id -> do
        extra <- getTxExtraOrFail id
        tx <- getTxMain genesisHash id extra
        pure $ makeTxBrief tx extra

    pure CAddressSummary {
        caAddress = cAddr,
        caType = getAddressType addr,
        caTxNum = fromIntegral $ length transactions,
        caBalance = balance,
        caTxList = transactions
    }
  where
    getAddressType :: Address -> CAddressType
    getAddressType Address {..} =
        case addrType of
            ATPubKey     -> CPubKeyAddress
            ATScript     -> CScriptAddress
            ATRedeem     -> CRedeemAddress
            ATUnknown {} -> CUnknownAddress


getAddressUtxoBulk
    :: (ExplorerMode ctx m)
    => NetworkMagic
    -> [CAddress]
    -> m [CUtxo]
getAddressUtxoBulk nm cAddrs = do
    unless explorerExtendedApi $
        throwM err405
        { errReasonPhrase = "Explorer extended API is disabled by configuration!"
        }

    let nAddrs = length cAddrs

    when (nAddrs > 10) $
        throwM err405
        { errReasonPhrase = "Maximum number of addresses you can send to fetch Utxo in bulk is 10!"
        }

    addrs <- mapM (cAddrToAddr nm) cAddrs
    utxo <- getFilteredUtxo addrs

    pure . map futxoToCUtxo . M.toList $ utxo
  where
    futxoToCUtxo :: (TxIn, TxOutAux) -> CUtxo
    futxoToCUtxo ((TxInUtxo txInHash txInIndex), txOutAux) = CUtxo {
        cuId = toCTxId txInHash,
        cuOutIndex = fromIntegral txInIndex,
        cuAddress = toCAddress . txOutAddress . toaOut $ txOutAux,
        cuCoins = mkCCoin . txOutValue . toaOut $ txOutAux
    }
    futxoToCUtxo ((TxInUnknown tag bs), _) = CUtxoUnknown {
        cuTag = fromIntegral tag,
        cuBs = CByteString bs
    }

getBlockRange
    :: ExplorerMode ctx m
    => Genesis.Config
    -> CHash
    -> CHash
    -> m CBlockRange
getBlockRange genesisConfig start stop = do
    startHeaderHash <- unwrapOrThrow $ fromCHash start
    stopHeaderHash <- unwrapOrThrow $ fromCHash stop
    let
      getTxSummaryFromBlock
          :: (ExplorerMode ctx m)
          => MainBlock
          -> Tx
          -> m CTxSummary
      getTxSummaryFromBlock mb tx = do
          let txId = hash tx
          txExtra                <- getTxExtraOrFail txId

          blkSlotStart           <- getBlkSlotStart mb

          let
            blockTime           = timestampToPosix <$> blkSlotStart
            inputOutputsMB      = map (fmap toaOut) $ NE.toList $ teInputOutputs txExtra
            txOutputs           = convertTxOutputs . NE.toList $ _txOutputs tx
            totalInputMB        = unsafeIntegerToCoin . sumCoins . map txOutValue <$> sequence inputOutputsMB
            totalOutput         = unsafeIntegerToCoin $ sumCoins $ map snd txOutputs

          -- Verify that strange things don't happen with transactions
          whenJust totalInputMB $ \totalInput -> when (totalOutput > totalInput) $
              throwM $ Internal "Detected tx with output greater than input"

          pure $ CTxSummary
              { ctsId              = toCTxId txId
              , ctsTxTimeIssued    = timestampToPosix <$> teReceivedTime txExtra
              , ctsBlockTimeIssued = blockTime
              , ctsBlockHeight     = Nothing
              , ctsBlockEpoch      = Nothing
              , ctsBlockSlot       = Nothing
              , ctsBlockHash       = Just $ toCHash $ headerHash mb
              , ctsRelayedBy       = Nothing
              , ctsTotalInput      = mkCCoinMB totalInputMB
              , ctsTotalOutput     = mkCCoin totalOutput
              , ctsFees            = mkCCoinMB $ (`unsafeSubCoin` totalOutput) <$> totalInputMB
              , ctsInputs          = map (fmap (second mkCCoin)) $ convertTxOutputsMB inputOutputsMB
              , ctsOutputs         = map (second mkCCoin) txOutputs
              }
      genesisHash = configGenesisHash genesisConfig
      go :: ExplorerMode ctx m => HeaderHash -> CBlockRange -> m CBlockRange
      go hh state1 = do
        maybeBlund <- getBlund genesisHash hh
        newState <- case maybeBlund of
          Just (Right blk', undo) -> do
            let
              txs :: [Tx]
              txs = blk' ^. mainBlockTxPayload . txpTxs
            blockSum <- toBlockSummary (configEpochSlots genesisConfig) (blk',undo)
            let
              state2 = state1 { cbrBlocks = blockSum : (cbrBlocks state1) }
              iterateTx :: ExplorerMode ctx m => CBlockRange -> Tx -> m CBlockRange
              iterateTx stateIn tx = do
                txSummary <- getTxSummaryFromBlock blk' tx
                pure $ stateIn { cbrTransactions = txSummary : (cbrTransactions stateIn) }
            foldM iterateTx state2 txs
          _ -> pure state1
        if hh == stopHeaderHash then
          pure newState
        else do
          nextHh <- resolveForwardLink hh
          case nextHh of
            Nothing -> do
              pure newState
            Just nextHh' -> go nextHh' newState
    backwards <- go startHeaderHash (CBlockRange [] [])
    pure $ CBlockRange
      { cbrBlocks = reverse $ cbrBlocks backwards
      , cbrTransactions = reverse $ cbrTransactions backwards
      }


-- | Get transaction summary from transaction id. Looks at both the database
-- and the memory (mempool) for the transaction. What we have at the mempool
-- are transactions that have to be written in the blockchain.
getTxSummary
    :: ExplorerMode ctx m
    => GenesisHash
    -> CTxId
    -> m CTxSummary
getTxSummary genesisHash cTxId = do
    -- There are two places whence we can fetch a transaction: MemPool and DB.
    -- However, TxExtra should be added in the DB when a transaction is added
    -- to MemPool. So we start with TxExtra and then figure out whence to fetch
    -- the rest.
    txId                   <- cTxIdToTxId cTxId
    -- Get from database, @TxExtra
    txExtra                <- ExDB.getTxExtra txId

    -- If we found @TxExtra@ that means we found something saved on the
    -- blockchain and we don't have to fetch @MemPool@. But if we don't find
    -- anything on the blockchain, we go searching in the @MemPool@.
    if isJust txExtra
      then getTxSummaryFromBlockchain cTxId
      else getTxSummaryFromMemPool cTxId

  where
    -- Get transaction from blockchain (the database).
    getTxSummaryFromBlockchain
        :: (ExplorerMode ctx m)
        => CTxId
        -> m CTxSummary
    getTxSummaryFromBlockchain cTxId' = do
        txId                   <- cTxIdToTxId cTxId'
        txExtra                <- getTxExtraOrFail txId

        -- Return transaction extra (txExtra) fields
        let mBlockchainPlace    = teBlockchainPlace txExtra
        blockchainPlace        <- maybeThrow (Internal "No blockchain place.") mBlockchainPlace

        let headerHashBP        = fst blockchainPlace
        let txIndexInBlock      = snd blockchainPlace

        mb                     <- getMainBlock genesisHash headerHashBP
        blkSlotStart           <- getBlkSlotStart mb

        let blockHeight         = fromIntegral $ mb ^. difficultyL
        let receivedTime        = teReceivedTime txExtra
        let blockTime           = timestampToPosix <$> blkSlotStart

        -- Get block epoch and slot index
        let blkHeaderSlot       = mb ^. mainBlockSlot
        let epochIndex          = getEpochIndex $ siEpoch blkHeaderSlot
        let slotIndex           = getSlotIndex  $ siSlot  blkHeaderSlot
        let blkHash             = toCHash headerHashBP

        tx <- maybeThrow (Internal "TxExtra return tx index that is out of bounds") $
              atMay (toList $ mb ^. mainBlockTxPayload . txpTxs) (fromIntegral txIndexInBlock)

        let inputOutputsMB      = map (fmap toaOut) $ NE.toList $ teInputOutputs txExtra
        let txOutputs           = convertTxOutputs . NE.toList $ _txOutputs tx

        let totalInputMB        = unsafeIntegerToCoin . sumCoins . map txOutValue <$> sequence inputOutputsMB
        let totalOutput         = unsafeIntegerToCoin $ sumCoins $ map snd txOutputs

        -- Verify that strange things don't happen with transactions
        whenJust totalInputMB $ \totalInput -> when (totalOutput > totalInput) $
            throwM $ Internal "Detected tx with output greater than input"

        pure $ CTxSummary
            { ctsId              = cTxId'
            , ctsTxTimeIssued    = timestampToPosix <$> receivedTime
            , ctsBlockTimeIssued = blockTime
            , ctsBlockHeight     = Just blockHeight
            , ctsBlockEpoch      = Just epochIndex
            , ctsBlockSlot       = Just slotIndex
            , ctsBlockHash       = Just blkHash
            , ctsRelayedBy       = Nothing
            , ctsTotalInput      = mkCCoinMB totalInputMB
            , ctsTotalOutput     = mkCCoin totalOutput
            , ctsFees            = mkCCoinMB $ (`unsafeSubCoin` totalOutput) <$> totalInputMB
            , ctsInputs          = map (fmap (second mkCCoin)) $ convertTxOutputsMB inputOutputsMB
            , ctsOutputs         = map (second mkCCoin) txOutputs
            }

    -- Get transaction from mempool (the memory).
    getTxSummaryFromMemPool
        :: (ExplorerMode ctx m)
        => CTxId
        -> m CTxSummary
    getTxSummaryFromMemPool cTxId' = do
        txId                   <- cTxIdToTxId cTxId'
        tx                     <- fetchTxFromMempoolOrFail txId

        let inputOutputs        = NE.toList . _txOutputs $ taTx tx
        let txOutputs           = convertTxOutputs inputOutputs

        let totalInput          = unsafeIntegerToCoin $ sumCoins $ map txOutValue inputOutputs
        let totalOutput         = unsafeIntegerToCoin $ sumCoins $ map snd txOutputs

        -- Verify that strange things don't happen with transactions
        when (totalOutput > totalInput) $
            throwM $ Internal "Detected tx with output greater than input"

        pure $ CTxSummary
            { ctsId              = cTxId'
            , ctsTxTimeIssued    = Nothing
            , ctsBlockTimeIssued = Nothing
            , ctsBlockHeight     = Nothing
            , ctsBlockEpoch      = Nothing
            , ctsBlockSlot       = Nothing
            , ctsBlockHash       = Nothing
            , ctsRelayedBy       = Nothing
            , ctsTotalInput      = mkCCoin totalInput
            , ctsTotalOutput     = mkCCoin totalOutput
            , ctsFees            = mkCCoin $ unsafeSubCoin totalInput totalOutput
            , ctsInputs          = map (Just . second mkCCoin) $ convertTxOutputs inputOutputs
            , ctsOutputs         = map (second mkCCoin) txOutputs
            }

data GenesisSummaryInternal = GenesisSummaryInternal
    { gsiNumRedeemed            :: !Int
    , gsiRedeemedAmountTotal    :: !Coin
    , gsiNonRedeemedAmountTotal :: !Coin
    }

getGenesisSummary
    :: ExplorerMode ctx m
    => m CGenesisSummary
getGenesisSummary = do
    grai <- getGenesisRedeemAddressInfo
    redeemAddressInfo <- V.mapM (uncurry getRedeemAddressInfo) grai
    let GenesisSummaryInternal {..} =
            V.foldr folder (GenesisSummaryInternal 0 minBound minBound)
            redeemAddressInfo
    let numTotal = length grai
    pure CGenesisSummary
        { cgsNumTotal = numTotal
        , cgsNumRedeemed = gsiNumRedeemed
        , cgsNumNotRedeemed = numTotal - gsiNumRedeemed
        , cgsRedeemedAmountTotal = mkCCoin gsiRedeemedAmountTotal
        , cgsNonRedeemedAmountTotal = mkCCoin gsiNonRedeemedAmountTotal
        }
  where
    getRedeemAddressInfo
        :: MonadDBRead m
        => Address -> Coin -> m GenesisSummaryInternal
    getRedeemAddressInfo address initialBalance = do
        currentBalance <- fromMaybe minBound <$> ExDB.getAddrBalance address
        if currentBalance > initialBalance then
            throwM $ Internal $ sformat
                ("Redeem address "%build%" had "%build%" at genesis, but now has "%build)
                address initialBalance currentBalance
        else
            -- Abusing gsiNumRedeemed here. We'd like to keep
            -- only one wrapper datatype, so we're storing an Int
            -- with a 0/1 value in a field that we call isRedeemed.
            let isRedeemed = if currentBalance == minBound then 1 else 0
                redeemedAmount = initialBalance `unsafeSubCoin` currentBalance
                amountLeft = currentBalance
            in pure $ GenesisSummaryInternal isRedeemed redeemedAmount amountLeft
    folder
        :: GenesisSummaryInternal
        -> GenesisSummaryInternal
        -> GenesisSummaryInternal
    folder
        (GenesisSummaryInternal isRedeemed redeemedAmount amountLeft)
        (GenesisSummaryInternal numRedeemed redeemedAmountTotal nonRedeemedAmountTotal) =
        GenesisSummaryInternal
            { gsiNumRedeemed = numRedeemed + isRedeemed
            , gsiRedeemedAmountTotal = redeemedAmountTotal `unsafeAddCoin` redeemedAmount
            , gsiNonRedeemedAmountTotal = nonRedeemedAmountTotal `unsafeAddCoin` amountLeft
            }

isAddressRedeemed :: MonadDBRead m => Address -> m Bool
isAddressRedeemed address = do
    currentBalance <- fromMaybe minBound <$> ExDB.getAddrBalance address
    pure $ currentBalance == minBound

getFilteredGrai :: ExplorerMode ctx m => CAddressesFilter -> m (V.Vector (Address, Coin))
getFilteredGrai addrFilt = do
    grai <- getGenesisRedeemAddressInfo
    case addrFilt of
            AllAddresses         ->
                pure grai
            RedeemedAddresses    ->
                V.filterM (isAddressRedeemed . fst) grai
            NonRedeemedAddresses ->
                V.filterM (isAddressNotRedeemed . fst) grai
  where
    isAddressNotRedeemed :: MonadDBRead m => Address -> m Bool
    isAddressNotRedeemed = fmap not . isAddressRedeemed

getGenesisAddressInfo
    :: (ExplorerMode ctx m)
    => Maybe Word  -- ^ pageNumber
    -> Maybe Word  -- ^ pageSize
    -> CAddressesFilter
    -> m [CGenesisAddressInfo]
getGenesisAddressInfo mPage mPageSize addrFilt = do
    filteredGrai <- getFilteredGrai addrFilt
    let pageNumber    = fromMaybe 1 $ fmap fromIntegral mPage
        pageSize      = fromIntegral $ toPageSize mPageSize
        skipItems     = (pageNumber - 1) * pageSize
        requestedPage = V.slice skipItems pageSize filteredGrai
    V.toList <$> V.mapM toGenesisAddressInfo requestedPage
  where
    toGenesisAddressInfo :: ExplorerMode ctx m => (Address, Coin) -> m CGenesisAddressInfo
    toGenesisAddressInfo (address, coin) = do
        cgaiIsRedeemed <- isAddressRedeemed address
        -- Commenting out RSCoin address until it can actually be displayed.
        -- See comment in src/Pos/Explorer/Web/ClientTypes.hs for more information.
        pure CGenesisAddressInfo
            { cgaiBccAddress = toCAddress address
            -- , cgaiRSCoinAddress  = toCAddress address
            , cgaiGenesisAmount  = mkCCoin coin
            , ..
            }

getGenesisPagesTotal
    :: ExplorerMode ctx m
    => Maybe Word
    -> CAddressesFilter
    -> m Integer
getGenesisPagesTotal mPageSize addrFilt = do
    filteredGrai <- getFilteredGrai addrFilt
    pure $ fromIntegral $ (length filteredGrai + pageSize - 1) `div` pageSize
  where
    pageSize = fromIntegral $ toPageSize mPageSize

-- | Search the blocks by epoch and slot.
getEpochSlot
    :: ExplorerMode ctx m
    => SlotCount
    -> EpochIndex
    -> Word16
    -> m [CBlockEntry]
getEpochSlot epochSlots epochIndex slotIndex = do

    -- The slots start from 0 so we need to modify the calculation of the index.
    let page = fromIntegral $ (slotIndex `div` 10) + 1

    -- Get pages from the database
    -- TODO: Fix this Int / Integer thing once we merge repositories
    epochBlocksHH   <- getPageHHsOrThrow epochIndex page
    blunds          <- forM epochBlocksHH getBlundOrThrow
    forM (getEpochSlots slotIndex (blundToMainBlockUndo blunds)) (toBlockEntry epochSlots)
  where
    blundToMainBlockUndo :: [Blund] -> [(MainBlock, Undo)]
    blundToMainBlockUndo blund = [(mainBlock, undo) | (Right mainBlock, undo) <- blund]
    -- Get epoch slot block that's being searched or return all epochs if
    -- the slot is @Nothing@.
    getEpochSlots
        :: Word16
        -> [MainBlund]
        -> [MainBlund]
    getEpochSlots slotIndex' blunds = filter filterBlundsBySlotIndex blunds
      where
        getBlundSlotIndex
            :: MainBlund
            -> Word16
        getBlundSlotIndex blund = getSlotIndex $ siSlot $ fst blund ^. mainBlockSlot

        filterBlundsBySlotIndex
            :: MainBlund
            -> Bool
        filterBlundsBySlotIndex blund = getBlundSlotIndex blund == slotIndex'

    -- Either get the @HeaderHash@es from the @Epoch@ or throw an exception.
    getPageHHsOrThrow
        :: (HasExplorerCSLInterface m, MonadThrow m)
        => EpochIndex
        -> Int
        -> m [HeaderHash]
    getPageHHsOrThrow epoch page =
        getEpochBlocksCSLI epoch page >>= maybeThrow (Internal errMsg)
      where
        errMsg :: Text
        errMsg = sformat ("No blocks on epoch "%build%" page "%build%" found!") epoch page

-- | Search the blocks by epoch and epoch page number.
getEpochPage
    :: ExplorerMode ctx m
    => SlotCount
    -> EpochIndex
    -> Maybe Int
    -> m (Int, [CBlockEntry])
getEpochPage epochSlots epochIndex mPage = do

    -- Get the page if it exists, return first page otherwise.
    let page = fromMaybe 1 mPage

    -- We want to fetch as many pages as we have in this @Epoch@.
    epochPagesNumber <- getEpochPagesOrThrow epochIndex

    -- Get pages from the database
    -- TODO: Fix this Int / Integer thing once we merge repositories
    epochBlocksHH       <- getPageHHsOrThrow epochIndex page
    blunds              <- forM epochBlocksHH getBlundOrThrow

    let sortedBlunds     = sortBlocksByEpochSlots blunds
    let sortedMainBlocks = blundToMainBlockUndo sortedBlunds

    cBlocksEntry        <- forM sortedMainBlocks (toBlockEntry epochSlots)

    pure (epochPagesNumber, cBlocksEntry)
  where
    blundToMainBlockUndo :: [Blund] -> [(MainBlock, Undo)]
    blundToMainBlockUndo blund = [(mainBlock, undo) | (Right mainBlock, undo) <- blund]

    -- Either get the @HeaderHash@es from the @Epoch@ or throw an exception.
    getPageHHsOrThrow
        :: (HasExplorerCSLInterface m, MonadThrow m)
        => EpochIndex
        -> Int
        -> m [HeaderHash]
    getPageHHsOrThrow epoch page' =
        getEpochBlocksCSLI epoch page' >>= maybeThrow (Internal errMsg)
      where
        errMsg :: Text
        errMsg = sformat ("No blocks on epoch "%build%" page "%build%" found!") epoch page'

    -- | Sorting.
    sortBlocksByEpochSlots
        :: [(Block, Undo)]
        -> [(Block, Undo)]
    sortBlocksByEpochSlots blocks = sortOn (Down . getBlockIndex . fst) blocks
      where
        -- | Get the block index number. We start with the the index 1 for the
        -- genesis block and add 1 for the main blocks since they start with 1
        -- as well.
        getBlockIndex :: Block -> Int
        getBlockIndex (Left _)      = 1
        getBlockIndex (Right block) =
            fromIntegral $ (+1) $ getSlotIndex $ siSlot $ block ^. mainBlockSlot

getStatsTxs
    :: forall ctx m. ExplorerMode ctx m
    => Genesis.Config
    -> Maybe Word
    -> m (Integer, [(CTxId, Byte)])
getStatsTxs genesisConfig mPageNumber = do
    -- Get blocks from the requested page
    blocksPage <- getBlocksPage (configEpochSlots genesisConfig)
                                mPageNumber
                                (Just defaultPageSizeWord)
    getBlockPageTxsInfo blocksPage
  where
    getBlockPageTxsInfo
        :: (Integer, [CBlockEntry])
        -> m (Integer, [(CTxId, Byte)])
    getBlockPageTxsInfo (blockPageNumber, cBlockEntries) = do
        blockTxsInfo <- blockPageTxsInfo
        pure (blockPageNumber, blockTxsInfo)
      where
        cHashes :: [CHash]
        cHashes = cbeBlkHash <$> cBlockEntries

        blockPageTxsInfo :: m [(CTxId, Byte)]
        blockPageTxsInfo = concatForM cHashes getBlockTxsInfo

        getBlockTxsInfo
            :: CHash
            -> m [(CTxId, Byte)]
        getBlockTxsInfo cHash = do
            txs <- getMainBlockTxs (configGenesisHash genesisConfig) cHash
            pure $ txToTxIdSize <$> txs
          where
            txToTxIdSize :: Tx -> (CTxId, Byte)
            txToTxIdSize tx = (toCTxId $ hash tx, biSize tx)


--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- | A pure calculation of the page number.
-- Get total pages from the blocks. And we want the page
-- with the example, the page size 10,
-- to start with 10 + 1 == 11, not with 10 since with
-- 10 we'll have an empty page.
-- Could also be `((blocksTotal - 1) `div` pageSizeInt) + 1`.
roundToBlockPage :: Integer -> Integer
roundToBlockPage blocksTotal = divRoundUp blocksTotal $ fromIntegral ExDB.defaultPageSize

-- | A pure function that return the number of blocks.
getBlockDifficulty :: Block -> Integer
getBlockDifficulty tipBlock = fromIntegral $ getChainDifficulty $ tipBlock ^. difficultyL

defaultPageSizeWord :: Word
defaultPageSizeWord = fromIntegral ExDB.defaultPageSize

toPageSize :: Maybe Word -> Integer
toPageSize = fromIntegral . fromMaybe defaultPageSizeWord

getMainBlockTxs :: ExplorerMode ctx m => GenesisHash -> CHash -> m [Tx]
getMainBlockTxs genesisHash cHash = do
    hash' <- unwrapOrThrow $ fromCHash cHash
    blk   <- getMainBlock genesisHash hash'
    topsortTxsOrFail withHash $ toList $ blk ^. mainBlockTxPayload . txpTxs

makeTxBrief :: Tx -> TxExtra -> CTxBrief
makeTxBrief tx extra = toTxBrief (TxInternal extra tx)

unwrapOrThrow :: ExplorerMode ctx m => Either Text a -> m a
unwrapOrThrow = either (throwM . Internal) pure

-- | Get transaction from memory (STM) or throw exception.
fetchTxFromMempoolOrFail :: ExplorerMode ctx m => TxId -> m TxAux
fetchTxFromMempoolOrFail txId = do
    memPoolTxs        <- localMemPoolTxs
    let memPoolTxsSize = HM.size memPoolTxs

    logDebug $ sformat ("Mempool size "%int%" found!") memPoolTxsSize

    let maybeTxAux = memPoolTxs ^. at txId
    maybeThrow (Internal "Transaction missing in MemPool!") maybeTxAux

  where
    -- type TxMap = HashMap TxId TxAux
    localMemPoolTxs
        :: (MonadIO m, MonadTxpMem ext ctx m)
        => m TxMap
    localMemPoolTxs = do
      memPool <- withTxpLocalData getMemPool
      pure $ memPool ^. mpLocalTxs

getMempoolTxs :: ExplorerMode ctx m => m [TxInternal]
getMempoolTxs = do

    localTxs <- fmap reverse $ topsortTxsOrFail mkWhTx =<< tlocalTxs

    fmap catMaybes . forM localTxs $ \(id, txAux) -> do
        mextra <- ExDB.getTxExtra id
        forM mextra $ \extra -> pure $ TxInternal extra (taTx txAux)
  where
    tlocalTxs :: (MonadIO m, MonadTxpMem ext ctx m) => m [(TxId, TxAux)]
    tlocalTxs = withTxpLocalData getLocalTxs

    mkWhTx :: (TxId, TxAux) -> WithHash Tx
    mkWhTx (txid, txAux) = WithHash (taTx txAux) txid

getBlkSlotStart :: MonadSlots ctx m => MainBlock -> m (Maybe Timestamp)
getBlkSlotStart blk = getSlotStart $ blk ^. gbHeader . gbhConsensus . mcdSlot

topsortTxsOrFail :: (MonadThrow m, Eq a) => (a -> WithHash Tx) -> [a] -> m [a]
topsortTxsOrFail f =
    maybeThrow (Internal "Dependency loop in txs set") .
    topsortTxs f

-- Either get the block from the @HeaderHash@ or throw an exception.
getBlundOrThrow
    :: ExplorerMode ctx m
    => HeaderHash
    -> m Blund
getBlundOrThrow hh =
    getBlundFromHHCSLI hh >>= maybeThrow (Internal "Blund with hash cannot be found!")


-- | Deserialize Bcc or RSCoin address and convert it to Bcc address.
-- Throw exception on failure.
cAddrToAddr :: MonadThrow m => NetworkMagic -> CAddress -> m Address
cAddrToAddr nm cAddr@(CAddress rawAddrText) =
    -- Try decoding address as base64. If both decoders succeed,
    -- the output of the first one is returned
    let mDecodedBase64 =
            rightToMaybe (B64.decode rawAddrText) <|>
            rightToMaybe (B64.decodeUrl rawAddrText)

    in case mDecodedBase64 of
        Just addr -> do
            -- the decoded address can be both the RSCoin address and the Bcc address.
            -- > RSCoin address == 32 bytes
            -- > Bcc address >= 34 bytes
            if (BS.length addr == 32)
                then pure $ makeRedeemAddress nm $ redeemPkBuild addr
                else either badBccAddress pure (fromCAddress cAddr)
        Nothing ->
            -- cAddr is in Bcc address format or it's not valid
            either badBccAddress pure (fromCAddress cAddr)
  where

    badBccAddress = const $ throwM $ Internal "Invalid Bcc address!"

-- | Deserialize transaction ID.
-- Throw exception on failure.
cTxIdToTxId :: MonadThrow m => CTxId -> m TxId
cTxIdToTxId cTxId = either exception pure (fromCTxId cTxId)
  where
    exception = const $ throwM $ Internal "Invalid transaction id!"

getMainBlund :: ExplorerMode ctx m => GenesisHash -> HeaderHash -> m MainBlund
getMainBlund genesisHash h = do
    (blk, undo) <- getBlund genesisHash h >>= maybeThrow (Internal "No block found")
    either (const $ throwM $ Internal "Block is genesis block") (pure . (,undo)) blk

getMainBlock :: ExplorerMode ctx m => GenesisHash -> HeaderHash -> m MainBlock
getMainBlock genesisHash = fmap fst . getMainBlund genesisHash

-- | Get transaction extra from the database, and if you don't find it
-- throw an exception.
getTxExtraOrFail :: MonadDBRead m => TxId -> m TxExtra
getTxExtraOrFail txId = ExDB.getTxExtra txId >>= maybeThrow exception
  where
    exception = Internal "Transaction not found"

getTxMain :: ExplorerMode ctx m => GenesisHash -> TxId -> TxExtra -> m Tx
getTxMain genesisHash id TxExtra {..} = case teBlockchainPlace of
    Nothing -> taTx <$> fetchTxFromMempoolOrFail id
    Just (hh, idx) -> do
        mb <- getMainBlock genesisHash hh
        maybeThrow (Internal "TxExtra return tx index that is out of bounds") $
            atMay (toList $ mb ^. mainBlockTxPayload . txpTxs) $ fromIntegral idx

-- | Get @Page@ numbers from an @Epoch@ or throw an exception.
getEpochPagesOrThrow
    :: (HasExplorerCSLInterface m, MonadThrow m)
    => EpochIndex
    -> m Page
getEpochPagesOrThrow epochIndex =
    getEpochPagesCSLI epochIndex >>= maybeThrow (Internal "No epoch pages.")

-- Silly name for a list index-lookup function.
atMay :: [a] -> Int -> Maybe a
atMay xs n
    | n < 0     = Nothing
    | n == 0    = fmap fst (uncons xs)
    | otherwise = case xs of
                      []        -> Nothing
                      (_ : xs') -> atMay xs' (n - 1)
