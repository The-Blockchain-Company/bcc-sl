{-- | IxSet-specific backend to filter data from the model. --}
module Bcc.Wallet.API.Response.Filter.IxSet (
      applyFilters
      ) where

import           Bcc.Wallet.API.Indices (Indexable, IsIndexOf, IxSet)
import qualified Bcc.Wallet.API.Request.Filter as F
import           Bcc.Wallet.Kernel.DB.Util.IxSet ((@+), (@<), (@<=), (@=),
                     (@>), (@>=), (@>=<=))

-- | Applies all the input filters to the input 'IxSet''.
applyFilters :: Indexable a => F.FilterOperations ixs a -> IxSet a -> IxSet a
applyFilters F.NoFilters iset        = iset
applyFilters (F.FilterNop  fop) iset = applyFilters fop iset
applyFilters (F.FilterOp f fop) iset = applyFilters fop (applyFilter f iset)

-- | Applies a single 'FilterOperation' on the input 'IxSet'', producing another 'IxSet'' as output.
applyFilter :: forall ix a. (Indexable a , IsIndexOf ix a) => F.FilterOperation ix a -> IxSet a -> IxSet a
applyFilter fltr inputData =
    let byPredicate o i = case o of
            F.Equal            -> inputData @= (i :: ix)
            F.LesserThan       -> inputData @< (i :: ix)
            F.GreaterThan      -> inputData @> (i :: ix)
            F.LesserThanEqual  -> inputData @<= (i :: ix)
            F.GreaterThanEqual -> inputData @>= (i :: ix)
    in case fltr of
           F.FilterByIndex idx          -> byPredicate F.Equal idx
           F.FilterByPredicate ordr idx -> byPredicate ordr idx
           F.FilterByRange from to      -> inputData @>=<= (from, to)
           F.FilterIn ixs               -> inputData @+ ixs
