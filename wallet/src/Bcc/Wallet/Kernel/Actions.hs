{-# LANGUAGE LambdaCase #-}
module Bcc.Wallet.Kernel.Actions
    ( WalletAction(..)
    , WalletActionInterp(..)
    , WalletInterpAction(..)
    , withWalletWorker
    , WalletWorkerExpiredError(..)
    , interp
    , interpList
    , interpStep
    , WalletWorkerState
    , initialWorkerState
    , isInitialState
    , hasPendingFork
    , isValidState
    ) where

import qualified Control.Concurrent.Async as Async
import qualified Control.Concurrent.STM as STM
import qualified Control.Concurrent.STM.TBMQueue as STM
import qualified Control.Exception.Safe as Ex
import           Control.Lens (makeLenses, (%=), (+=), (-=), (.=))
import           Control.Monad.IO.Unlift (MonadUnliftIO, UnliftIO (unliftIO),
                     withUnliftIO)
import           Control.Monad.Writer.Strict (Writer, runWriter, tell)
import           Formatting (bprint, build, shown, (%))
import qualified Formatting.Buildable
import           Universum

import           Pos.Core.Chrono

{-------------------------------------------------------------------------------
  Workers and helpers for performing wallet state updates
-------------------------------------------------------------------------------}

-- | Actions that can be invoked on a wallet, via a worker.
--   Workers may not respond directly to each action; for example,
--   a `RollbackBlocks` followed by several `ApplyBlocks` may be
--   batched into a single operation on the actual wallet.
data WalletAction b
    = ApplyBlocks    (OldestFirst NE b)
    | RollbackBlocks Int
    | LogMessage Text

-- | Interface abstraction for the wallet worker.
--   The caller provides these primitive wallet operations;
--   the worker uses these to invoke changes to the
--   underlying wallet.
data WalletActionInterp m b = WalletActionInterp
    { applyBlocks  :: OldestFirst NE b -> m ()
    , switchToFork :: Int -> OldestFirst NE b -> m ()
    , emit         :: Text -> m ()
    }

-- | An interpreted action
--
-- Used for 'interpStep'
data WalletInterpAction b
    = InterpApplyBlocks (OldestFirst NE b)
    | InterpSwitchToFork Int (OldestFirst NE b)
    | InterpLogMessage Text

-- | Internal state of the wallet worker.
data WalletWorkerState b = WalletWorkerState
    { _pendingRollbacks    :: !Int
    , _pendingBlocks       :: !(NewestFirst [] b)
    , _lengthPendingBlocks :: !Int
    }
  deriving Eq

makeLenses ''WalletWorkerState

-- A helper function for lifting a `WalletActionInterp` through a monad transformer.
lifted :: (Monad m, MonadTrans t) => WalletActionInterp m b -> WalletActionInterp (t m) b
lifted i = WalletActionInterp
    { applyBlocks  = lift . applyBlocks i
    , switchToFork = \n bs -> lift (switchToFork i n bs)
    , emit         = lift . emit i
    }

-- | `interp` is the main interpreter for converting a wallet action to a concrete
--   transition on the wallet worker's state, perhaps combined with some effects on
--   the concrete wallet.
interp :: Monad m => WalletActionInterp m b -> WalletAction b -> StateT (WalletWorkerState b) m ()
interp walletInterp action = do

    numPendingRollbacks <- use pendingRollbacks
    numPendingBlocks    <- use lengthPendingBlocks

    -- Respond to the incoming action
    case action of

      -- If we are not in the midst of a rollback, just apply the blocks.
      ApplyBlocks bs | numPendingRollbacks == 0 -> do
                         emit "applying some blocks (non-rollback)"
                         applyBlocks bs

      -- Otherwise, add the blocks to the pending list. If the resulting
      -- list of pending blocks is longer than the number of pending rollbacks,
      -- then perform a `switchToFork` operation on the wallet.
      ApplyBlocks bs -> do

        -- Add the blocks
        let bsList = toNewestFirst (OldestFirst (toList (getOldestFirst bs)))
        pendingBlocks %= prependNewestFirst bsList
        lengthPendingBlocks += length bs

        -- If we have seen more blocks than rollbacks, switch to the new fork.
        (nonEmptyOldestFirst . toOldestFirst) <$> use pendingBlocks >>= \case
            Just pb | numPendingBlocks + length bs > numPendingRollbacks -> do

                switchToFork numPendingRollbacks pb

                -- Reset state to "no fork in progress"
                pendingRollbacks    .= 0
                lengthPendingBlocks .= 0
                pendingBlocks       .= NewestFirst []
            _ -> return ()

      -- If we are in the midst of a fork and have seen some new blocks,
      -- roll back some of those blocks. If there are more rollbacks requested
      -- than the number of new blocks, see the next case below.
      RollbackBlocks n | n <= numPendingBlocks -> do
        lengthPendingBlocks -= n
        pendingBlocks %= NewestFirst . drop n . getNewestFirst

      -- If we are in the midst of a fork and are asked to rollback more than
      -- the number of new blocks seen so far, clear out the list of new
      -- blocks and add any excess to the number of pending rollback operations.
      RollbackBlocks n -> do
        pendingRollbacks    += n - numPendingBlocks
        lengthPendingBlocks .= 0
        pendingBlocks       .= NewestFirst []

      LogMessage txt -> emit txt

  where
    WalletActionInterp{..} = lifted walletInterp
    prependNewestFirst bs = \nf -> NewestFirst (getNewestFirst bs <> getNewestFirst nf)

-- | Connect a wallet action interpreter to a source of actions. This function
-- returns as soon as the given action returns 'Nothing'.
walletWorker
  :: Ex.MonadMask m
  => WalletActionInterp m b
  -> m (Maybe (WalletAction b))
  -> m ()
walletWorker wai getWA = Ex.bracket_
  (emit wai "Starting wallet worker.")
  (emit wai "Stopping wallet worker.")
  (evalStateT
     (fix $ \next -> lift getWA >>= \case
        Nothing -> pure ()
        Just wa -> interp wai wa >> next)
     initialWorkerState)

-- | Connect a wallet action interpreter to a stream of actions.
interpList :: Monad m => WalletActionInterp m b -> [WalletAction b] -> m (WalletWorkerState b)
interpList ops actions = execStateT (forM_ actions $ interp ops) initialWorkerState

-- | Step the wallet worker in a pure context
--
-- This is useful for testing purposes.
-- interp :: Monad m => WalletActionInterp m b -> WalletAction b -> StateT (WalletWorkerState b) m ()
interpStep :: forall b. WalletAction b -> WalletWorkerState b -> (WalletWorkerState b, [WalletInterpAction b])
interpStep act st = runWriter (execStateT (interp wai act) st)
  where
    -- Writer should not be used in production code as it has a memory leak. For
    -- this use case however it is perfect: we only accumulate a tiny list here,
    -- and anyway only use this in testing.
    wai :: WalletActionInterp (Writer [WalletInterpAction b]) b
    wai = WalletActionInterp {
          applyBlocks  = \bs   -> tell [InterpApplyBlocks bs]
        , switchToFork = \n bs -> tell [InterpSwitchToFork n bs]
        , emit         = \msg  -> tell [InterpLogMessage msg]
        }

initialWorkerState :: WalletWorkerState b
initialWorkerState = WalletWorkerState
    { _pendingRollbacks    = 0
    , _pendingBlocks       = NewestFirst []
    , _lengthPendingBlocks = 0
    }

-- | Thrown by 'withWalletWorker''s continuation in case it's used outside of
-- its intended scope.
data WalletWorkerExpiredError = WalletWorkerExpiredError deriving (Show)
instance Ex.Exception WalletWorkerExpiredError

-- | Start a wallet worker in backround who will react to input provided via the
-- 'STM' function, in FIFO order.
--
-- After the given continuation returns (successfully or due to some exception),
-- the worker will continue processing any pending input before returning,
-- re-throwing the continuation's exception if any. Async exceptions from any
-- source will always be prioritized.
--
-- Usage of the obtained 'STM' action after the given continuation has returned
-- is not possible. It will throw 'WalletWorkerExpiredError'.
withWalletWorker
  :: forall m a b .
     (MonadUnliftIO m)
  => WalletActionInterp IO a
  -> ((WalletAction a -> STM ()) -> m b)
  -> m b
withWalletWorker wai k = do
  -- 'tmq' keeps items to be processed by the worker in FIFO order.
  tmq :: STM.TBMQueue (WalletAction a) <- liftIO $ STM.newTBMQueueIO 64
  -- 'getWA' gets the next action to be processed.
  let getWA :: STM (Maybe (WalletAction a))
      getWA = STM.readTBMQueue tmq
  -- 'pushWA' adds an action to queue, unless it's been closed already.
  let pushWA :: WalletAction a -> STM ()
      pushWA = STM.writeTBMQueue tmq
  fmap snd $ withUnliftIO $ \(unlift :: UnliftIO m) -> Async.concurrently
    -- Queue reader. If it dies, the writer dies too.
    (walletWorker wai (STM.atomically getWA))
    -- Queue writer. If it finishes, it closes the queue, causing the reader
    -- to terminate normally. If it dies, forget about closing the queue, just
    -- kill the reader.
    (unliftIO unlift (k pushWA) <* STM.atomically (STM.closeTBMQueue tmq))

-- | Check if this is the initial worker state.
isInitialState :: Eq b => WalletWorkerState b -> Bool
isInitialState = (== initialWorkerState)

-- | Check that the state invariants all hold.
isValidState :: WalletWorkerState b -> Bool
isValidState WalletWorkerState{..} =
    _pendingRollbacks >= 0 &&
    length (_pendingBlocks) == _lengthPendingBlocks &&
    _lengthPendingBlocks <= _pendingRollbacks

-- | Check if this state represents a pending fork.
hasPendingFork :: WalletWorkerState b -> Bool
hasPendingFork WalletWorkerState{..} = _pendingRollbacks /= 0

instance Show b => Buildable (WalletWorkerState b) where
    build WalletWorkerState{..} = bprint
      ( "WalletWorkerState "
      % "{ _pendingRollbacks:    " % shown
      % ", _pendingBlocks:       " % shown
      % ", _lengthPendingBlocks: " % shown
      % " }"
      )
      _pendingRollbacks
      _pendingBlocks
      _lengthPendingBlocks

instance Show b => Buildable (WalletAction b) where
    build wa = case wa of
      ApplyBlocks bs    -> bprint ("ApplyBlocks " % shown) bs
      RollbackBlocks bs -> bprint ("RollbackBlocks " % shown) bs
      LogMessage msg    -> bprint ("LogMessage " % shown) msg

instance Show b => Buildable [WalletAction b] where
    build was = case was of
      []     -> bprint "[]"
      (x:xs) -> bprint (build % ":" % build) x xs
