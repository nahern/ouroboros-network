{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- Constants used in 'Ouroboros.Network.Diffusion'
module Ouroboros.Network.Diffusion.Policies where

import           Control.Monad.Class.MonadSTM.Strict
import           Control.Monad.Class.MonadTime

import           Data.List (sortOn, unfoldr)
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import           Data.Word (Word32)
import           System.Random

import           Network.Socket (SockAddr)

import           Ouroboros.Network.PeerSelection.Governor.Types
import           Ouroboros.Network.PeerSelection.KnownPeers (KnownPeerInfo (..))
import           Ouroboros.Network.PeerSelection.PeerMetric


-- | Timeout for 'spsDeactivateTimeout'.
--
-- The maximal timeout on 'ChainSync' (in 'StMustReply' state) is @269s@.
--
deactivateTimeout :: DiffTime
deactivateTimeout = 300

-- | Timeout for 'spsCloseConnectionTimeout'.
--
-- This timeout depends on 'KeepAlive' and 'TipSample' timeouts.  'KeepAlive'
-- keeps agancy most of the time, but 'TipSample' can give away its agency for
-- longer periods of time.  Here we allow it to get 6 blocks (assuming a new
-- block every @20s@).
--
closeConnectionTimeout :: DiffTime
closeConnectionTimeout = 120


simplePeerSelectionPolicy :: forall m. MonadSTM m
                          => StrictTVar m StdGen
                          -> STM m ChurnMode
                          -> PeerMetrics m SockAddr
                          -> PeerSelectionPolicy SockAddr m
simplePeerSelectionPolicy rngVar getChurnMode metrics = PeerSelectionPolicy {
      policyPickKnownPeersForGossip = simplePromotionPolicy,
      policyPickColdPeersToPromote  = simplePromotionPolicy,
      policyPickWarmPeersToPromote  = simplePromotionPolicy,

      policyPickHotPeersToDemote    = hotDemotionPolicy,
      policyPickWarmPeersToDemote   = warmDemotionPolicy,
      policyPickColdPeersToForget   = coldForgetPolicy,

      policyFindPublicRootTimeout   = 5,    -- seconds
      policyMaxInProgressGossipReqs = 2,
      policyGossipRetryTime         = 3600, -- seconds
      policyGossipBatchWaitTime     = 3,    -- seconds
      policyGossipOverallTimeout    = 10    -- seconds
    }
  where

     -- Add a random number in order to prevent ordering based on SockAddr.
     -- The random number is influenced by `kpiFn`.
    addRand :: Map SockAddr KnownPeerInfo
            -> (((SockAddr, KnownPeerInfo), Word32) -> (SockAddr, Word32))
            -> STM m (Map SockAddr Word32)
    addRand available kpiFn = do
      inRng <- readTVar rngVar

      let (rng, rng') = split inRng
          rns = take (Map.size available) $ unfoldr (Just . random)  rng :: [Word32]
          available' = Map.fromList $ zipWith (curry kpiFn) (Map.toList available) rns
      writeTVar rngVar rng'
      return available'

    hotDemotionPolicy :: PickPolicy SockAddr m
    hotDemotionPolicy available pickNum = do
        mode <- getChurnMode
        scores <- case mode of
                       ChurnModeNormal ->
                           upstreamyness <$> getHeaderMetrics metrics
                       ChurnModeBulkSync ->
                           fetchyness <$> getFetchedMetrics metrics
        available' <- addRand available nullWeight
        return $ Set.fromList
             . map fst
             . take pickNum
             . sortOn (\(peer, rn) ->
                          (Map.findWithDefault 0 peer scores, rn))
             . Map.assocs
             $ available'

    simplePromotionPolicy :: PickPolicy SockAddr m
    simplePromotionPolicy available pickNum = do
      available' <- addRand available  nullWeight
      return $ Set.fromList
             . map fst
             . take pickNum
             . sortOn snd
             . Map.assocs
             $ available'

    _simpleDemotionPolicy :: PickPolicy SockAddr m
    _simpleDemotionPolicy available pickNum = do
      available' <- addRand available nullWeight
      return $ Set.fromList
             . map fst
             . take pickNum
             . sortOn snd
             . Map.assocs
             $ available'

    -- Randomly pick peers to demote, peeers with knownPeerTepid set are twice
    -- as likely to be demoted.
    warmDemotionPolicy :: PickPolicy SockAddr m
    warmDemotionPolicy available pickNum = do
      available' <- addRand available tepidWeight
      return $ Set.fromList
             . map fst
             . take pickNum
             . sortOn snd
             . Map.assocs
             $ available'

    -- Randomly pick peers to forget, peers with failures are more likely to
    -- be forgotten.
    coldForgetPolicy :: PickPolicy SockAddr m
    coldForgetPolicy available pickNum = do
      available' <- addRand available failWeight
      return $ Set.fromList
             . map fst
             . take pickNum
             . sortOn snd
             . Map.assocs
             $ available'

    -- KnownPeerInfo does not influence 'r'.
    nullWeight :: ((SockAddr, KnownPeerInfo), Word32)
               -> (SockAddr, Word32)
    nullWeight ((p, _), r) = (p, r)


    -- knownPeerTepid cuts r in half.
    tepidWeight :: ((SockAddr, KnownPeerInfo), Word32)
                -> (SockAddr, Word32)
    tepidWeight ((peer, KnownPeerInfo{knownPeerTepid}), r) =
          if knownPeerTepid then (peer, r `div` 2)
                            else (peer, r)

    -- knownPeerFailCount lowers r.
    failWeight :: ((SockAddr, KnownPeerInfo), Word32)
               -> (SockAddr, Word32)
    failWeight ((peer, KnownPeerInfo{knownPeerFailCount}), r) =
          (peer, r `div` (1 + fromIntegral knownPeerFailCount))
