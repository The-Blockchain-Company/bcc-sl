{-# LANGUAGE CPP           #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE LambdaCase    #-}
{-# LANGUAGE Rank2Types    #-}
{-# LANGUAGE TypeFamilies  #-}

module Pos.Communication.Limits
       ( maxAsBinaryOverhead
       , mlAsBinary

       , maxTxSize
       , mlTxAux
       , mlTxMsgContents
       , updateVoteNumLimit
       , maxProposalSize
       , mlUpdateVote
       , mlUpId
       , mlUpdateProposal
       , mlUpdateProposalAndVotes
       , mlMsgGetBlocks
       , mlMsgGetHeaders

       , mlCommitment
       , mlSignedCommitment
       , mlAsBinarySecretProof
       , mlOpening
       , mlInnerSharesMap
       , mlVssCertificate
       , mlStakeholderId
       , mlMCOpening
       , mlMCVssCertificate
       , mlMCCommitment
       , mlMCShares

       , mlEpochIndex
       , mlHeavyDlgIndex
       , mlLightDlgIndices
       , mlProxyCert
       , mlProxySecretKey

       , mlMsgHeaders
       , mlGenesisBlockHeader
       , mlMainBlockHeader
       , mlBlockHeader
       , mlGenesisBlock
       , mlMainBlock
       , mlBlock
       , mlMsgBlock
       , mlMsgStreamBlock
       , mlMsgStream
       ) where

import           Prelude (log)
import           Universum

import qualified Crypto.SCRAPE as Scrape
import           Data.Coerce (coerce)
import           Serokell.Data.Memory.Units (Byte)

import           Pos.Binary.Class (AsBinary (..))
import           Pos.Binary.Limit (Limit (..), mlBool, mlEither, mlMaybe,
                     mlTriple, mlTuple, vectorOf, vectorOfNE, (<+>))
import           Pos.Chain.Block (Block, BlockHeader (..), GenesisBlock,
                     GenesisBlockHeader, MainBlock, MainBlockHeader)
import           Pos.Chain.Delegation (HeavyDlgIndex (..), LightDlgIndices (..))
import           Pos.Chain.Ssc (Commitment (..), InnerSharesMap,
                     MCCommitment (..), MCOpening (..), MCShares (..),
                     MCVssCertificate (..), Opening (..), SignedCommitment,
                     VssCertificate)
import           Pos.Chain.Txp (TxAux, TxMsgContents (..))
import           Pos.Chain.Update (BlockVersionData (..), UpId,
                     UpdateProposal (..), UpdateVote (..))
import           Pos.Core (BlockCount, EpochIndex, StakeholderId,
                     coinPortionToDouble)
import           Pos.Crypto (ProxyCert (..), ProxySecretKey (..),
                     SecretProof (..))
import           Pos.Network.Block.Types (MsgBlock (..), MsgGetBlocks (..),
                     MsgGetHeaders (..), MsgHeaders (..), MsgStream (..),
                     MsgStreamBlock (..))

import           Pos.Core.Chrono (NewestFirst (..))
import           Pos.Crypto.Limits (mlAbstractHash, mlDecShare, mlEncShare,
                     mlPublicKey, mlSignature, mlVssPublicKey, mlXSignature)

----------------------------------------------------------------------------
-- Instances (MessageLimited[Pure])
----------------------------------------------------------------------------

----------------------------------------------------------------------------
---- Core and lower
----------------------------------------------------------------------------

-- Sometimes 'AsBinary a' is serialized with some overhead compared to
-- 'a'. This is tricky to estimate as CBOR uses a number of bytes at
-- the beginning of a BS to encode the length, and the encoding of the length
-- depends on the length itself. This overhead is (conservatively) estimated
-- as at most 64.
maxAsBinaryOverhead :: Limit a
maxAsBinaryOverhead = 64

mlAsBinary :: Limit a -> Limit (AsBinary a)
mlAsBinary lim = coerce lim + maxAsBinaryOverhead

mlScrapeCommitment :: Limit Scrape.Commitment
mlScrapeCommitment = 35

mlExtraGen :: Limit Scrape.ExtraGen
mlExtraGen = 35

mlProof :: Limit Scrape.Proof
mlProof = 35

mlEpochIndex :: Limit EpochIndex
mlEpochIndex = 12

-----------------------------------------------------------------
-- Delegation
-----------------------------------------------------------------

mlHeavyDlgIndex :: Limit HeavyDlgIndex
mlHeavyDlgIndex = HeavyDlgIndex <$> mlEpochIndex

mlLightDlgIndices :: Limit LightDlgIndices
mlLightDlgIndices = LightDlgIndices <$> mlTuple mlEpochIndex mlEpochIndex

mlProxyCert :: Limit (ProxyCert w)
mlProxyCert = ProxyCert <$> mlXSignature

mlProxySecretKey :: Limit w -> Limit (ProxySecretKey w)
mlProxySecretKey lim = UnsafeProxySecretKey <$> lim
                                            <+> mlPublicKey
                                            <+> mlPublicKey
                                            <+> mlProxyCert

----------------------------------------------------------------------------
---- SSC
----------------------------------------------------------------------------

commitmentsNumLimit :: BlockVersionData -> Int
commitmentsNumLimit = succ . ceiling . recip . coinPortionToDouble . bvdMpcThd

mlParallelProofs :: BlockVersionData -> Limit Scrape.ParallelProofs
mlParallelProofs bvd = 32 + numLimit * 32 + 100
    -- ParallelProofs =
    --   ??? Challenge (has size 32)
    --   ??? as many proofs as there are participants
    --     (each proof has size 32)
    -- 100 just in case; something like
    -- 20 should be enough
    -- FIXME this whole limit thing is rotten.
  where
    numLimit = fromIntegral (commitmentsNumLimit bvd)

mlSecretProof :: BlockVersionData -> Limit SecretProof
mlSecretProof bvd = SecretProof <$> mlExtraGen
                                <+> mlProof
                                <+> mlParallelProofs bvd
                                <+> vectorOf numLimit mlScrapeCommitment
  where
    numLimit = commitmentsNumLimit bvd

-- FIXME this was also broken.
-- Inside the Commitment is a HashMap (AsBinary VssPublicKey) (NonEmpty (AsBinary EncShare))
-- What's the limit of the length of the NonEmpty? It was never written down...
mlCommitment :: BlockVersionData -> Limit Commitment
mlCommitment bvd = Commitment <$> mlSecretProof bvd
                              <+> multiMap numLimit
                                           (mlAsBinary mlVssPublicKey)
                                           (vectorOfNE numLimit (mlAsBinary mlEncShare))
  where
    numLimit = commitmentsNumLimit bvd

mlSignedCommitment :: BlockVersionData -> Limit SignedCommitment
mlSignedCommitment bvd = mlTriple mlPublicKey (mlCommitment bvd) mlSignature

mlAsBinarySecretProof :: BlockVersionData -> Limit (AsBinary SecretProof)
mlAsBinarySecretProof bvd = mlAsBinary (mlSecretProof bvd)


mlOpening :: Limit Opening
mlOpening = 37 -- 35 for `Secret` + 2 for the `AsBinary` wrapping

-- FIXME this has also been wrong since forever. How do we limit the
-- NonEmpty list inside the map?
mlInnerSharesMap :: BlockVersionData -> Limit InnerSharesMap
mlInnerSharesMap bvd = multiMap numLimit mlStakeholderId (vectorOfNE numLimit (mlAsBinary mlDecShare))
  where
    numLimit = commitmentsNumLimit bvd

-- There is some precaution in this limit. 179 means that epoch is
-- extremely large. It shouldn't happen in practice, but adding few
-- bytes to the limit is harmless.
-- FIXME it's also a symptom of a bad design.
mlVssCertificate :: Limit VssCertificate
mlVssCertificate = 179

mlStakeholderId :: Limit StakeholderId
mlStakeholderId = mlAbstractHash

mlMCOpening :: Limit MCOpening
mlMCOpening = MCOpening <$> mlStakeholderId <+> mlOpening

mlMCVssCertificate :: Limit MCVssCertificate
mlMCVssCertificate = MCVssCertificate <$> mlVssCertificate

mlMCCommitment :: BlockVersionData -> Limit MCCommitment
mlMCCommitment bvd = MCCommitment <$> mlSignedCommitment bvd

mlMCShares :: BlockVersionData -> Limit MCShares
mlMCShares bvd = MCShares <$> mlStakeholderId <+> mlInnerSharesMap bvd

----------------------------------------------------------------------------
---- Txp
----------------------------------------------------------------------------

maxTxSize :: BlockVersionData -> Byte
maxTxSize = bvdMaxTxSize

mlTxAux :: BlockVersionData -> Limit TxAux
mlTxAux = Limit . fromIntegral . maxTxSize

mlTxMsgContents :: BlockVersionData -> Limit TxMsgContents
mlTxMsgContents = fmap TxMsgContents . mlTxAux

----------------------------------------------------------------------------
---- Update System
----------------------------------------------------------------------------

updateVoteNumLimit :: BlockVersionData -> Int
updateVoteNumLimit = succ . ceiling . recip . coinPortionToDouble . bvdUpdateVoteThd

maxProposalSize
    :: BlockVersionData -> Byte
maxProposalSize = bvdMaxProposalSize

mlUpdateVote :: Limit UpdateVote
-- FIXME why 1 + ?
mlUpdateVote = 1 + (UnsafeUpdateVote <$> mlPublicKey
                                     <+> mlUpId
                                     <+> mlBool
                                     <+> mlSignature)

mlUpId :: Limit UpId
mlUpId = mlAbstractHash

mlUpdateProposal :: BlockVersionData -> Limit UpdateProposal
mlUpdateProposal = Limit . fromIntegral . maxProposalSize

mlUpdateProposalAndVotes :: BlockVersionData -> Limit (UpdateProposal, [UpdateVote])
mlUpdateProposalAndVotes bvd = (,) <$> mlUpdateProposal bvd <+> vectorOf voteNumLimit mlUpdateVote
  where
    voteNumLimit = updateVoteNumLimit bvd

----------------------------------------------------------------------------
---- Blocks/headers
----------------------------------------------------------------------------

mlMsgGetBlocks :: Limit MsgGetBlocks
mlMsgGetBlocks = MsgGetBlocks <$> mlAbstractHash <+> mlAbstractHash

mlMsgGetHeaders :: BlockCount -> Limit MsgGetHeaders
mlMsgGetHeaders blkSecurityParam = MsgGetHeaders <$> vectorOf maxGetHeadersNum mlAbstractHash <+> mlMaybe mlAbstractHash
  where
    -- FIXME why?
    maxGetHeadersNum = ceiling $
        log (fromIntegral blkSecurityParam) + (5 :: Double)

mlMsgHeaders :: BlockVersionData -> Int -> Limit MsgHeaders
mlMsgHeaders bvd recoveryHeadersMessage = MsgHeaders . NewestFirst <$> vectorOfNE recoveryHeadersMessage (mlBlockHeader bvd)

mlGenesisBlockHeader :: BlockVersionData -> Limit GenesisBlockHeader
mlGenesisBlockHeader = Limit . fromIntegral . bvdMaxHeaderSize

mlMainBlockHeader :: BlockVersionData -> Limit MainBlockHeader
mlMainBlockHeader = Limit . fromIntegral . bvdMaxHeaderSize

mlBlockHeader :: BlockVersionData -> Limit BlockHeader
mlBlockHeader bvd = 1 + max (BlockHeaderGenesis <$> mlGenesisBlockHeader bvd)
                            (BlockHeaderMain    <$> mlMainBlockHeader bvd)

mlGenesisBlock :: BlockVersionData -> Limit GenesisBlock
mlGenesisBlock _ = Limit 2000000

mlMainBlock :: BlockVersionData -> Limit MainBlock
mlMainBlock = Limit . fromIntegral . bvdMaxBlockSize

mlBlock :: BlockVersionData -> Limit Block
mlBlock bvd = mlEither (mlGenesisBlock bvd) (mlMainBlock bvd)

mlMsgBlock :: BlockVersionData -> Limit MsgBlock
mlMsgBlock = fmap MsgBlock . mlBlock

mlMsgStream :: Limit MsgStream
mlMsgStream = mlMsgStreamStart

mlMsgStreamStart :: Limit MsgStream
mlMsgStreamStart = 0x7ffff -- XXX A 512k limit, if these numbers are bytes.

mlMsgStreamBlock :: BlockVersionData -> Limit MsgStreamBlock
mlMsgStreamBlock = fmap MsgStreamBlock . mlBlock -- XXX MsgStreamNoBlock has an arbitrary text field...

----------------------------------------------------------------------------
-- Utils
----------------------------------------------------------------------------

multiMap
    :: Int -> Limit k -> Limit v -> Limit l
multiMap k keyLimit valLimit =
    -- max message length is reached when each key has single value
    Limit $ encodedMapLength + x * (fromIntegral k)
    where
    Limit x = (,) <$> keyLimit <+> valLimit
    -- FIXME just like in vectorOf, this is silly.
    encodedMapLength = 20
