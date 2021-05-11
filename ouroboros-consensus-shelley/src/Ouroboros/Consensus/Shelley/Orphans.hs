{-# LANGUAGE TypeFamilies #-}

{-# OPTIONS_GHC -Wno-orphans #-}

module Ouroboros.Consensus.Shelley.Orphans () where

import qualified Cardano.Ledger.Era as Core (TranslationContext)
import           Cardano.Ledger.Shelley (ShelleyEra)

type instance Core.TranslationContext (ShelleyEra c) = ()
