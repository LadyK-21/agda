{-# LANGUAGE TemplateHaskell #-}

module Internal.TypeChecking ( tests ) where

import Agda.Syntax.Common.Pretty
import Agda.Syntax.Internal
import Agda.TypeChecking.Substitute
import Agda.TypeChecking.Telescope
import Agda.Utils.Impossible
import Agda.Utils.Permutation
import Agda.Utils.Size

import Agda.Utils.VarSet (VarSet)
import qualified Agda.Utils.VarSet as VarSet

import Internal.Helpers
import Internal.TypeChecking.Generators hiding ( tests )


---------------------------------------------------------------------------
-- * Tests for "Agda.Utils.Permutation"
---------------------------------------------------------------------------

---------------------------------------------------------------------------
-- * Tests for "Agda.TypeChecking.Telescope"
---------------------------------------------------------------------------

-- | @telFromList . telToList == id@
prop_telToListInv :: TermConfiguration -> Property
prop_telToListInv conf =
  forAll (genC conf) $ \tel ->
  telFromList (telToList tel) == tel

-- | All elements of 'flattenTel' are well-scoped under the original telescope.
prop_flattenTelScope :: TermConfiguration -> Property
prop_flattenTelScope conf =
  forAll (genC conf) $ \tel ->
  all (isWellScoped $ extendWithTelConf tel conf) (flattenTel tel)

-- | 'flattenRevTel' is the reverse of 'flattenTel'.
prop_flattenRevTelScope :: TermConfiguration -> Property
prop_flattenRevTelScope conf =
  forAll @Telescope (genC conf) $ \tel ->
  reverse (flattenTel tel) === flattenRevTel tel

-- | @unflattenTel . flattenTel == id@
prop_flattenTelInv :: TermConfiguration -> Property
prop_flattenTelInv conf =
  forAll (genC conf) $ \tel ->
  unflattenTel (teleNames tel) (flattenTel tel) == tel

-- | 'reorderTel' is stable.
prop_reorderTelStable :: TermConfiguration -> Property
prop_reorderTelStable conf =
  forAll (genC conf) $ \tel ->
  reorderTel (flattenTel tel) == Just (idP (size tel))

-- | The result of splitting a telescope is well-scoped.
prop_splitTelescopeScope :: TermConfiguration -> Property
prop_splitTelescopeScope conf =
  forAll (genC conf)                        $ \tel ->
  forAll (listOfElements [0..size tel - 1]) $ \vs ->
  let SplitTel tel1 tel2 perm = splitTelescope (VarSet.fromList vs) tel
      tel' = telFromList (telToList tel1 ++ telToList tel2)
  in  isWellScoped conf tel'

-- | 'varDependencies' is a superset of the input when all variables are inside the
-- telescope.
prop_varDependenciesSuperset :: TermConfiguration -> Property
prop_varDependenciesSuperset conf =
  forAllShow (genC conf) prettyShow \tel ->
  forAll (listOfElements [0..size tel - 1]) $ \ns ->
    let vs = VarSet.fromList ns
    in vs `VarSet.isSubsetOf` varDependencies tel vs

-- | 'varDependencies' is idempotent when all variables are inside the telescope.
prop_varDependenciesIdempotent :: TermConfiguration -> Property
prop_varDependenciesIdempotent conf =
  forAllShow (genC conf) prettyShow \tel ->
  forAll (listOfElements [0..size tel - 1]) $ \ns ->
    let vs = VarSet.fromList ns
        deps = varDependencies tel vs
    in varDependencies tel deps === deps

-- | 'varDependents' is monotone.
prop_varDependentsMonotone :: TermConfiguration -> Property
prop_varDependentsMonotone conf =
  forAllShow (genC conf) prettyShow \tel ->
  forAll (listOfElements [0..size tel - 1]) $ \ms ->
  forAll (listOfElements ms) $ \ns ->
  let us = VarSet.fromList ms
      vs = VarSet.fromList ns
      usDeps = varDependents tel us
      vsDeps = varDependents tel vs
  in vsDeps `VarSet.isSubsetOf` usDeps

-- | @varDependents tel (varDependents tel vs)@ is a subset of @varDependents tel vs@.
prop_varDependentsCoclosure :: TermConfiguration -> Property
prop_varDependentsCoclosure conf =
  forAllShow (genC conf) prettyShow \tel ->
  forAll (listOfElements [0..size tel - 1]) $ \ns ->
    let vs = VarSet.fromList ns
        deps = varDependents tel vs
    in varDependents tel deps `VarSet.isSubsetOf` deps

-- | The permutation generated when splitting a telescope preserves scoping.
prop_splitTelescopePermScope :: TermConfiguration -> Property
prop_splitTelescopePermScope conf =
      forAllShrink (genC conf) (shrinkC conf)                $ \tel ->
      forAllShrink (listOfElements [0..size tel - 1]) shrink $ \vs ->
  let SplitTel tel1 tel2 perm = splitTelescope (VarSet.fromList vs) tel
      conf1 = extendWithTelConf tel1 conf
      conf2 = conf1 { tcFreeVariables = map (size tel2 +) (tcFreeVariables conf1) }
      conf' = conf  { tcFreeVariables = map (size tel +) (tcFreeVariables conf) ++ vs }
  in  forAllShrink (genC conf') (shrinkC conf') $ \t ->
      isWellScoped conf2 (applySubst (renamingR $ invertP __IMPOSSIBLE__ perm) (t :: Term))


-- -- | The permutation generated when splitting a telescope correctly translates
-- --   between the old and the new telescope.
-- prop_splitTelescopePermInv :: TermConfiguration -> Property
-- prop_splitTelescopePermInv conf =
--       forAll (wellScopedTel conf)               $ \tel ->
--       forAll (listOfElements [0..size tel - 1]) $ \vs ->
--   let SplitTel tel1 tel2 perm = splitTelescope (VarSet.fromList vs) tel
--       tel' = telFromList (telToList tel1 ++ telToList tel2)
--       conf1 = extendWithTelConf tel  conf
--       conf2 = extendWithTelConf tel' conf
--   in  forAll (wellScopedTerm conf1) $ \t1 ->
--       forAll (wellScopedTerm conf2) $ \t2 ->
--   let t1' = rename (invertP __IMPOSSIBLE__ perm) $ rename perm t1
--       t2' = rename perm $ rename (invertP __IMPOSSIBLE__ perm) t2
--   in  t1 == t1' && t2 == t2'


------------------------------------------------------------------------
-- * All tests
------------------------------------------------------------------------

-- Template Haskell hack to make the following $allProperties work
-- under ghc-7.8.
return [] -- KEEP!

-- | All tests as collected by 'allProperties'.
--
-- Using 'allProperties' is convenient and superior to the manual
-- enumeration of tests, since the name of the property is added
-- automatically.

tests :: TestTree
tests = testProperties "Internal.TypeChecking" $allProperties
