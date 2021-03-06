{-# LANGUAGE RecordWildCards #-}

-- | Center of where block verification/application/rollback happens.
-- Unifies VAR for all components (slog, ssc, txp, dlg, us).

module Pos.DB.Block.Logic.VAR
       ( verifyBlocksPrefix

       , BlockLrcMode
       , verifyAndApplyBlocks
       , applyWithRollback

       -- * Exported for tests
       , applyBlocks
       , rollbackBlocks
       ) where

import           Universum

import           Control.Exception.Safe (bracketOnError)
import           Control.Lens (_Wrapped)
import           Control.Monad.Except (ExceptT (ExceptT),
                     MonadError (throwError), runExceptT, withExceptT)
import qualified Data.List.NonEmpty as NE
import           Formatting (sformat, shown, (%))

import           Pos.Chain.Block (ApplyBlocksException (..), Block,
                     BlockHeader (..), Blund, HasSlogGState, HeaderHash,
                     RollbackException (..), Undo (..),
                     VerifyBlocksException (..), headerHash, headerHashG,
                     prevBlockL)
import           Pos.Chain.Genesis as Genesis (Config (..), configEpochSlots)
import           Pos.Chain.Txp (TxpConfiguration)
import           Pos.Chain.Update (ConsensusEra (..), PollModifier,
                     UpdateConfiguration)
import           Pos.Core (epochIndexL)
import           Pos.Core.Chrono (NE, NewestFirst (..), OldestFirst (..),
                     toNewestFirst, toOldestFirst)
import           Pos.Core.Reporting (HasMisbehaviorMetrics)
import           Pos.Core.Slotting (MonadSlots (getCurrentSlot), SlotId)
import           Pos.DB.Block.Logic.Internal (BypassSecurityCheck (..),
                     MonadBlockApply, MonadBlockVerify,
                     MonadMempoolNormalization, applyBlocksUnsafe,
                     normalizeMempool, rollbackBlocksUnsafe, toSscBlock,
                     toTxpBlock, toUpdateBlock)
import           Pos.DB.Block.Logic.SplitByEpoch (splitByEpoch)
import           Pos.DB.Block.Lrc (LrcModeFull, lrcSingleShot)
import           Pos.DB.Block.Slog.Logic (ShouldCallBListener (..),
                     mustDataBeKnown, slogVerifyBlocks)
import           Pos.DB.BlockIndex (getTipHeader)
import           Pos.DB.Delegation (dlgVerifyBlocks)
import qualified Pos.DB.GState.Common as GS (getTip, writeBatchGState)
import           Pos.DB.Ssc (sscVerifyBlocks)
import           Pos.DB.Txp.Settings
                     (TxpGlobalSettings (TxpGlobalSettings, tgsVerifyBlocks))
import           Pos.DB.Update (getAdoptedBV, getConsensusEra, usApplyBlocks,
                     usVerifyBlocks)
import           Pos.Util (neZipWith4, spanSafe, _neHead)
import           Pos.Util.Util (HasLens (..))
import           Pos.Util.Wlog (logDebug)

-- -- CHECK: @verifyBlocksLogic
-- -- #txVerifyBlocks
-- -- #sscVerifyBlocks
-- -- #dlgVerifyBlocks
-- -- #usVerifyBlocks
-- | Verify new blocks. If parent of the first block is not our tip,
-- verification fails. All blocks must be from the same epoch.  This
-- function checks literally __everything__ from blocks, including
-- header, body, extra data, etc.
--
-- LRC must be already performed for the epoch from which blocks are.
--
-- Algorithm:
-- 1.  Ensure that the parent of the oldest block that we want to apply
--     matches the current tip.
-- 2.  Perform verification component-wise (@slog@, @ssc@, @txp@, @dlg@, @us@).
-- 3.  Ensure that the number of undos from @txp@ and @dlg@ is the same.
-- 4.  Return all undos.
verifyBlocksPrefix
    :: forall ctx m.
       ( MonadBlockVerify ctx m
       , HasSlogGState ctx
       )
    => Genesis.Config
    -> Maybe SlotId -- ^ current slot to verify that headers are not from future slots
    -> OldestFirst NE Block
    -> m (Either VerifyBlocksException (OldestFirst NE Undo, PollModifier))
verifyBlocksPrefix genesisConfig currentSlot blocks = runExceptT $ do
    uc <- view (lensOf @UpdateConfiguration)
    -- This check (about tip) is here just in case, we actually check
    -- it before calling this function.
    tip <- lift GS.getTip
    when (tip /= blocks ^. _Wrapped . _neHead . prevBlockL) $
        throwError $ VerifyBlocksError "the first block isn't based on the tip"
    -- Some verifications need to know whether all data must be known.
    -- We determine it here and pass to all interested components.
    adoptedBV <- lift getAdoptedBV
    let dataMustBeKnown = mustDataBeKnown uc adoptedBV

    -- Run verification of each component.
    -- 'slogVerifyBlocks' uses 'Pos.Chain.Block.Pure.verifyBlocks' which does
    -- the internal consistency checks formerly done in the 'Bi' instance
    -- 'decode'.
    slogUndos <- withExceptT VerifyBlocksError $
        ExceptT $ slogVerifyBlocks genesisConfig currentSlot blocks
    era <- getConsensusEra
    case era of
        Original -> void $ withExceptT (VerifyBlocksError . pretty) $
                        ExceptT $ sscVerifyBlocks genesisConfig (map toSscBlock blocks)
        SBFT _   -> pass -- We don't perform SSC operations during the SBFT era
    TxpGlobalSettings {..} <- view (lensOf @TxpGlobalSettings)
    txUndo <- withExceptT (VerifyBlocksError . pretty) $
        ExceptT $ tgsVerifyBlocks dataMustBeKnown $ map toTxpBlock blocks
    pskUndo <- withExceptT VerifyBlocksError $ dlgVerifyBlocks genesisConfig blocks
    (pModifier, usUndos) <- withExceptT (VerifyBlocksError . pretty) $
        ExceptT $ usVerifyBlocks genesisConfig dataMustBeKnown (map toUpdateBlock blocks)

    -- Eventually we do a sanity check just in case and return the result.
    when (length txUndo /= length pskUndo) $
        throwError $ VerifyBlocksError
        "Internal error of verifyBlocksPrefix: lengths of undos don't match"
    pure ( OldestFirst $ neZipWith4 Undo
               (getOldestFirst txUndo)
               (getOldestFirst pskUndo)
               (getOldestFirst usUndos)
               (getOldestFirst slogUndos)
         , pModifier)

-- | Union of constraints required by block processing and LRC.
type BlockLrcMode ctx m = (MonadBlockApply ctx m, LrcModeFull ctx m)

-- | Applies a list of blocks (not necessarily from a single epoch) if they
-- are valid. Takes one boolean flag @rollback@. On success, normalizes all
-- mempools except the delegation one and returns the header hash of the last
-- applied block (the new tip). Failure behavior depends on the @rollback@
-- flag. If it's on, all blocks applied inside this function will be rolled
-- back, so it will do effectively nothing and return @Left error@. If it's
-- off, it will try to apply as many blocks as possible. If the very first
-- block cannot be applied, it will throw an exception, otherwise it will
-- return the header hash of the new tip. It's up to the caller to log a
-- warning that partial application has occurred.
verifyAndApplyBlocks
    :: forall ctx m.
       ( BlockLrcMode ctx m
       , MonadMempoolNormalization ctx m
       , HasMisbehaviorMetrics ctx
       )
    => Genesis.Config
    -> TxpConfiguration
    -> Maybe SlotId
    -> Bool
    -> OldestFirst NE Block
    -> m (Either ApplyBlocksException (HeaderHash, NewestFirst [] Blund))
verifyAndApplyBlocks genesisConfig txpConfig curSlot rollback blocks = runExceptT $ do
    tip <- lift getTipHeader
    let tipHash = headerHash tip
        assumedTip = blocks ^. _Wrapped . _neHead . prevBlockL
        startingNewEpoch = blocks ^. _Wrapped . _neHead ^. epochIndexL /= tip ^. epochIndexL
    when (tipHash /= assumedTip) $
        throwError $ ApplyBlocksTipMismatch "verify and apply" tipHash assumedTip
    hh <- rollingVerifyAndApply genesisConfig curSlot rollback [] (splitByEpoch startingNewEpoch blocks)
    lift $ normalizeMempool genesisConfig txpConfig
    pure hh

-- This function tries to apply a new portion of blocks (prefix
-- and suffix). It also has an aggregating parameter @blunds@ which is
-- collected to rollback blocks if correspondent flag is on. The first
-- list is packs of blunds. The head of this list is the blund that should
-- be rolled back first. This function also tries to apply as much as
-- possible if the @rollback@ flag is on.
rollingVerifyAndApply
    :: forall ctx m.
       ( BlockLrcMode ctx m
       , MonadMempoolNormalization ctx m
       , HasMisbehaviorMetrics ctx
       )
    => Genesis.Config
    -> Maybe SlotId
    -> Bool
    -> [NewestFirst NE Blund]
    -> [OldestFirst NE Block]
    -> ExceptT ApplyBlocksException m (HeaderHash, NewestFirst [] Blund)
rollingVerifyAndApply _ _ _ blunds [] = (,concatNE blunds) <$> lift GS.getTip
rollingVerifyAndApply genesisConfig curSlot rollback blunds (prefix : suffix) = do
    let prefixHead = prefix ^. _Wrapped . _neHead
        epochIndex = prefixHead ^. epochIndexL

    if isLeft prefixHead
        then do
            -- This is an EBB for the Original era.
            logDebug $ "Rolling: Calculating LRC if needed for epoch "
                    <> pretty epochIndex
            lift $ lrcSingleShot genesisConfig epochIndex
        else do
            -- We may or may not be in the Original era here.
            -- This is a somewhat savage hack to make sure the adopted block version
            -- data is updated on the first block of an SBFT epoch (which may not
            -- be slot 0 of the new epoch).
            tipHeader <- getTipHeader
            case tipHeader of
                BlockHeaderGenesis _ -> pure ()

                BlockHeaderMain mb ->
                    when (mb ^. epochIndexL == epochIndex - 1) $ do
                        logDebug $ "Rolling: Calculating SBFT LRC if needed for epoch "
                                <> pretty epochIndex
                        lift $ lrcSingleShot genesisConfig epochIndex

                        -- Apply just the update payload of the first block of the next epoch.
                        let ublocks = OldestFirst $ toUpdateBlock (NE.head $ getOldestFirst prefix) :| []
                        ops <- lift $ usApplyBlocks genesisConfig ublocks Nothing
                        GS.writeBatchGState ops

    logDebug "Rolling: verifying"
    logDebug $ sformat ("verifyBlocksPrefix: " % shown) (NE.length $ getOldestFirst prefix)
    lift (verifyBlocksPrefix genesisConfig curSlot prefix) >>= \case
        Left (ApplyBlocksVerifyFailure -> failure)
            | rollback  -> failWithRollback failure blunds
            | otherwise -> do
                  logDebug $ sformat ("Rolling: run applyAMAP: apply as much as possible\
                                     \ after `verifyBlocksPrefix` failure: "%shown) failure
                  applyAMAP failure
                               (over _Wrapped toList prefix)
                               (NewestFirst [])
                               (null blunds)
        Right (undos, pModifier) -> do
            let newBlunds = OldestFirst $ getOldestFirst prefix `NE.zip`
                                          getOldestFirst undos
            let blunds' = toNewestFirst newBlunds : blunds
            logDebug "Rolling: Verification done, applying unsafe block"
            lift $ applyBlocksUnsafe
                genesisConfig
                (ShouldCallBListener True)
                newBlunds
                (Just pModifier)
            case suffix of
                [] -> (,concatNE blunds') <$> lift GS.getTip
                _ ->  do
                    logDebug "Rolling: Applying done, next portion"
                    rollingVerifyAndApply genesisConfig curSlot rollback blunds' suffix
  where
    -- Applies as many blocks from failed prefix as possible. Argument
    -- indicates if at least some progress was done so we should
    -- return tip. Fail otherwise.
    applyAMAP
        :: ApplyBlocksException
        -> OldestFirst [] Block
        -> NewestFirst [] Blund  -- an accumulator for `Blund`s
        -> Bool
        -> ExceptT ApplyBlocksException m (HeaderHash, NewestFirst [] Blund)
    applyAMAP e (OldestFirst []) _      True                   = throwError e
    applyAMAP _ (OldestFirst []) blnds False                  = (,blnds) <$> lift GS.getTip
    applyAMAP e (OldestFirst (block:xs)) blnds nothingApplied = do
        lift (verifyBlocksPrefix genesisConfig curSlot (one block)) >>= \case
            Left (ApplyBlocksVerifyFailure -> e') ->
                applyAMAP e' (OldestFirst []) blnds nothingApplied
            Right (OldestFirst (undo :| []), pModifier) -> do
                lift $ applyBlocksUnsafe
                    genesisConfig
                    (ShouldCallBListener True)
                    (one (block, undo))
                    (Just pModifier)
                applyAMAP e (OldestFirst xs) (NewestFirst $ (block, undo) : getNewestFirst blnds) False
            Right _ -> error "verifyAndApplyBlocksInternal: applyAMAP: \
                             \verification of one block produced more than one undo"
    -- Rollbacks and returns an error
    failWithRollback
        :: ApplyBlocksException
        -> [NewestFirst NE Blund]
        -> ExceptT ApplyBlocksException m (HeaderHash, NewestFirst [] Blund)
    failWithRollback e toRollback = do
        logDebug "verifyAndapply failed, rolling back"
        lift $ mapM_ (rollbackBlocks genesisConfig) toRollback
        throwError e

concatNE :: [NewestFirst NE a] -> NewestFirst [] a
concatNE = NewestFirst . foldMap (\(NewestFirst as) -> NE.toList as)

-- | Apply definitely valid sequence of blocks. At this point we must
-- have verified all predicates regarding block (including txp and ssc
-- data checks). We also must have taken lock on block application
-- and ensured that chain is based on our tip. Blocks will be applied
-- per-epoch, calculating lrc when needed if flag is set.
applyBlocks
    :: forall ctx m
     . ( BlockLrcMode ctx m
       , HasMisbehaviorMetrics ctx
       )
    => Genesis.Config
    -> Bool
    -> Maybe PollModifier
    -> OldestFirst NE Blund
    -> m ()
applyBlocks genesisConfig calculateLrc pModifier blunds = do
    when (isLeft prefixHead && calculateLrc) $
        -- Hopefully this lrc check is never triggered -- because
        -- caller most definitely should have computed lrc to verify
        -- the sequence beforehand.
        lrcSingleShot genesisConfig (prefixHead ^. epochIndexL)
    applyBlocksUnsafe genesisConfig (ShouldCallBListener True) prefix pModifier
    case getOldestFirst suffix of
        []           -> pass
        (genesis:xs) -> applyBlocks genesisConfig calculateLrc pModifier (OldestFirst (genesis:|xs))
  where
    prefixHead = prefix ^. _Wrapped . _neHead . _1
    (prefix, suffix) = spanEpoch blunds
    -- this version is different from one in verifyAndApply subtly,
    -- but they can be merged with some struggle.
    spanEpoch (OldestFirst (b@((Left _),_):|xs)) = (OldestFirst $ b:|[], OldestFirst xs)
    spanEpoch x                                  = spanTail x
    spanTail = over _1 OldestFirst . over _2 OldestFirst .
               spanSafe ((==) `on` view (_1 . epochIndexL)) .
               getOldestFirst

-- | Rollbacks blocks. Head must be the current tip.
rollbackBlocks
    :: MonadBlockApply ctx m
    => Genesis.Config
    -> NewestFirst NE Blund
    -> m ()
rollbackBlocks genesisConfig blunds = do
    tip <- GS.getTip
    let firstToRollback = blunds ^. _Wrapped . _neHead . _1 . headerHashG
    when (tip /= firstToRollback) $
        throwM $ RollbackTipMismatch tip firstToRollback
    rollbackBlocksUnsafe genesisConfig (BypassSecurityCheck False) (ShouldCallBListener True) blunds

-- | Rollbacks some blocks and then applies some blocks.
applyWithRollback
    :: forall ctx m
     . ( BlockLrcMode ctx m
       , MonadMempoolNormalization ctx m
       , HasMisbehaviorMetrics ctx
       )
    => Genesis.Config
    -> TxpConfiguration
    -> NewestFirst NE Blund        -- ^ Blocks to rollbck
    -> OldestFirst NE Block        -- ^ Blocks to apply
    -> m (Either ApplyBlocksException HeaderHash)
applyWithRollback genesisConfig txpConfig toRollback toApply = runExceptT $ do
    tip <- lift GS.getTip
    when (tip /= newestToRollback) $
        throwError $ ApplyBlocksTipMismatch "applyWithRollback/rollback" tip newestToRollback

    let doRollback = rollbackBlocksUnsafe
            genesisConfig
            (BypassSecurityCheck False)
            (ShouldCallBListener True)
            toRollback
    -- We want to make sure that if we successfully perform a
    -- rollback, we will eventually apply old or new blocks.
    ExceptT $ bracketOnError doRollback (\_ -> applyBack) $ \_ -> do
        tipAfterRollback <- GS.getTip
        if tipAfterRollback /= expectedTipApply
            then onBadRollback tip
            else onGoodRollback
  where
    reApply = toOldestFirst toRollback
    applyBack :: m ()
    applyBack = applyBlocks genesisConfig False Nothing reApply
    expectedTipApply = toApply ^. _Wrapped . _neHead . prevBlockL
    newestToRollback = toRollback ^. _Wrapped . _neHead . _1 . headerHashG

    onBadRollback tip =
        applyBack $> Left (ApplyBlocksTipMismatch "applyWithRollback/apply" tip newestToRollback)

    onGoodRollback = do
        curSlot <- getCurrentSlot $ configEpochSlots genesisConfig
        verifyAndApplyBlocks genesisConfig txpConfig curSlot True toApply >>= \case
            Left err           -> applyBack $> Left err
            Right (tipHash, _) -> pure (Right tipHash)
