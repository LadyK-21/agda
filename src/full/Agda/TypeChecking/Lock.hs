{-# OPTIONS_GHC -Wunused-imports #-}

{-# LANGUAGE NondecreasingIndentation #-}

module Agda.TypeChecking.Lock
  ( isTimeless
  , checkLockedVars
  , checkEarlierThan
  )
where

import Prelude hiding (null)
import qualified Prelude as Prelude

import qualified Data.IntMap as IMap
import qualified Data.Set as Set

import Agda.Syntax.Common
import Agda.Syntax.Internal

import Agda.TypeChecking.Monad
import Agda.TypeChecking.Pretty
import Agda.TypeChecking.Constraints () -- instance MonadConstraint TCM
import Agda.TypeChecking.Reduce
import Agda.TypeChecking.Substitute.Class
import Agda.TypeChecking.Free

import qualified Agda.Utils.List1 as List1
import qualified Agda.Utils.VarSet as VarSet
import Agda.Utils.VarSet (VarSet)
import Agda.Utils.Functor
import Agda.Utils.Maybe
import Agda.Utils.Monad
import Agda.Utils.Null
import Agda.Utils.Size

checkLockedVars
  :: Term
     -- ^ term to check
  -> Type
     -- ^ its type
  -> Arg Term
     -- ^ the lock
  -> Type
     -- ^ type of the lock
  -> TCM ()
checkLockedVars t ty lk lk_ty = catchConstraint (CheckLockedVars t ty lk lk_ty) $ do
  -- Have to instantiate the lock, otherwise we might block on it even
  -- after it's been solved (e.g.: it's an interaction point, see #6528)
  -- Update (Andreas, 2023-10-23, issue #6913): need even full instantiation.
  -- Since @lk@ is typically just a variable, 'instantiateFull' is not expensive here.
  -- In #6913 it was a postulate applied to a meta, thus, 'instantiate' was not enough.
  lk <- instantiateFull lk
  reportSDoc "tc.term.lock" 40 $ "Checking locked vars.."
  reportSDoc "tc.term.lock" 50 $ nest 2 $ vcat
     [ text "t     = " <+> pretty t
     , text "ty    = " <+> pretty ty
     , text "lk    = " <+> pretty lk
     , text "lk_ty = " <+> pretty lk_ty
     ]

  -- Strategy: compute allowed variables, check that @t@ doesn't use more.
  mi <- getLockVar (unArg lk)
  caseMaybe mi (typeError (DoesNotMentionTicks t ty lk)) $ \ i -> do

  cxt <- getContext
  let toCheck = zip [0..] $ zipWith raise [1..] (take i cxt)

  let fv = freeVarsIgnore IgnoreInAnnotations (t,ty)
  let
    rigid = rigidVars fv
    -- flexible = IMap.keysSet $ flexibleVars fv
    termVars = allVars fv -- ISet.union rigid flexible
    earlierVars = VarSet.range i (size cxt)
  if termVars `VarSet.isSubsetOf` earlierVars then return () else do

  checked <- fmap catMaybes . forM toCheck $ \ (j,ce) -> do
    ifM (isTimeless (ctxEntryType ce))
        (return $ Just j)
        (return $ Nothing)

  let allowedVars = VarSet.union earlierVars (VarSet.fromList checked)

  if termVars `VarSet.isSubsetOf` allowedVars then return () else do
  let
    illegalVars = rigid `VarSet.difference` allowedVars
    -- flexVars = flexibleVars fv
    -- blockingMetas = map (`lookupVarMap` flexVars) (ISet.toList $ termVars ISet.\\ allowedVars)
  if null illegalVars then  -- only flexible vars are infringing
    -- TODO: be more precise about which metas
    -- flexVars = flexibleVars fv
    -- blockingMetas = map (`lookupVarMap` flexVars) (ISet.toList $ termVars ISet.\\ allowedVars)
    patternViolation alwaysUnblock
  else
    typeError $ ReferencesFutureVariables t (List1.fromList (VarSet.toAscList illegalVars)) lk i
    -- List1.fromList is guarded by not (null illegalVars)


-- | Precondition: 'Term' is fully instantiated.
getLockVar :: Term -> TCMT IO (Maybe Int)
getLockVar lk = do
  let
    fv = freeVarsIgnore IgnoreInAnnotations lk
    flex = flexibleVars fv

    isLock i = fmap (getLock . domInfo) (domOfBV i) <&> \case
      IsLock{} -> True
      IsNotLock{} -> False

  unless (IMap.null flex) $ do
    let metas = Set.unions $ map (foldrMetaSet Set.insert Set.empty) $ IMap.elems flex
    patternViolation $ unblockOnAnyMeta metas
      -- Andreas, 2023-10-23, issue #6913:
      -- We should not block on solved metas, so we need @lk@ to be fully instantiated,
      -- otherwise it may mention solved metas which end up here.

  is <- filterM isLock $ VarSet.toAscList $ rigidVars fv

  -- Out of the lock variables that appear in @lk@ the one in the
  -- left-most position in the context is what will determine the
  -- available context for the head.
  let mi | Prelude.null is   = Nothing
         | otherwise = Just $ maximum is

  pure mi

isTimeless :: Type -> TCM Bool
isTimeless t = do
  t <- abortIfBlocked t
  timeless <- mapM getName' [builtinInterval, builtinIsOne]
  case unEl t of
    Def q _ | Just q `elem` timeless -> return True
    _                                -> return False

-- | If the first argument is a lock variable, check that all variables in the given set
--   are either earlier than this variable or are timeless.
--
checkEarlierThan :: Term -> VarSet -> TCM Bool
checkEarlierThan lk fvs = do
  getLockVar lk >>= \case
    Nothing -> return True
    Just i  -> allM (isTimeless <=< typeOfBV) $ filter (<= i) $ VarSet.toAscList fvs
