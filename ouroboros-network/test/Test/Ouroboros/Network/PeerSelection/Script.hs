{-# LANGUAGE DeriveTraversable          #-}
{-# LANGUAGE DerivingVia                #-}

module Test.Ouroboros.Network.PeerSelection.Script (

    -- * Test scripts
    Script(..),
    scriptHead,
    singletonScript,
    initScript,
    stepScript,
    stepScriptSTM,
    arbitraryShortScriptOf,

    -- * Timed scripts
    ScriptDelay(..),
    TimedScript,
    playTimedScript,

    -- * Pick scripts
    PickScript,
    interpretPickScript

  ) where

import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import           Data.Set (Set)
import qualified Data.Set as Set
import           Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NonEmpty

import           Control.Monad.Class.MonadAsync
import           Control.Monad.Class.MonadSTM
import           Control.Monad.Class.MonadTimer

import           Test.Ouroboros.Network.PeerSelection.Instances ()

import           Test.QuickCheck


--
-- Test script abstraction
--

newtype Script a = Script (NonEmpty a)
  deriving (Eq, Show, Functor, Foldable, Traversable)
  deriving Arbitrary via NonEmpty a

singletonScript :: a -> Script a
singletonScript x = (Script (x :| []))

scriptHead :: Script a -> a
scriptHead (Script (x :| _)) = x

arbitraryShortScriptOf :: Gen a -> Gen (Script a)
arbitraryShortScriptOf a =
    sized $ \sz ->
      (Script . NonEmpty.fromList) <$> vectorOf (min 5 (sz+1)) a

initScript :: MonadSTM m => Script a -> m (TVar m (Script a))
initScript = newTVarIO

stepScript :: MonadSTM m => TVar m (Script a) -> m a
stepScript scriptVar = atomically (stepScriptSTM scriptVar)

stepScriptSTM :: MonadSTMTx stm tvar tmvar tqueue tbqueue => tvar (Script a) -> stm a
stepScriptSTM scriptVar = do
    Script (x :| xs) <- readTVar scriptVar
    case xs of
      []     -> return ()
      x':xs' -> writeTVar scriptVar (Script (x' :| xs'))
    return x

--
-- Timed scripts
--

type TimedScript a = Script (a, ScriptDelay)

data ScriptDelay = NoDelay | ShortDelay | LongDelay
  deriving (Eq, Show)

instance Arbitrary ScriptDelay where
  arbitrary = frequency [ (1, pure NoDelay)
                        , (1, pure ShortDelay)
                        , (4, pure LongDelay) ]

  shrink LongDelay  = [NoDelay, ShortDelay]
  shrink ShortDelay = [NoDelay]
  shrink NoDelay    = []

playTimedScript :: (MonadAsync m, MonadTimer m)
                => TimedScript a -> m (TVar m a)
playTimedScript (Script ((x0,d0) :| script)) = do
    v <- newTVarIO x0
    _ <- async $ do
           threadDelay (interpretScriptDelay d0)
           sequence_ [ do atomically (writeTVar v x)
                          threadDelay (interpretScriptDelay d)
                     | (x,d) <- script ]
    return v
  where
    interpretScriptDelay NoDelay    = 0
    interpretScriptDelay ShortDelay = 1
    interpretScriptDelay LongDelay  = 3600


--
-- Pick scripts
--

-- | A pick script is used to interpret the 'policyPickKnownPeersForGossip' and
-- the 'policyPickColdPeersToForget'. It selects elements from the given
-- choices by their index (modulo the number of choices). This representation
-- was chosen because it allows easy shrinking.
--
type PickScript = Script PickMembers

data PickMembers = PickFirst
                 | PickAll
                 | PickSome [Int]
  deriving (Eq, Show)

instance Arbitrary PickMembers where
    arbitrary = frequency [ (1, pure PickFirst)
                          , (1, pure PickAll)
                          , (2, PickSome <$> listOf1 arbitrarySizedNatural) ]

    shrink (PickSome ixs) = PickAll
                          : [ PickSome ixs'
                            | ixs' <- shrink ixs
                            , not (null ixs') ]
    shrink PickAll        = [PickFirst]
    shrink PickFirst      = []

interpretPickScript :: (MonadSTMTx stm tvar tmvar tqueue tbqueue, Ord peeraddr)
                    => tvar PickScript
                    -> Map peeraddr k
                    -> Int
                    -> stm (Set peeraddr)
interpretPickScript scriptVar available pickNum
  | Map.null available
  = error "interpretPickScript: given empty map to pick from"
  | pickNum <= 0
  = error "interpretPickScript: given invalid pickNum"

  | Map.size available <= pickNum
  = return $ Set.fromList $ Map.keys available

  | otherwise
  = do pickmembers <- stepScriptSTM scriptVar
       return (interpretPickMembers pickmembers available pickNum)

interpretPickMembers :: Ord peeraddr
                     => PickMembers -> Map peeraddr k -> Int -> Set peeraddr
interpretPickMembers PickFirst      ps _ = Set.singleton $ fst (Map.elemAt 0 ps)
interpretPickMembers PickAll        ps n = Set.fromList $ take n  $ Map.keys ps
interpretPickMembers (PickSome ixs) ps n = pickMapKeys ps (take n ixs)

pickMapKeys :: Ord a => Map a b -> [Int] -> Set a
pickMapKeys m ns =
    let s = Set.fromList $ Map.keys m in
    Set.fromList (map (pick s) ns)
  where
    pick s n = Set.elemAt i s where i = n `mod` Set.size s

