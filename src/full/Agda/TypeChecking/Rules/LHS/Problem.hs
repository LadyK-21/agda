
module Agda.TypeChecking.Rules.LHS.Problem
       ( FlexibleVars , FlexibleVarKind(..) , FlexibleVar(..) , allFlexVars
       , FlexChoice(..) , ChooseFlex(..)
       , ProblemEq(..) , Problem(..) , problemEqs
       , problemRestPats, problemCont, problemInPats
       , AsBinding(..) , DotPattern(..) , AbsurdPattern(..), AnnotationPattern(..)
       , LHSState(..) , lhsTel , lhsOutPat , lhsProblem , lhsTarget
       , LeftoverPatterns(..), getLeftoverPatterns, getUserVariableNames
       ) where

import Prelude hiding (null)

import Control.Monad        ( zipWithM )
import Control.Monad.Writer ( MonadWriter(..), Writer, runWriter )

import Data.Functor (($>))
import Data.IntMap (IntMap)
import qualified Data.IntMap as IntMap
import Data.List ( sortOn )
import qualified Data.Set as Set

import Agda.Syntax.Common
import Agda.Syntax.Position
import Agda.Syntax.Internal
import Agda.Syntax.Abstract (ProblemEq(..))
import qualified Agda.Syntax.Abstract as A

import Agda.TypeChecking.Monad
import Agda.TypeChecking.Substitute
import Agda.TypeChecking.Telescope
import Agda.TypeChecking.Records
import Agda.TypeChecking.Reduce
import Agda.TypeChecking.Pretty

import Agda.Utils.Lens
import Agda.Utils.List
import Agda.Utils.Monad
import Agda.Utils.Null
import Agda.Utils.Singleton
import Agda.Utils.Size
import qualified Agda.Syntax.Common.Pretty as PP

type FlexibleVars   = [FlexibleVar Nat]

-- | When we encounter a flexible variable in the unifier, where did it come from?
--   The alternatives are ordered such that we will assign the higher one first,
--   i.e., first we try to assign a @DotFlex@, then...
data FlexibleVarKind
  = RecordFlex [FlexibleVarKind]
      -- ^ From a record pattern ('ConP').
      --   Saves the 'FlexibleVarKind' of its subpatterns.
  | ImplicitFlex -- ^ From a hidden formal argument or underscore ('WildP').
  | DotFlex      -- ^ From a dot pattern ('DotP').
  | OtherFlex    -- ^ From a non-record constructor or literal ('ConP' or 'LitP').
  deriving (Eq, Show)

-- | Flexible variables are equipped with information where they come from,
--   in order to make a choice which one to assign when two flexibles are unified.
data FlexibleVar a = FlexibleVar
  { flexArgInfo :: ArgInfo
  , flexForced  :: IsForced
  , flexKind    :: FlexibleVarKind
  , flexPos     :: Maybe Int
  , flexVar     :: a
  } deriving (Eq, Show, Functor, Foldable, Traversable)

instance LensArgInfo (FlexibleVar a) where
  getArgInfo = flexArgInfo
  setArgInfo ai fl = fl { flexArgInfo = ai }
  mapArgInfo f  fl = fl { flexArgInfo = f (flexArgInfo fl) }

instance LensHiding (FlexibleVar a)
instance LensOrigin (FlexibleVar a)
instance LensModality (FlexibleVar a)

-- UNUSED
-- defaultFlexibleVar :: a -> FlexibleVar a
-- defaultFlexibleVar a = FlexibleVar Hidden Inserted ImplicitFlex Nothing a

-- UNUSED
-- flexibleVarFromHiding :: Hiding -> a -> FlexibleVar a
-- flexibleVarFromHiding h a = FlexibleVar h ImplicitFlex Nothing a

allFlexVars :: [IsForced] -> Telescope -> FlexibleVars
allFlexVars forced tel = zipWith3 makeFlex (downFrom n) (telToList tel) fs
  where
    n  = size tel
    fs = forced ++ repeat NotForced
    makeFlex i d f = FlexibleVar (getArgInfo d) f ImplicitFlex (Just i) i

data FlexChoice = ChooseLeft | ChooseRight | ChooseEither | ExpandBoth
  deriving (Eq, Show)

instance Semigroup FlexChoice where
  ExpandBoth   <> _            = ExpandBoth
  _            <> ExpandBoth   = ExpandBoth
  ChooseEither <> y            = y
  x            <> ChooseEither = x
  ChooseLeft   <> ChooseRight  = ExpandBoth -- If there's dot patterns on both sides,
  ChooseRight  <> ChooseLeft   = ExpandBoth -- we need to eta-expand
  ChooseLeft   <> ChooseLeft   = ChooseLeft
  ChooseRight  <> ChooseRight  = ChooseRight

instance Monoid FlexChoice where
  mempty  = ChooseEither
  mappend = (<>)

class ChooseFlex a where
  chooseFlex :: a -> a -> FlexChoice

instance ChooseFlex FlexibleVarKind where
  chooseFlex DotFlex         DotFlex         = ChooseEither
  chooseFlex DotFlex         _               = ChooseLeft
  chooseFlex _               DotFlex         = ChooseRight
  chooseFlex (RecordFlex xs) (RecordFlex ys) = chooseFlex xs ys
  chooseFlex (RecordFlex xs) y               = chooseFlex xs (repeat y)
  chooseFlex x               (RecordFlex ys) = chooseFlex (repeat x) ys
  chooseFlex ImplicitFlex    ImplicitFlex    = ChooseEither
  chooseFlex ImplicitFlex    _               = ChooseLeft
  chooseFlex _               ImplicitFlex    = ChooseRight
  chooseFlex OtherFlex       OtherFlex       = ChooseEither

instance ChooseFlex a => ChooseFlex [a] where
  chooseFlex xs ys = mconcat $ zipWith chooseFlex xs ys

instance ChooseFlex a => ChooseFlex (Maybe a) where
  chooseFlex Nothing Nothing = ChooseEither
  chooseFlex Nothing (Just y) = ChooseLeft
  chooseFlex (Just x) Nothing = ChooseRight
  chooseFlex (Just x) (Just y) = chooseFlex x y

instance ChooseFlex ArgInfo where
  chooseFlex ai1 ai2 = firstChoice [ chooseFlex (getOrigin ai1) (getOrigin ai2)
                                   , chooseFlex (getHiding ai1) (getHiding ai2) ]

instance ChooseFlex IsForced where
  chooseFlex NotForced NotForced = ChooseEither
  chooseFlex NotForced Forced    = ChooseRight
  chooseFlex Forced    NotForced = ChooseLeft
  chooseFlex Forced    Forced    = ChooseEither

instance ChooseFlex Hiding where
  chooseFlex Hidden     Hidden     = ChooseEither
  chooseFlex Hidden     _          = ChooseLeft
  chooseFlex _          Hidden     = ChooseRight
  chooseFlex Instance{} Instance{} = ChooseEither
  chooseFlex Instance{} _          = ChooseLeft
  chooseFlex _          Instance{} = ChooseRight
  chooseFlex _          _          = ChooseEither

instance ChooseFlex Origin where
  chooseFlex Inserted  Inserted  = ChooseEither
  chooseFlex Inserted  _         = ChooseLeft
  chooseFlex _         Inserted  = ChooseRight
  chooseFlex Reflected Reflected = ChooseEither
  chooseFlex Reflected _         = ChooseLeft
  chooseFlex _         Reflected = ChooseRight
  chooseFlex _         _         = ChooseEither

instance ChooseFlex Int where
  chooseFlex x y = case compare x y of
    LT -> ChooseLeft
    EQ -> ChooseEither
    GT -> ChooseRight

instance (ChooseFlex a) => ChooseFlex (FlexibleVar a) where
  chooseFlex (FlexibleVar ai1 fc1 f1 p1 i1) (FlexibleVar ai2 fc2 f2 p2 i2) =
    firstChoice [ chooseFlex f1 f2, chooseFlex fc1 fc2, chooseFlex ai1 ai2
                , chooseFlex p1 p2, chooseFlex i1 i2]

firstChoice :: [FlexChoice] -> FlexChoice
firstChoice []                  = ChooseEither
firstChoice (ChooseEither : xs) = firstChoice xs
firstChoice (x            : _ ) = x

-- | The user patterns we still have to split on.
data Problem a = Problem
  { _problemEqs      :: [ProblemEq]
    -- ^ User patterns which are typed
    --   (including the ones generated from implicit arguments).
  , _problemRestPats :: [NamedArg A.Pattern]
    -- ^ List of user patterns which could not yet be typed.
    --   Example:
    --   @
    --      f : (b : Bool) -> if b then Nat else Nat -> Nat
    --      f true          = zero
    --      f false zero    = zero
    --      f false (suc n) = n
    --   @
    --   In this sitation, for clause 2, we construct an initial problem
    --   @
    --      problemEqs      = [false = b]
    --      problemRestPats = [zero]
    --   @
    --   As we instantiate @b@ to @false@, the 'targetType' reduces to
    --   @Nat -> Nat@ and we can move pattern @zero@ over to @problemEqs@.
  , _problemCont     :: LHSState a -> TCM a
    -- ^ The code that checks the RHS.
  }
  deriving Show

problemEqs :: Lens' (Problem a) [ProblemEq]
problemEqs f p = f (_problemEqs p) <&> \x -> p {_problemEqs = x}

problemRestPats :: Lens' (Problem a) [NamedArg A.Pattern]
problemRestPats f p = f (_problemRestPats p) <&> \x -> p {_problemRestPats = x}

problemCont :: Lens' (Problem a) (LHSState a -> TCM a)
problemCont f p = f (_problemCont p) <&> \x -> p {_problemCont = x}

problemInPats :: Problem a -> [A.Pattern]
problemInPats = map problemInPat . (^. problemEqs)

data AsBinding = AsB Name Term (Dom Type)
data DotPattern = Dot A.Expr Term (Dom Type)
data AbsurdPattern = Absurd Range Type
data AnnotationPattern = Ann A.Expr Type

-- | State worked on during the main loop of checking a lhs.
--   [Ulf Norell's PhD, page. 35]
data LHSState a = LHSState
  { _lhsTel     :: Telescope
    -- ^ The types of the pattern variables.
  , _lhsOutPat  :: [NamedArg DeBruijnPattern]
    -- ^ Patterns after splitting.
    --   The de Bruijn indices refer to positions in the list of abstract syntax
    --   patterns in the problem, counted from the back (right-to-left).
  , _lhsProblem :: Problem a
    -- ^ User patterns of supposed type @delta@.
  , _lhsTarget  :: Arg Type
    -- ^ Type eliminated by 'problemRestPats' in the problem.
    --   Can be 'Irrelevant' to indicate that we came by
    --   an irrelevant projection and, hence, the rhs must
    --   be type-checked in irrelevant mode.
  , _lhsPartialSplit :: ![Maybe Int]
    -- ^ have we splitted with a PartialFocus?
  , _lhsIndexedSplit :: !Bool
    -- ^ Have we split on any indexed inductive types?
  }

lhsTel :: Lens' (LHSState a) Telescope
lhsTel f p = f (_lhsTel p) <&> \x -> p {_lhsTel = x}

lhsOutPat :: Lens' (LHSState a) [NamedArg DeBruijnPattern]
lhsOutPat f p = f (_lhsOutPat p) <&> \x -> p {_lhsOutPat = x}

lhsProblem :: Lens' (LHSState a) (Problem a)
lhsProblem f p = f (_lhsProblem p) <&> \x -> p {_lhsProblem = x}

lhsTarget :: Lens' (LHSState a) (Arg Type)
lhsTarget f p = f (_lhsTarget p) <&> \x -> p {_lhsTarget = x}

data PatVarPosition = PVLocal | PVParam
  deriving (Show, Eq)

data LeftoverPatterns = LeftoverPatterns
  { patternVariables :: IntMap [(Arg A.Name,PatVarPosition)]
  , asPatterns       :: [AsBinding]
  , dotPatterns      :: [DotPattern]
  , absurdPatterns   :: [AbsurdPattern]
  , typeAnnotations  :: [AnnotationPattern]
  , otherPatterns    :: [A.Pattern]
  }

instance Semigroup LeftoverPatterns where
  x <> y = LeftoverPatterns
    { patternVariables = IntMap.unionWith (++) (patternVariables x) (patternVariables y)
    , asPatterns       = asPatterns x ++ asPatterns y
    , dotPatterns      = dotPatterns x ++ dotPatterns y
    , absurdPatterns   = absurdPatterns x ++ absurdPatterns y
    , typeAnnotations  = typeAnnotations x ++ typeAnnotations y
    , otherPatterns    = otherPatterns x ++ otherPatterns y
    }

instance Null LeftoverPatterns where
  empty = LeftoverPatterns empty [] [] [] [] []
  null (LeftoverPatterns as bs cs ds es fs) = null as && null bs && null cs && null ds && null es && null fs


instance Monoid LeftoverPatterns where
  mempty  = empty
  mappend = (<>)

instance PP.Pretty PatVarPosition where
  pretty = PP.text . show

instance PrettyTCM LeftoverPatterns where
  prettyTCM (LeftoverPatterns varp asb dotp absurdp annp otherp) = vcat
    [ "pattern variables: " <+> pretty (IntMap.toList varp)
    , "as bindings:       " <+> prettyList_ (map prettyTCM asb)
    , "dot patterns:      " <+> prettyList_ (map prettyTCM dotp)
    , "absurd patterns:   " <+> prettyList_ (map prettyTCM absurdp)
    , "type annotations:  " <+> prettyList_ (map prettyTCM annp)
    , "other patterns:    " <+> prettyList_ (map prettyA otherp)
    ]

-- | Classify remaining patterns after splitting is complete into pattern
--   variables, as patterns, dot patterns, and absurd patterns.
--   Precondition: there are no more constructor patterns.
getLeftoverPatterns
  :: forall m. (PureTCM m, MonadFresh NameId m)
  => [ProblemEq] -> m LeftoverPatterns
getLeftoverPatterns eqs = do
  reportSDoc "tc.lhs.top" 30 $ "classifying leftover patterns"
  params <- Set.fromList . teleNames <$> (lookupSection =<< currentModule)
  let isParamName x = if nameToArgName x `Set.member` params then PVParam else PVLocal
  mconcat <$> mapM (getLeftoverPattern isParamName) eqs
  where
    patternVariable x i isPar = empty { patternVariables = singleton (i,[(x,isPar)]) }
    asPattern x v a      = empty { asPatterns       = singleton (AsB x v a) }
    dotPattern e v a     = empty { dotPatterns      = singleton (Dot e v a) }
    absurdPattern info a = empty { absurdPatterns   = singleton (Absurd info a) }
    otherPattern p       = empty { otherPatterns    = singleton p }

    getLeftoverPattern :: (A.Name -> PatVarPosition) -> ProblemEq -> m LeftoverPatterns
    getLeftoverPattern isParamName (ProblemEq p v a) = case p of
      (A.VarP A.BindName{unBind = x}) -> isEtaVar v (unDom a) <&> \case
        Just i -> patternVariable (argFromDom a $> x) i (isParamName x)
        Nothing -> asPattern x v a
      (A.WildP r)
        | isInstance a ->
            -- Issue #7392: If the wildcard appears in an instance position
            -- and is not already bound as an instance in the context,
            -- add it as a let binding.
            ifM (isInstanceVar v $ unDom a) (return mempty) $ do
              -- TODO: avoid fresh name by assigning unique `NameId` to `WildP`s?
              x <- freshNoName (getRange r)
              return $ asPattern x v a
        | otherwise -> return mempty
      (A.AsP info A.BindName{unBind = x} p)  -> (asPattern x v a `mappend`) <$> do
        getLeftoverPattern isParamName $ ProblemEq p v a
      (A.DotP info e)   -> return $ dotPattern e v a
      (A.AbsurdP info)  -> return $ absurdPattern (getRange info) (unDom a)
      _                 -> return $ otherPattern p

      where
        isInstanceVar :: Term -> Type -> m Bool
        isInstanceVar v a = isEtaVar v a >>= \case
            Just i -> isInstance <$> domOfBV i
            Nothing -> return False

-- | Build a renaming for the internal patterns using variable names from
--   the user patterns. If there are multiple user names for the same internal
--   variable, the unused ones are returned as as-bindings.
--   Names that are not also module parameters are preferred over
--   those that are.
getUserVariableNames
  :: Telescope                         -- ^ The telescope of pattern variables
  -> IntMap [(Arg A.Name,PatVarPosition)]  -- ^ The list of user names for each pattern variable
  -> ([Maybe A.Name], [AsBinding])
getUserVariableNames tel names = runWriter $
  zipWithM makeVar (flattenTel tel) (downFrom $ size tel)

  where
    makeVar :: Dom Type -> Int -> Writer [AsBinding] (Maybe A.Name)
    makeVar a i =
      case map fst $ sortOn ((== PVParam) . snd) (IntMap.findWithDefault [] i names) of
        [] -> return Nothing
        (z:zs) -> do
          tellAsBindings $
            -- Issue #7392: if the name that we picked comes from an instance argument
            -- but we are *not* binding it in an instance position, we should
            -- preserve the instance by *also* adding it as a let-binding.
            if isInstance z && not (isInstance a) then z:zs else zs
          return $ Just (unArg z)
      where
        -- Use hiding status of the variable as written rather than from the telescope
        tellAsBindings = tell . map (\y -> AsB (unArg y) (var i) (setHiding (getHiding y) a))

instance Subst (Problem a) where
  type SubstArg (Problem a) = Term
  applySubst rho (Problem eqs rps cont) = Problem (applySubst rho eqs) rps cont

instance Subst AsBinding where
  type SubstArg AsBinding = Term
  applySubst rho (AsB x v a) = (\(v,a) -> AsB x v a) $ applySubst rho (v, a)

instance Subst DotPattern where
  type SubstArg DotPattern = Term
  applySubst rho (Dot e v a) = uncurry (Dot e) $ applySubst rho (v, a)

instance Subst AbsurdPattern where
  type SubstArg AbsurdPattern = Term
  applySubst rho (Absurd r a) = Absurd r $ applySubst rho a

instance PrettyTCM ProblemEq where
  prettyTCM (ProblemEq p v a) = sep
    [ prettyA p <+> "="
    , nest 2 $ prettyTCM v <+> ":"
    , nest 2 $ prettyTCM a
    ]

instance PrettyTCM AsBinding where
  prettyTCM (AsB x v a) =
    sep [ prettyTCM x <> "@" <> parens (prettyTCM v)
        , nest 2 $ ":" <+> prettyTCM a
        ]

instance PrettyTCM DotPattern where
  prettyTCM (Dot e v a) = sep
    [ prettyA e <+> "="
    , nest 2 $ prettyTCM v <+> ":"
    , nest 2 $ prettyTCM a
    ]

instance PrettyTCM AbsurdPattern where
  prettyTCM (Absurd r a) = "() :" <+> prettyTCM a

instance PrettyTCM AnnotationPattern where
  prettyTCM (Ann a p) = prettyTCM p <+> ":" <+> prettyA a

instance PP.Pretty AsBinding where
  pretty (AsB x v a) =
    PP.pretty x PP.<+> "=" PP.<+>
      PP.hang (PP.pretty v PP.<+> ":") 2 (PP.pretty a)

instance InstantiateFull AsBinding where
  instantiateFull' (AsB x v a) = AsB x <$> instantiateFull' v <*> instantiateFull' a

instance PrettyTCM (LHSState a) where
  prettyTCM (LHSState tel outPat (Problem eqs rps _) target _ _) = vcat
    [ "tel             = " <+> prettyTCM tel
    , "outPat          = " <+> addContext tel (prettyTCMPatternList outPat)
    , "problemEqs      = " <+> addContext tel (prettyList_ $ map prettyTCM eqs)
    , "problemRestPats = " <+> prettyList_ (map prettyA rps)
    , "target          = " <+> addContext tel (prettyTCM target)
    ]
