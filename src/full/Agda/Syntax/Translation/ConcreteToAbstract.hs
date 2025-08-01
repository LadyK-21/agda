{-| Translation from "Agda.Syntax.Concrete" to "Agda.Syntax.Abstract".
    Involves scope analysis,
    figuring out infix operator precedences and tidying up definitions.
-}

module Agda.Syntax.Translation.ConcreteToAbstract
    ( ToAbstract(..), localToAbstract
    , concreteToAbstract_
    , concreteToAbstract
    , TopLevel(..)
    , TopLevelInfo(..)
    , topLevelModuleName
    , importPrimitives
    , checkAttributes
    ) where

import Prelude hiding ( null, (||) )

import Control.Monad        ( (>=>), (<=<), foldM, forM, forM_, zipWithM, zipWithM_ )
import Control.Applicative  ( liftA2, liftA3 )
import Control.Monad.Except ( runExceptT, MonadError(..) )
import Control.Monad.State  ( StateT, execStateT, get, put )
import Control.Monad.Trans.Maybe
import Control.Monad.Trans  ( lift )

import Data.Bifunctor
import Data.Foldable (traverse_)
import Data.Set (Set)
import Data.Map (Map)
import Data.Functor (void)
import qualified Data.List as List
import qualified Data.Set as Set
import qualified Data.Map as Map
import qualified Data.HashSet as HashSet
import Data.Maybe
import Data.Text qualified as Text
import Data.Void

import Agda.Syntax.Common
import qualified Agda.Syntax.Common.Pretty as P
import Agda.Syntax.Common.Pretty (render, Pretty, pretty, prettyShow)
import Agda.Syntax.Concrete as C
import Agda.Syntax.Concrete.Attribute as CA
import Agda.Syntax.Concrete.Generic
import Agda.Syntax.Concrete.Operators
import Agda.Syntax.Concrete.Pattern
import Agda.Syntax.Abstract as A
import Agda.Syntax.Abstract.Pattern as A
  ( patternVars, checkPatternLinearity, containsAsPattern, lhsCoreApp, lhsCoreWith, noDotOrEqPattern )
import Agda.Syntax.Abstract.Pretty
import Agda.Syntax.Abstract.UsedNames
  ( allUsedNames, allBoundNames )
import qualified Agda.Syntax.Internal as I
import Agda.Syntax.Position
import Agda.Syntax.Literal
import Agda.Syntax.Info as Info
import Agda.Syntax.Concrete.Definitions as C
import Agda.Syntax.Fixity
import Agda.Syntax.Concrete.Fixity (DoWarn(..))
import Agda.Syntax.Notation
import Agda.Syntax.Scope.Base as A
import Agda.Syntax.Scope.Monad
import Agda.Syntax.Translation.AbstractToConcrete (ToConcrete, ConOfAbs)
import Agda.Syntax.DoNotation
import Agda.Syntax.IdiomBrackets
import Agda.Syntax.TopLevelModuleName

import qualified Agda.TypeChecking.Monad.Base.Warning as W
import Agda.TypeChecking.Monad.Base hiding (ModuleInfo, MetaInfo)
import Agda.TypeChecking.Monad.Builtin
import Agda.TypeChecking.Monad.Trace (traceCall, setCurrentRange)
import Agda.TypeChecking.Monad.State hiding (topLevelModuleName)
import qualified Agda.TypeChecking.Monad.State as S (topLevelModuleName)
import Agda.TypeChecking.Monad.Signature (notUnderOpaque)
import Agda.TypeChecking.Monad.MetaVars (registerInteractionPoint)
import Agda.TypeChecking.Monad.Debug
import Agda.TypeChecking.Monad.Env (insideDotPattern, isInsideDotPattern, getCurrentPath)
import Agda.TypeChecking.Rules.Builtin (isUntypedBuiltin, bindUntypedBuiltin, builtinKindOfName)

import Agda.TypeChecking.Patterns.Abstract (expandPatternSynonyms)
import Agda.TypeChecking.Pretty hiding (pretty, prettyA)
import Agda.TypeChecking.Quote (quotedName)
import Agda.TypeChecking.Opacity
import Agda.TypeChecking.Warnings

import Agda.Interaction.FindFile (checkModuleName, rootNameModule, SourceFile(SourceFile))
-- import Agda.Interaction.Imports  -- for type-checking in ghci
import {-# SOURCE #-} Agda.Interaction.Imports (scopeCheckImport)
import Agda.Interaction.Options
import qualified Agda.Interaction.Options.Lenses as Lens
import Agda.Interaction.Options.Warnings

import qualified Agda.Utils.AssocList as AssocList
import Agda.Utils.Boolean   ( (||), ifThenElse )
import Agda.Utils.CallStack ( HasCallStack, withCurrentCallStack )
import Agda.Utils.Char
import Agda.Utils.Either
import Agda.Utils.FileName
import Agda.Utils.Function ( applyWhen, applyWhenJust, applyWhenM, applyUnless )
import Agda.Utils.Functor
import Agda.Utils.Lens
import Agda.Utils.List
import Agda.Utils.List1 ( List1, pattern (:|) )
import Agda.Utils.List2 ( List2, pattern List2 )
import qualified Agda.Utils.List1 as List1
import qualified Agda.Utils.Map as Map
import Agda.Utils.Maybe
import Agda.Utils.Monad
import Agda.Utils.Null
import Agda.Utils.Set1 ( Set1 )
import qualified Agda.Utils.Set1 as Set1
import Agda.Utils.Singleton
import Agda.Utils.Tuple

import Agda.Utils.Impossible ( __IMPOSSIBLE__ )
import Agda.ImpossibleTest (impossibleTest, impossibleTestReduceM)
import qualified Agda.Syntax.Common as A

{--------------------------------------------------------------------------
    Exceptions
 --------------------------------------------------------------------------}

notAnExpression :: (HasCallStack, MonadTCError m) => C.Expr -> m a
notAnExpression = locatedTypeError NotAnExpression

notAValidLetBinding :: (HasCallStack, MonadTCError m) => Maybe NotAValidLetBinding -> m a
notAValidLetBinding = locatedTypeError NotAValidLetBinding

{--------------------------------------------------------------------------
    Helpers
 --------------------------------------------------------------------------}

newtype RecordConstructorType = RecordConstructorType [C.Declaration]

instance ToAbstract RecordConstructorType where
  type AbsOfCon RecordConstructorType = A.Expr
  toAbstract (RecordConstructorType ds) = recordConstructorType ds

-- | Compute the type of the record constructor (with bogus target type)
recordConstructorType :: [C.Declaration] -> ScopeM A.Expr
recordConstructorType decls =
    -- Nicify all declarations since there might be fixity declarations after
    -- the the last field. Use NoWarn to silence fixity warnings. We'll get
    -- them again when scope checking the declarations to build the record
    -- module.
    niceDecls NoWarn decls $ buildType . takeFields
  where
    takeFields = List.dropWhileEnd notField

    notField NiceField{} = False
    notField _           = True

    buildType :: [C.NiceDeclaration] -> ScopeM A.Expr
      -- TODO: Telescope instead of Expr in abstract RecDef
    buildType ds = do
      -- The constructor target type is computed in the type checker.
      -- For now, we put a dummy expression there.
      -- Andreas, 2022-10-06, issue #6165:
      -- The dummy was builtinSet, but this might not be defined yet.
      let dummy = A.Lit empty $ LitString "TYPE"
      tel   <- catMaybes <$> mapM makeBinding ds
      return $ A.mkPi (ExprRange (getRange ds)) tel dummy

    makeBinding :: C.NiceDeclaration -> ScopeM (Maybe A.TypedBinding)
    makeBinding d = do
      let failure = typeError $ NotValidBeforeField d
          r       = getRange d
          mkLet d = Just . A.TLet r <$> toAbstract (LetDef RecordLetDef d)
      setCurrentRange r $ case d of

        C.NiceField r pr ab inst tac x (Arg ai t) -> do
          fx  <- getConcreteFixity x
          ai  <- checkFieldArgInfo True ai
          let bv = Arg ai $ unnamed $ C.mkBinder $ (C.mkBoundName x fx) { bnameTactic = tac }
          toAbstract $ C.TBind r (singleton bv) t

        -- Public open is allowed and will take effect when scope checking as
        -- proper declarations.
        C.NiceOpen r m dir -> do
          mkLet $ C.NiceOpen r m dir{ publicOpen = Nothing }
        C.NiceModuleMacro r p e x modapp open dir -> do
          mkLet $ C.NiceModuleMacro r p e x modapp open
                    dir{ publicOpen = Nothing }

        -- Do some rudimentary matching here to get NotValidBeforeField instead
        -- of NotAValidLetDecl.
        C.NiceMutual _ _ _ _
          [ C.FunSig _ _ _ _ macro _ _ _ _ _
          , C.FunDef _ _ abstract _ _ _ _
             (C.Clause _ _ _ (C.LHS _p [] []) (C.RHS _) NoWhere [] :| [])
          ] | abstract /= AbstractDef && macro /= MacroDef -> do
          mkLet d

        C.NiceLoneConstructor{} -> failure
        C.NiceMutual{}        -> failure
        -- TODO: some of these cases might be __IMPOSSIBLE__
        C.Axiom{}             -> failure
        C.PrimitiveFunction{} -> failure
        C.NiceModule{}        -> failure
        C.NiceImport{}        -> failure
        C.NicePragma{}        -> failure
        C.NiceRecSig{}        -> failure
        C.NiceDataSig{}       -> failure
        C.NiceFunClause{}     -> failure
        C.FunSig{}            -> failure  -- Note: these are bundled with FunDef in NiceMutual
        C.FunDef{}            -> failure
        C.NiceDataDef{}       -> failure
        C.NiceRecDef{}        -> failure
        C.NicePatternSyn{}    -> failure
        C.NiceGeneralize{}    -> failure
        C.NiceUnquoteDecl{}   -> failure
        C.NiceUnquoteDef{}    -> failure
        C.NiceUnquoteData{}   -> failure
        C.NiceOpaque{}        -> failure

checkModuleApplication
  :: C.ModuleApplication
  -> ModuleName
  -> C.Name
  -> C.ImportDirective
  -> ScopeM (A.ModuleApplication, ScopeCopyInfo, A.ImportDirective)

checkModuleApplication (C.SectionApp _ tel m es) m0 x dir' = do
  reportSDoc "scope.decl" 70 $ vcat $
    [ text $ "scope checking ModuleApplication " ++ prettyShow x
    ]

  -- For the following, set the current module to be m0.
  withCurrentModule m0 $ do
    -- Parse the raw arguments of the module application. (See issue #1245.)
    args <- parseArguments (C.Ident m) es
    -- Scope check the telescope (introduces bindings!).
    tel' <- catMaybes <$> toAbstract tel
    -- Scope check the old module name and the module args.
    m1    <- toAbstract $ OldModuleName m
    args' <- toAbstractCtx (ArgumentCtx PreferParen) args
    -- Copy the scope associated with m and take the parts actually imported.
    (adir, s) <- applyImportDirectiveM (C.QName x) dir' =<< getNamedScope m1
    (s', copyInfo) <- copyScope m m0 s
    -- Set the current scope to @s'@
    modifyCurrentScope $ const s'
    printScope "mod.inst" 40 "copied source module"
    reportS "scope.mod.inst" 30 $ pretty copyInfo
    let amodapp = A.SectionApp tel' m1 args'
    reportSDoc "scope.decl" 70 $ vcat $
      [ text $ "scope checked ModuleApplication " ++ prettyShow x
      ]
    reportSDoc "scope.decl" 70 $ vcat $
      [ nest 2 $ prettyA amodapp
      ]
    return (amodapp, copyInfo, adir)

checkModuleApplication (C.RecordModuleInstance _ recN) m0 x dir' =
  withCurrentModule m0 $ do
    m1 <- toAbstract $ OldModuleName recN
    s <- getNamedScope m1
    (adir, s) <- applyImportDirectiveM recN dir' s
    (s', copyInfo) <- copyScope recN m0 s
    modifyCurrentScope $ const s'

    printScope "mod.inst" 40 "copied record module"
    return (A.RecordModuleInstance m1, copyInfo, adir)

-- | @checkModuleMacro mkApply range access concreteName modapp open dir@
--
--   Preserves local variables.

checkModuleMacro
  :: (ToConcrete a, Pretty (ConOfAbs a))
  => (ModuleInfo
      -> Erased
      -> ModuleName
      -> A.ModuleApplication
      -> ScopeCopyInfo
      -> A.ImportDirective
      -> a)
  -> OpenKind
  -> Range
  -> Access
  -> Erased
  -> C.Name
  -> C.ModuleApplication
  -> OpenShortHand
  -> C.ImportDirective
  -> ScopeM a
checkModuleMacro apply kind r p e x modapp open dir = do
    reportSDoc "scope.decl" 70 $ vcat $
      [ text $ "scope checking ModuleMacro " ++ prettyShow x
      ]
    dir <- notPublicWithoutOpen open dir

    m0 <- toAbstract (NewModuleName x)
    reportSDoc "scope.decl" 90 $ "NewModuleName: m0 =" <+> prettyA m0

    printScope "mod.inst" 40 "module macro"

    -- If we're opening a /named/ module, the import directive is
    -- applied to the "open", otherwise to the module itself. However,
    -- "public" is always applied to the "open".
    let (moduleDir, openDir) = case (open, isNoName x) of
          (DoOpen,   False) -> (defaultImportDir, dir)
          (DoOpen,   True)  -> ( dir { publicOpen = Nothing }
                               , defaultImportDir { publicOpen = publicOpen dir }
                               )
          (DontOpen, _)     -> (dir, defaultImportDir)

    -- Restore the locals after module application has been checked.
    (modapp', copyInfo', adir') <- withLocalVars $ checkModuleApplication modapp m0 x moduleDir

    -- Mark the copy as being private (renPublic = False) if the module
    -- name is PrivateAccess and not open public.
    -- If the user gave an explicit 'using'/'renaming'/etc, keep the
    -- copy as 'public' to avoid trimming.
    let
      visible = case p of
        PrivateAccess{} -> not (null dir) || isJust (publicOpen dir)
        _               -> True

      copyInfo = copyInfo'{ renPublic = visible }

    printScope "mod.inst.app" 40 "checkModuleMacro, after checkModuleApplication"

    reportSDoc "scope.decl" 90 $ "after mod app: trying to print m0 ..."
    reportSDoc "scope.decl" 90 $ "after mod app: m0 =" <+> prettyA m0

    bindModule p x m0
    reportSDoc "scope.decl" 90 $ "after bindMod: m0 =" <+> prettyA m0

    printScope "mod.inst.copy.after" 40 "after copying"

    -- Open the module if DoOpen.
    -- Andreas, 2014-09-02: @openModule@ might shadow some locals!
    adir <- case open of
      DontOpen -> return adir'
      DoOpen   -> do
        adir'' <- openModule kind (Just m0) (C.QName x) openDir
        -- Andreas, 2020-05-14, issue #4656
        -- Keep the more meaningful import directive for highlighting
        -- (the other one is a defaultImportDir).
        return $ if isNoName x then adir' else adir''

    printScope "mod.inst" 40 $ show open
    reportSDoc "scope.decl" 90 $ "after open   : m0 =" <+> prettyA m0

    stripNoNames
    printScope "mod.inst.strip" 30 $ "after stripping"
    reportSDoc "scope.decl" 90 $ "after stripNo: m0 =" <+> prettyA m0

    let m      = m0 `withRangesOf` singleton x
        adecl  = apply info e m modapp' copyInfo adir

    reportSDoc "scope.decl" 70 $ vcat $
      [ text $ "scope checked ModuleMacro " ++ prettyShow x
      ]
    reportSLn  "scope.decl" 90 $ "info    = " ++ show info
    reportSLn  "scope.decl" 90 $ "m       = " ++ prettyShow m
    reportSLn  "scope.decl" 90 $ "modapp' = " ++ show modapp'
    reportS    "scope.decl" 90 $ pretty copyInfo
    reportSDoc "scope.decl" 70 $ nest 2 $ prettyA adecl
    return adecl
  where
    info = ModuleInfo
             { minfoRange  = r
             , minfoAsName = Nothing
             , minfoAsTo   = renamingRange dir
             , minfoOpenShort = Just open
             , minfoDirective = Just dir
             }

-- | The @public@ keyword must only be used together with @open@.

notPublicWithoutOpen :: OpenShortHand -> C.ImportDirective -> ScopeM C.ImportDirective
notPublicWithoutOpen DoOpen   = return
notPublicWithoutOpen DontOpen = uselessPublic UselessPublicNoOpen

-- | Warn about useless @public@.

uselessPublic :: UselessPublicReason -> C.ImportDirective -> ScopeM C.ImportDirective
uselessPublic reason dir = do
  whenJust (publicOpen dir) \ r ->
    setCurrentRange r $ warning $ UselessPublic reason
  return $ dir { publicOpen = Nothing }

-- | Computes the range of all the \"to\" keywords used in a renaming
-- directive.

renamingRange :: C.ImportDirective -> Range
renamingRange = getRange . map renToRange . impRenaming

-- | Scope check a 'NiceOpen'.
checkOpen
  :: Range                -- ^ Range of @open@ statement.
  -> Maybe A.ModuleName   -- ^ Resolution of concrete module name (if already resolved).
  -> C.QName              -- ^ Module to open.
  -> C.ImportDirective    -- ^ Scope modifier.
  -> ScopeM (ModuleInfo, A.ModuleName, A.ImportDirective) -- ^ Arguments of 'A.Open'
checkOpen r mam x dir = do
  cm <- getCurrentModule
  reportSDoc "scope.decl" 70 $ do
    vcat $
      [ text   "scope checking NiceOpen " <> return (pretty x)
      , text   "  getCurrentModule       = " <> prettyA cm
      , text $ "  getCurrentModule (raw) = " ++ show cm
      , text $ "  C.ImportDirective      = " ++ prettyShow dir
      ]
  -- Andreas, 2017-01-01, issue #2377: warn about useless `public`
  dir <- if null cm then uselessPublic UselessPublicPreamble dir else return dir

  m <- caseMaybe mam (toAbstract (OldModuleName x)) return
  printScope "open" 40 $ "opening " ++ prettyShow x
  adir <- openModule TopOpenModule (Just m) x dir
  printScope "open" 40 $ "result:"
  let minfo = ModuleInfo
        { minfoRange     = r
        , minfoAsName    = Nothing
        , minfoAsTo      = renamingRange dir
        , minfoOpenShort = Nothing
        , minfoDirective = Just dir
        }
  let adecls = [A.Open minfo m adir]
  reportSDoc "scope.decl" 70 $ vcat $
    text ( "scope checked NiceOpen " ++ prettyShow x
         ) : map (nest 2 . prettyA) adecls
  return (minfo, m, adir)

-- | Check a literal, issuing an error warning for bad literals.
checkLiteral :: Literal -> ScopeM ()
checkLiteral = \case
  LitChar   c   -> when (isSurrogateCodePoint c) $ warning $ InvalidCharacterLiteral c
  LitNat    _   -> return ()
  LitWord64 _   -> return ()
  LitFloat  _   -> return ()
  LitString _   -> return ()
  LitQName  _   -> return ()
  LitMeta   _ _ -> return ()

{--------------------------------------------------------------------------
    Translation
 --------------------------------------------------------------------------}

concreteToAbstract_ :: ToAbstract c => c -> ScopeM (AbsOfCon c)
concreteToAbstract_ = toAbstract

concreteToAbstract :: ToAbstract c => ScopeInfo -> c -> ScopeM (AbsOfCon c)
concreteToAbstract scope x = withScope_ scope (toAbstract x)

-- | Things that can be translated to abstract syntax are instances of this
--   class.
class ToAbstract c where
    type AbsOfCon c
    toAbstract :: c -> ScopeM (AbsOfCon c)

-- | This function should be used instead of 'toAbstract' for things that need
--   to keep track of precedences to make sure that we don't forget about it.
toAbstractCtx :: ToAbstract c => Precedence -> c-> ScopeM (AbsOfCon c)
toAbstractCtx ctx c = withContextPrecedence ctx $ toAbstract c

--UNUSED Liang-Ting Chen 2019-07-16
--toAbstractTopCtx :: ToAbstract c a => c -> ScopeM a
--toAbstractTopCtx = toAbstractCtx TopCtx

toAbstractHiding :: (LensHiding h, ToAbstract c) => h -> c -> ScopeM (AbsOfCon c)
toAbstractHiding h | visible h = toAbstract -- don't change precedence if visible
toAbstractHiding _             = toAbstractCtx TopCtx

--UNUSED Liang-Ting Chen 2019-07-16
--setContextCPS :: Precedence -> (a -> ScopeM b) ->
--                 ((a -> ScopeM b) -> ScopeM b) -> ScopeM b
--setContextCPS p ret f = do
--  old <- useScope scopePrecedence
--  withContextPrecedence p $ f $ \ x -> setContextPrecedence old >> ret x
--
--localToAbstractCtx :: ToAbstract c =>
--                     Precedence -> c -> (AbsOfCon -> ScopeM (AbsOfCon c)) -> ScopeM (AbsOfCon c)
--localToAbstractCtx ctx c ret = setContextCPS ctx ret (localToAbstract c)

-- | This operation does not affect the scope, i.e. the original scope
--   is restored upon completion.
localToAbstract :: ToAbstract c => c -> (AbsOfCon c -> ScopeM b) -> ScopeM b
localToAbstract x ret = localScope $ ret =<< toAbstract x

-- | Like 'localToAbstract' but returns the scope after the completion of the
--   second argument.
localToAbstract' :: ToAbstract c => c -> (AbsOfCon c -> ScopeM b) -> ScopeM (b, ScopeInfo)
localToAbstract' x ret = do
  scope <- getScope
  withScope scope $ ret =<< toAbstract x

instance ToAbstract () where
  type AbsOfCon () = ()
  toAbstract = pure

instance (ToAbstract c1, ToAbstract c2) => ToAbstract (c1, c2) where
  type AbsOfCon (c1, c2) = (AbsOfCon c1, AbsOfCon c2)
  toAbstract (x,y) = (,) <$> toAbstract x <*> toAbstract y

instance (ToAbstract c1, ToAbstract c2, ToAbstract c3) => ToAbstract (c1, c2, c3) where
  type AbsOfCon (c1, c2, c3) = (AbsOfCon c1, AbsOfCon c2, AbsOfCon c3)
  toAbstract (x,y,z) = flatten <$> toAbstract (x,(y,z))
    where
      flatten (x,(y,z)) = (x,y,z)

instance ToAbstract c => ToAbstract [c] where
  type AbsOfCon [c] = [AbsOfCon c]
  toAbstract = mapM toAbstract

instance ToAbstract c => ToAbstract (List1 c) where
  type AbsOfCon (List1 c) = List1 (AbsOfCon c)
  toAbstract = mapM toAbstract

instance (ToAbstract c1, ToAbstract c2) => ToAbstract (Either c1 c2) where
  type AbsOfCon (Either c1 c2) = Either (AbsOfCon c1) (AbsOfCon c2)
  toAbstract = traverseEither toAbstract toAbstract

instance ToAbstract c => ToAbstract (Maybe c) where
  type AbsOfCon (Maybe c) = Maybe (AbsOfCon c)
  toAbstract = traverse toAbstract

-- Names ------------------------------------------------------------------

data NewName a = NewName
  { newBinder   :: A.BindingSource -- what kind of binder?
  , newName     :: a
  } deriving (Functor)

data OldQName = OldQName
  C.QName
    -- ^ Concrete name to be resolved.
  (Maybe (Set1 A.Name))
    -- ^ If a set is given, then the first name must
    --   correspond to one of the names in the set.

-- | We sometimes do not want to fail hard if the name is not actually
--   in scope because we have a strategy to recover from this problem
--   (e.g. drop the offending COMPILE pragma)
data MaybeOldQName = MaybeOldQName OldQName

-- | Wrapper for a concrete name that we already bound to an 'A.Def'.
--
newtype OldName a = OldName a

-- | Wrapper to resolve a name in a pattern.
data PatName = PatName
  C.QName
    -- ^ Concrete name to be resolved in a pattern.
  (Maybe (Set1 A.Name))
    -- ^ If a set is given, then the first name must correspond to one
    --   of the names in the set.
  Hiding
    -- ^ If pattern variable is hidden, its status is indicated in 'Hiding'.
  DisplayLHS
    -- ^ If we parse the lhs of a 'DisplayPragma',
    --   names of arbitrary definitions count as constructors.

instance ToAbstract (NewName C.Name) where
  type AbsOfCon (NewName C.Name) = A.Name
  toAbstract (NewName b x) = do
    y <- freshAbstractName_ x
    bindVariable b x y
    return y

instance ToAbstract (NewName C.BoundName) where
  type AbsOfCon (NewName C.BoundName) = A.BindName
  toAbstract NewName{ newBinder = b, newName = BName{ boundName = x, bnameFixity = fx }} = do
    y <- freshAbstractName fx x
    bindVariable b x y
    return $ A.BindName y

instance ToAbstract OldQName where
  type AbsOfCon OldQName = A.Expr
  toAbstract q@(OldQName x _) =
    fromMaybeM (notInScopeError x) $ toAbstract (MaybeOldQName q)

instance ToAbstract MaybeOldQName where
  type AbsOfCon MaybeOldQName = Maybe A.Expr
  toAbstract (MaybeOldQName (OldQName x ns)) = do
    qx <- resolveName' allKindsOfNames ns x
    reportSLn "scope.name" 30 $ "resolved " ++ prettyShow x ++ ": " ++ prettyShow qx
    case qx of
      VarName x' _         -> return $ Just $ A.Var x'
      DefinedName _ d suffix -> do
        raiseWarningsOnUsage $ anameName d
        -- then we take note of generalized names used
        addGeneralizable d
        -- and then we return the name
        return $ withSuffix suffix $ nameToExpr d
        where
          withSuffix NoSuffix   e         = Just e
          withSuffix s@Suffix{} (A.Def x) = Just $ A.Def' x s
          withSuffix _          _         = Nothing

      FieldName     ds     -> ambiguous (A.Proj ProjPrefix) ds
      ConstructorName _ ds -> ambiguous A.Con ds
      PatternSynResName ds -> ambiguous A.PatternSyn ds
      UnknownName          -> do
        reportSLn "scope.name.unknown" 80 $ "resolved : unknown " ++ prettyShow x
        pure Nothing
    where
      ambiguous :: (AmbiguousQName -> A.Expr) -> List1 AbstractName -> ScopeM (Maybe A.Expr)
      ambiguous f ds = do
        let xs = fmap anameName ds
        raiseWarningsOnUsageIfUnambiguous xs
        return $ Just $ f $ AmbQ xs

      -- Note: user warnings on ambiguous names will be raised by the type checker,
      -- see 'storeDisambiguatedName'.
      raiseWarningsOnUsageIfUnambiguous :: List1 A.QName -> ScopeM ()
      raiseWarningsOnUsageIfUnambiguous = \case
        x :| [] -> raiseWarningsOnUsage x
        _       -> return ()

-- | Resolve a name and fail hard if it is not in scope.
--
resolveQName :: C.QName -> ScopeM ResolvedName
resolveQName x = resolveName x >>= \case
    UnknownName -> notInScopeError x
    q -> q <$ addGeneralizable q
      -- Issue #7575:
      -- If the name is a @variable@, add it to the things we wish to generalize.
      -- If generalization is not supported here, this will throw an error.

-- | A name resolved in a pattern.
data APatName
  = VarPatName A.Name
      -- ^ Pattern variable.
  | ConPatName (List1 AbstractName)
      -- ^ A (possibly ambiguous) constructor.
      --   When parsing a 'C.DisplayPragma', this can be the name of a definition.
  | PatternSynPatName (List1 AbstractName)
      -- ^ A (possibly ambiguous) pattern synonym.
  | DefPatName AbstractName
      -- ^ A defined name, only possible when checking a 'C.DisplayPragma'.

instance ToAbstract PatName where
  type AbsOfCon PatName = APatName
  toAbstract (PatName x ns h displayLhs) = do
    reportSLn "scope.pat" 30 $ "checking pattern name: " ++ prettyShow x
    let kinds = applyWhen displayLhs (defNameKinds ++) conLikeNameKinds
    rx <- resolveName' (someKindsOfNames kinds) ns x
          -- Andreas, 2013-03-21 ignore conflicting names which cannot
          -- be meant since we are in a pattern
          -- Andreas, 2020-04-11 CoConName:
          -- coinductive constructors will be rejected later, in the type checker
    reportSLn "scope.pat" 40 $ "resolved as " ++ prettyShow rx
    case rx of
      ConstructorName _ ds -> ConPatName ds <$ do
        reportSLn "scope.pat" 30 $ "it was a con: " ++ prettyShow (fmap anameName ds)
      PatternSynResName ds -> PatternSynPatName ds <$ do
        reportSLn "scope.pat" 30 $ "it was a pat syn: " ++ prettyShow (fmap anameName ds)
      DefinedName _ d suffix | YesDisplayLHS <- displayLhs, null suffix -> DefPatName d <$ do
        reportSLn "scope.pat" 30 $ "it was a def: " ++ prettyShow (anameName d)
      _ -> case x of
        C.QName y -> VarPatName <$> bindPatternVariable h y
        C.Qual{}  -> typeError $ InvalidPattern $ C.IdentP True x

-- | Translate and possibly bind a pattern variable
--   (which could have been bound before due to non-linearity).
bindPatternVariable :: Hiding -> C.Name -> ScopeM A.Name
bindPatternVariable h x = do
  y <- (AssocList.lookup x <$> getVarsToBind) >>= \case
    Just (LocalVar y _ _) -> do
      reportSLn "scope.pat" 30 $ "it was a old var: " ++ prettyShow x
      return $ setRange (getRange x) y
    Nothing -> do
      reportSLn "scope.pat" 30 $ "it was a new var: " ++ prettyShow x
      freshAbstractName_ x
  addVarToBind x $ LocalVar y (PatternBound h) []
  return y

class ToQName a where
  toQName :: a -> C.QName

instance ToQName C.Name  where toQName = C.QName
instance ToQName C.QName where toQName = id

-- | Should be a defined name.
instance ToQName a => ToAbstract (OldName a) where
  type AbsOfCon (OldName a) = A.QName
  toAbstract (OldName x) = do
    resolveName (toQName x) >>= \case
      DefinedName _ d NoSuffix -> return $ anameName d
      DefinedName _ d Suffix{} -> __IMPOSSIBLE__
      VarName{}                -> __IMPOSSIBLE__
      UnknownName              -> __IMPOSSIBLE__
      -- We can get the cases below for DISPLAY pragmas
      ConstructorName _ ds -> return $ anameName (List1.head ds)   -- We'll throw out this one, so it doesn't matter which one we pick
      FieldName ds         -> return $ anameName (List1.head ds)
      PatternSynResName ds -> return $ anameName (List1.head ds)

newtype NewModuleName      = NewModuleName      C.Name
newtype NewModuleQName     = NewModuleQName     C.QName
newtype OldModuleName      = OldModuleName      C.QName

freshQModule :: A.ModuleName -> C.Name -> ScopeM A.ModuleName
freshQModule m x = A.qualifyM m . mnameFromList1 . singleton <$> freshAbstractName_ x

checkForModuleClash :: C.Name -> ScopeM ()
checkForModuleClash x = do
  ms :: [AbstractModule] <- scopeLookup (C.QName x) <$> getScope
  List1.unlessNull ms \ ms -> do
    reportSLn "scope.clash" 40 $ "clashing modules ms = " ++ prettyShow ms
    reportSLn "scope.clash" 60 $ "clashing modules ms = " ++ show ms
    setCurrentRange x $
      typeError $ ShadowedModule x $ fmap ((`withRangeOf` x) . amodName) ms

instance ToAbstract NewModuleName where
  type AbsOfCon NewModuleName = A.ModuleName
  toAbstract (NewModuleName x) = do
    checkForModuleClash x
    m <- getCurrentModule
    y <- freshQModule m x
    createModule Nothing y
    return y

instance ToAbstract NewModuleQName where
  type AbsOfCon NewModuleQName = A.ModuleName
  toAbstract (NewModuleQName m) = toAbs noModuleName m
    where
      toAbs m (C.QName x)  = do
        y <- freshQModule m x
        createModule Nothing y
        return y
      toAbs m (C.Qual x q) = do
        m' <- freshQModule m x
        toAbs m' q

instance ToAbstract OldModuleName where
  type AbsOfCon OldModuleName = A.ModuleName

  toAbstract (OldModuleName q) = setCurrentRange q $ do
    amodName <$> resolveModule q

-- Expressions ------------------------------------------------------------
--UNUSED Liang-Ting Chen 2019-07-16
---- | Peel off 'C.HiddenArg' and represent it as an 'NamedArg'.
--mkNamedArg :: C.Expr -> NamedArg C.Expr
--mkNamedArg (C.HiddenArg   _ e) = Arg (hide         defaultArgInfo) e
--mkNamedArg (C.InstanceArg _ e) = Arg (makeInstance defaultArgInfo) e
--mkNamedArg e                   = Arg defaultArgInfo $ unnamed e

-- | Peel off 'C.HiddenArg' and represent it as an 'Arg', throwing away any name.
mkArg' :: ArgInfo -> C.Expr -> Arg C.Expr
mkArg' info (C.HiddenArg   _ e) = Arg (hide         info) $ namedThing e
mkArg' info (C.InstanceArg _ e) = Arg (makeInstance info) $ namedThing e
mkArg' info e                   = Arg (setHiding NotHidden info) e

inferParenPreference :: C.Expr -> ParenPreference
inferParenPreference C.Paren{} = PreferParen
inferParenPreference _         = PreferParenless

-- | Scope check the argument in an 'C.App', giving special treatment to 'C.Dot'
--   which in some situation can be interpreted as post-fix projection.
toAbstractArgument :: NamedArg C.Expr -> ScopeM (NamedArg A.Expr, ParenPreference)
toAbstractArgument e = do
  case namedArg e of

    -- Andreas, 2025-07-15, issue #7954: do not allow parentheses around postfix projections.
    C.Dot kwr ex
      | null (getArgInfo e) -> do
          -- @ex@ may only be an identifier
          y <- toAbstractIdent ex $ fail InvalidDottedExpression
          return (defaultNamedArg $ A.Dot (ExprRange $ getRange e) y, PreferParenless)

      -- Andreas, 2021-02-10, issue #3289: reject @e {.p}@ and @e ⦃ .p ⦄@.
      -- Raise an error if argument is a C.Dot with Hiding info.
      | otherwise -> fail $ IllegalHidingInPostfixProjection e

    -- Ordinary function argument.
    _ -> do
      let parenPref = inferParenPreference (namedArg e)
      (,parenPref) <$> toAbstractCtx (ArgumentCtx parenPref) e
  where
    fail :: TypeError -> ScopeM a
    fail = setCurrentRange e . typeError


-- | Check an identifier in scope.
toAbstractIdent :: C.Expr -> ScopeM A.Expr -> ScopeM A.Expr
toAbstractIdent e fallback = traceCall (ScopeCheckExpr e) do
  case e of
    C.Ident        x -> toAbstract (OldQName x Nothing)
    C.KnownIdent _ x -> toAbstract (OldQName x Nothing)
    _ -> fallback

-- | Parse a possibly dotted and braced @C.Expr@ as @A.Expr@,
--   interpreting dots as relevance and braces as hiding.
--   Only accept a layer of dotting/bracing if the respective accumulator is @Nothing@.
toAbstractDotHiding :: Maybe Relevance -> Maybe Hiding -> Precedence -> C.Expr -> ScopeM (A.Expr, Relevance, Hiding)
toAbstractDotHiding mr mh prec e = do
    reportSLn "scope.irrelevance" 100 $ "toAbstractDotHiding: " ++ render (pretty e)
    traceCall (ScopeCheckExpr e) $ case e of

      C.RawApp _ es     -> toAbstractDotHiding mr mh prec =<< parseApplication es
      C.Paren _ e       -> toAbstractDotHiding mr mh TopCtx e

      C.Dot kwr e
        | Nothing <- mr -> toAbstractDotHiding (Just $ Irrelevant $ OIrrDot $ getRange kwr) mh prec e

      C.DoubleDot kwr e
        | Nothing <- mr -> toAbstractDotHiding (Just $ ShapeIrrelevant $ OShIrrDotDot $ getRange kwr) mh prec e

      C.HiddenArg _ (Named Nothing e)
        | Nothing <- mh -> toAbstractDotHiding mr (Just Hidden) TopCtx e

      C.InstanceArg _ (Named Nothing e)
        | Nothing <- mh -> toAbstractDotHiding mr (Just $ Instance NoOverlap) TopCtx e

      e                 -> (, fromMaybe relevant mr, fromMaybe NotHidden mh) <$>
                             toAbstractCtx prec e

-- | Translate concrete expression under at least one binder into nested
--   lambda abstraction in abstract syntax.
toAbstractLam :: Range -> List1 C.LamBinding -> C.Expr -> Precedence -> ScopeM A.Expr
toAbstractLam r bs e ctx = do
  -- Translate the binders
  lvars0 <- getLocalVars
  localToAbstract (fmap (C.DomainFull . makeDomainFull) bs) $ \ bs -> do
    lvars1 <- getLocalVars
    checkNoShadowing lvars0 lvars1
    -- Translate the body
    e <- toAbstractCtx ctx e
    -- We have at least one binder.  Get first @b@ and rest @bs@.
    return $ case List1.catMaybes bs of
      -- Andreas, 2020-06-18
      -- There is a pathological case in which we end up without binder:
      --   λ (let
      --        mutual -- warning: empty mutual block
      --     ) -> Set
      []   -> e
      b:bs -> A.Lam (ExprRange r) b $ foldr mkLam e bs
  where
    mkLam b e = A.Lam (ExprRange $ fuseRange b e) b e

-- | Scope check extended lambda expression.
scopeCheckExtendedLam ::
  Range -> Erased -> List1 C.LamClause -> ScopeM A.Expr
scopeCheckExtendedLam r e cs = do
  whenM isInsideDotPattern $ typeError $ NotAllowedInDotPatterns PatternLambdas

  -- Find an unused name for the extended lambda definition.
  cname <- freshConcreteName r 0 extendedLambdaName
  name  <- freshAbstractName_ cname
  a <- asksTC (^. lensIsAbstract)
  reportSDoc "scope.extendedLambda" 30 $ vcat
    [ text $ "new extended lambda name (" ++ show a ++ "): " ++ prettyShow name
    ]
  verboseS "scope.extendedLambda" 60 $ do
    forM_ cs $ \ c -> do
      reportSLn "scope.extendedLambda" 60 $ "extended lambda lhs: " ++ show (C.lamLHS c)
  qname <- qualifyName_ name
  bindName privateAccessInserted FunName cname qname

  -- Andreas, 2019-08-20
  -- Keep the following __IMPOSSIBLE__, which is triggered by -v scope.decl.trace:80,
  -- for testing issue #4016.
  d <- C.FunDef r __IMPOSSIBLE__ a NotInstanceDef __IMPOSSIBLE__ __IMPOSSIBLE__ cname <$> do
          forM cs $ \ (LamClause ps rhs ca) -> do
            let p   = C.rawAppP $
                        killRange (IdentP True $ C.QName cname) :| ps
            let lhs = C.LHS p [] []
            return $ C.Clause cname ca defaultArgInfo lhs rhs NoWhere []
  scdef <- toAbstract d

  -- Create the abstract syntax for the extended lambda.
  case scdef of
    A.ScopedDecl si [A.FunDef di qname' cs] -> do
      setScope si  -- This turns into an A.ScopedExpr si $ A.ExtendedLam...
      return $
        A.ExtendedLam (ExprRange r) di e qname' cs
    _ -> __IMPOSSIBLE__

-- | Scope check an expression.

instance ToAbstract C.Expr where
  type AbsOfCon C.Expr = A.Expr

  toAbstract e =
    traceCall (ScopeCheckExpr e) $ annotateExpr $ case e of

  -- Names
      C.Ident x -> toAbstract (OldQName x Nothing)
      C.KnownIdent _ x -> toAbstract (OldQName x Nothing)
      -- Just discard the syntax highlighting information.

  -- Literals
      C.Lit r l -> do
        checkLiteral l
        case l of
          LitNat n -> do
            let builtin | n < 0     = Just <$> primFromNeg    -- negative literals are only allowed if FROMNEG is defined
                        | otherwise = ensureInScope =<< getBuiltin' builtinFromNat
            builtin >>= \case
              Just (I.Def q _) -> return $ mkApp q $ A.Lit i $ LitNat $ abs n
              _                -> return alit

          LitString s -> do
            getBuiltin' builtinFromString >>= ensureInScope >>= \case
              Just (I.Def q _) -> return $ mkApp q alit
              _                -> return alit

          _ -> return alit
        where
        i       = ExprRange r
        alit    = A.Lit i l
        mkApp q = A.App (defaultAppInfo r) (A.Def q) . defaultNamedArg

        -- #4925: Require fromNat/fromNeg to be in scope *unqualified* for literal overloading to
        -- apply.
        ensureInScope :: Maybe I.Term -> ScopeM (Maybe I.Term)
        ensureInScope v@(Just (I.Def q _)) =
          ifM (isNameInScopeUnqualified q <$> getScope) (return v) (return Nothing)
        ensureInScope _ = return Nothing

  -- Meta variables
      C.QuestionMark r n -> do
        scope <- getScope
        -- Andreas, 2014-04-06 create interaction point.
        ii <- registerInteractionPoint True r n
        let info = MetaInfo
             { metaRange  = r
             , metaScope  = scope
             , metaNumber = Nothing
             , metaNameSuggestion = ""
             , metaKind   = UnificationMeta
             }
        return $ A.QuestionMark info ii
      C.Underscore r n -> do
        scope <- getScope
        return $ A.Underscore $ MetaInfo
                    { metaRange  = r
                    , metaScope  = scope
                    , metaNumber = __IMPOSSIBLE__ =<< n
                    , metaNameSuggestion = fromMaybe "" n
                    , metaKind   = UnificationMeta
                    }

  -- Raw application
      C.RawApp r es -> do
        e <- parseApplication es
        toAbstract e

  -- Application
      C.App r e1 e2 -> do
        e1 <- toAbstractCtx FunctionCtx e1
        (e2, parenPref) <- toAbstractArgument e2
        let info = (defaultAppInfo r) { appOrigin = UserWritten, appParens = parenPref }
        return $ A.App info e1 e2

  -- Operator application
      C.OpApp r op ns es -> toAbstractOpApp op ns es
      C.KnownOpApp _ r op ns es -> toAbstractOpApp op ns es

  -- With application
      C.WithApp r e es -> do
        e  <- toAbstractCtx WithFunCtx e
        es <- mapM (toAbstractCtx WithArgCtx) es
        return $ A.WithApp (ExprRange r) e es

  -- Misplaced hidden argument. We can treat these as parentheses and
  -- raise an error-warning
      C.HiddenArg _ e' -> do
        warning (HiddenNotInArgumentPosition e)
        toAbstract (namedThing e')

      C.InstanceArg _ e' -> do
        warning (InstanceNotInArgumentPosition e)
        toAbstract (namedThing e')

  -- Lambda
      C.AbsurdLam r h -> return $ A.AbsurdLam (ExprRange r) h

      C.Lam r bs e -> toAbstractLam r bs e TopCtx

  -- Extended Lambda
      C.ExtendedLam r e cs -> scopeCheckExtendedLam r e cs

  -- Relevant and irrelevant non-dependent function type
      C.Fun r (Arg info1 e1) e2 -> do
        let arg = mkArg' info1 e1
        let mr = case getRelevance arg of
              Relevant{} -> Nothing
              r -> Just r
        let mh = case getHiding arg of
              NotHidden -> Nothing
              h         -> Just h
        Arg info (e1', rel, hid) <- traverse (toAbstractDotHiding mr mh FunctionSpaceDomainCtx) arg
        let updRel = applyUnless (isRelevant rel) $ setRelevance rel
        let updHid = case hid of
              NotHidden -> id
              hid       -> setHiding hid
        A.Fun (ExprRange r) (Arg (updRel $ updHid info) e1') <$> toAbstractCtx TopCtx e2

  -- Dependent function type
      e0@(C.Pi tel e) -> do
        lvars0 <- getLocalVars
        localToAbstract tel $ \tel -> do
          lvars1 <- getLocalVars
          checkNoShadowing lvars0 lvars1
          e <- toAbstractCtx TopCtx e
          let info = ExprRange (getRange e0)
          return $ A.mkPi info (List1.catMaybes tel) e

  -- Let
      e0@(C.Let _ ds (Just e)) ->
        ifM isInsideDotPattern (typeError $ NotAllowedInDotPatterns LetExpressions) {-else-} do
        localToAbstract (LetDefs ExprLetDef ds) $ \ds' -> do
          e <- toAbstractCtx TopCtx e
          let info = ExprRange (getRange e0)
          return $ A.mkLet info ds' e
      C.Let _ _ Nothing -> typeError $ NotAValidLetExpression MissingBody

  -- Record construction
      C.Rec kwr r fs -> do
        fs' <- toAbstractCtx TopCtx fs
        let ds'  = [ d | Right (_, Just d) <- fs' ]
            fs'' = map (mapRight fst) fs'
            i    = ExprRange r
        return $ A.mkLet i ds' (A.Rec kwr i fs'')

      C.RecWhere kwr r [] -> pure $ A.Rec kwr (ExprRange r) []
      C.RecWhere kwr r (d0:ds0) -> localToAbstract (LetDefs RecordWhereLetDef (d0 :| ds0)) $ \ds -> do
        nms <- recordWhereNames ds
        reportSDoc "scope.record.where" 30 $ vcat
          [ "decls:"
          , nest 2 (vcat (map prettyA ds))
          , "names:" <+> prettyA nms
          ]
        return $ A.RecWhere kwr (ExprRange r) ds nms

      C.RecUpdateWhere kwr r e [] -> toAbstract e
      C.RecUpdateWhere kwr r e (d0:ds0) -> do
        e <- toAbstract e
        localToAbstract (LetDefs RecordWhereLetDef (d0 :| ds0)) $ \ds -> do
          nms <- recordWhereNames ds
          return $ A.RecUpdateWhere kwr (ExprRange r) e ds nms

  -- Record update
      C.RecUpdate kwr r e fs -> do
        A.RecUpdate kwr (ExprRange r) <$> toAbstract e <*> toAbstractCtx TopCtx fs

  -- Parenthesis
      C.Paren _ e -> toAbstractCtx TopCtx e

  -- Idiom brackets
      C.IdiomBrackets r es ->
        toAbstractCtx TopCtx =<< parseIdiomBracketsSeq r es

  -- Do notation
      C.DoBlock _kwr ss ->
        toAbstractCtx TopCtx =<< desugarDoNotation ss

  -- Post-fix projections
      C.Dot _ _ -> typeError InvalidDottedExpression

  -- Pattern things
      C.As _ _ _ -> notAnExpression e
      C.Absurd _ -> notAnExpression e

  -- Impossible things
      C.Equal{} -> syntaxError "unexpected '='" -- triggered by 'f = (x = e)'
      C.Ellipsis _ -> syntaxError "unexpected '...'"  -- triggered by 'f = ...'
      C.DoubleDot _ _ -> syntaxError "unexpected '..'" -- triggered by 'f = ..x'

  -- Quoting
      C.Quote r -> return $ A.Quote (ExprRange r)
      C.QuoteTerm r -> return $ A.QuoteTerm (ExprRange r)
      C.Unquote r -> return $ A.Unquote (ExprRange r)

      C.Tactic r e -> syntaxError "'tactic' can only appear in attributes"

  -- DontCare
      C.DontCare e -> A.DontCare <$> toAbstract e

  -- forall-generalize
      C.Generalized e -> do
        (s, e) <- collectGeneralizables $ toAbstract e
        pure $ A.generalized s e

-- | The bindings collected while checking a @record where@ expression.
--
-- To each field name is associated a nonempty list of expressions
-- (always 'A.Def' or 'A.Var') pointing to the relevant let-declaration,
-- together with a range representing the entire declaration.
newtype PendingBinds = PBs { getPBs :: Map C.Name (List1 (A.Expr, Range)) }

instance Semigroup PendingBinds where
  PBs x <> PBs y = PBs (Map.unionWith (<>) x y)

instance Monoid PendingBinds where
  mempty = PBs mempty

-- | State accumulated while checking a @record where@ expression.
data RecWhereState = RecWhereState
  { recWhereBinds :: PendingBinds
    -- ^ The actual bindings.
  , recWhereMods :: Map ModuleName PendingBinds
    -- ^ A list from (locally-bound) module names to bindings associated
    -- with that module; see #7838.
  }

-- | Chooses the appropriate field assignments for a @record where@
-- expression given a list of @let@ declarations. Handles both local
-- declarations and copying from a module (possibly a module
-- application).
recordWhereNames :: [A.LetBinding] -> ScopeM Assigns
recordWhereNames = finish <=< foldM decl st0 where
  st0 = RecWhereState mempty mempty

  -- Turn the accumulated state into a list of assignments, potentially
  -- choosing a binding if there are multiple for the same field; if
  -- this is the case, also raise a warning.
  finish :: RecWhereState -> ScopeM Assigns
  finish (RecWhereState (PBs pending) _) = do
    let
      go :: Assigns
         -> Map C.Name (List1 Range)
         -> [(C.Name, List1 (A.Expr, Range))]
         -> (Assigns, Map C.Name (List1 Range))
      go !fs !ws ((con, (exp, rs) :| exps):rest) =
        case exps of
          []            -> go fs' ws rest
          ((_, r):exps) -> go fs' (Map.insert con (r :| map snd exps) ws) rest
        where fs' = FieldAssignment con exp:fs

      go fs ws [] = (fs, ws)

      (out, warns) = go mempty mempty (Map.toList pending)
    List1.unlessNull (Map.toList warns) \ls -> warning . RecordFieldWarning . W.DuplicateFields $ ls
    pure out

  pb :: C.Name -> A.Expr -> Range -> PendingBinds
  pb n e r = PBs $ Map.singleton n ((e, r) :| [])

  -- Construct a single PendingBind coming from an import directive. We
  -- take the name from the ScopeCopyInfo if it is present (i.e. if the
  -- import directive is associated with a local module-macro),
  -- otherwise we trust that the scope checker did the right thing...
  def :: Maybe ScopeCopyInfo -> A.QName -> ScopeM PendingBinds
  def ren nm = do
    let
      new = case ren of
        Just ren -> maybe nm List1.head $ Map.lookup nm (renNames ren)
        Nothing  -> nm

    -- N.B.: since this is somewhere we might invent a reference to an
    -- internal name that does not go through resolveName', we have to
    -- explicitly mark the name we used as alive.
    pb (nameConcrete (qnameName nm)) (A.Def new) (getRange nm)
      <$ markLiveName new

  fromRenaming :: Maybe ScopeCopyInfo -> [A.Renaming] -> ScopeM PendingBinds
  fromRenaming ren fs | (rens, _) <- partitionImportedNames (map renTo fs) = foldMap (def ren) rens

  fromImport :: Maybe ScopeCopyInfo -> A.ImportDirective -> ScopeM PendingBinds
  fromImport inv ImportDirective{ using = using, impRenaming = renaming } =
    case using of
      UseEverything
        | null renaming -> pure mempty -- TODO: raise a warning?
        | otherwise     -> fromRenaming inv renaming
      Using using | (names, _) <- partitionImportedNames using ->
        fromRenaming inv renaming <> foldMap (def inv) names

  ins :: PendingBinds -> RecWhereState -> RecWhereState
  ins pb (RecWhereState pb' m) = let pb'' = pb <> pb' in pb'' `seq` RecWhereState pb'' m

  applyHiding :: A.ImportDirective -> PendingBinds -> PendingBinds
  applyHiding ImportDirective{ hiding = hiding } (PBs pb) =
    let
      (names, _) = partitionImportedNames hiding
      nset = Set.fromList $ map (nameConcrete . qnameName) names
    in PBs $ Map.filterKeys (\k -> k `Set.notMember` nset) pb

  var :: A.Name -> Range -> RecWhereState -> RecWhereState
  var x r = ins (pb (nameConcrete x) (A.Var x) r)

  decl :: RecWhereState -> A.LetBinding -> ScopeM RecWhereState
  decl st0 r@(A.LetBind _ _ bn _ _) = pure $! var (unBind bn) (getRange r) st0
  decl st0 r@(A.LetAxiom _ _ bn _)  = pure $! var (unBind bn) (getRange r) st0
  decl st0 (A.LetPatBind _ _ pat _) = pure $! Set.foldr (\x -> var x (getRange x)) st0 $ allBoundNames pat

  decl st0 (A.LetApply mi _ modn ma ren idr) = do
    mod_pbs  <- fromImport (Just ren) idr

    reportSDoc "scope.record.where" 30 $ vcat
      [ "module macro in `record where`:"
      , "  idr:" <+> pure (pretty idr)
      , "  pbs:" <+> prettyTCM (getPBs mod_pbs)
      ]

    -- If the module is immediately opened, then we do not keep around
    -- the pending bindings. This is to prevent introducing fake
    -- duplicate bindings if this module macro is opened again, and the
    -- opens have some overlap.
    case minfoOpenShort mi of
      Just DoOpen -> pure $! ins mod_pbs st0
      _ -> pure st0{ recWhereMods = Map.insert modn mod_pbs (recWhereMods st0) }

  -- If we're opening a module macro which was created in the scope of
  -- this 'record where' expression, then it might have pending bindings
  -- from not being opened yet.
  -- Those need to be added to the resulting expression, but any which
  -- are mentioned in a new hiding directive should be dropped, i.e.
  --
  --    module A = X using (field)
  --    open A hiding (field)
  --
  -- should not add a binding for field.
  decl st0@RecWhereState{recWhereMods = mods} (A.LetOpen _ mod idr) = do
    -- If the module is not coming from this 'record where' expression
    -- then we can just give it the empty list of bindings.
    let mod_pbs = applyHiding idr (fromMaybe mempty (Map.lookup mod mods))
    this_pbs <- fromImport Nothing idr

    reportSDoc "scope.record.where" 30 $ vcat
      [ "opening module macro in `record where` with import directive:"
      , "     idr:" <+> pure (pretty idr)
      , " mod_pbs:" <+> prettyTCM (getPBs (applyHiding idr mod_pbs))
      , "this_pbs:" <+> prettyTCM (getPBs this_pbs)
      ]

    pure $! ins this_pbs $! ins mod_pbs st0

instance ToAbstract C.ModuleAssignment where
  type AbsOfCon C.ModuleAssignment = (A.ModuleName, Maybe A.LetBinding)
  toAbstract (C.ModuleAssignment m es i)
    | null es && isDefaultImportDir i = (, Nothing) <$> toAbstract (OldModuleName m)
    | otherwise = do
        x <- C.NoName (getRange m) <$> fresh
        r <- checkModuleMacro LetApply LetOpenModule
               (getRange (m, es, i)) PublicAccess defaultErased x
               (C.SectionApp (getRange (m , es)) [] m es)
               DontOpen i
        case r of
          LetApply _ _ m' _ _ _ -> return (m', Just r)
          _ -> __IMPOSSIBLE__

instance ToAbstract c => ToAbstract (FieldAssignment' c) where
  type AbsOfCon (FieldAssignment' c) = FieldAssignment' (AbsOfCon c)

  toAbstract = traverse toAbstract

instance ToAbstract (C.Binder' (NewName C.BoundName)) where
  type AbsOfCon (C.Binder' (NewName C.BoundName)) = A.Binder

  toAbstract (C.Binder p o n) = do
    let name = C.boundName $ newName n

    -- If we do have a pattern then the variable needs to be inserted
    -- so we do need a proper internal name for it.
    --
    -- Amy, 2024-10-18: If we generated a name, then mark the binder
    -- name as being inserted.
    (n, o) <- if not (isNoName name && isJust p) then pure (n, o) else do
      n' <- freshConcreteName (getRange $ newName n) 0 patternInTeleName
      pure (fmap (\ n -> n { C.boundName = n' }) n, InsertedBinderName)

    n <- toAbstract n
    -- Expand puns if optHiddenArgumentPuns is True.
    p <- traverse expandPunsOpt p
    -- Actually parsing the pattern, checking it is linear,
    -- and bind its variables
    p <- traverse parsePattern p
    p <- toAbstract p
    checkPatternLinearity p $ \ys ->
      typeError $ RepeatedVariablesInPattern ys
    bindVarsToBind
    p <- toAbstract p
    pure $ A.Binder p o n

instance ToAbstract C.LamBinding where
  type AbsOfCon C.LamBinding = Maybe A.LamBinding

  toAbstract (C.DomainFree x)  = do
    tac <- scopeCheckTactic x
    Just . A.DomainFree tac <$> toAbstract (updateNamedArg (fmap $ NewName LambdaBound) x)
  toAbstract (C.DomainFull tb) = fmap A.DomainFull <$> toAbstract tb

-- | Scope check tactic attribute, make sure they are only used in hidden arguments.
scopeCheckTactic :: NamedArg C.Binder -> ScopeM A.TacticAttribute
scopeCheckTactic x = do
  let ctac = bnameTactic $ C.binderName $ namedArg x
  let r = getRange ctac
  setCurrentRange r $ do
    tac <- traverse toAbstract ctac
    if null tac || hidden x then return tac else empty <$ warning UselessTactic

makeDomainFull :: C.LamBinding -> C.TypedBinding
makeDomainFull (C.DomainFull b) = b
makeDomainFull (C.DomainFree x) = C.TBind r (singleton x) $ C.Underscore r Nothing
  where r = getRange x

instance ToAbstract C.TypedBinding where
  type AbsOfCon C.TypedBinding = Maybe A.TypedBinding

  toAbstract (C.TBind r xs t) = do
    t' <- toAbstractCtx TopCtx t
    -- Invariant: all tactics are the same
    -- (distributed in the parser, TODO: don't)
    let tacArg = List1.find (not . null . bnameTactic . C.binderName . namedArg) xs
    tac <- maybe (pure empty) scopeCheckTactic tacArg

    let fin = all (bnameIsFinite . C.binderName . namedArg) xs
    xs' <- toAbstract $ fmap (updateNamedArg (fmap $ NewName LambdaBound)) xs

    return $ Just $ A.TBind r (TypedBindingInfo tac fin) xs' t'
  toAbstract (C.TLet r ds) = A.mkTLet r <$> toAbstract (LetDefs ExprLetDef ds)

-- | Scope check a module (top level function).
--
scopeCheckNiceModule
  :: Range
  -> Access
  -> Erased
  -> C.Name
  -> C.Telescope
  -> ScopeM [A.Declaration]
  -> ScopeM A.Declaration
       -- ^ The returned declaration is an 'A.Section'.
scopeCheckNiceModule r p e name tel checkDs = do
    -- Andreas, 2025-03-29: clear @envCheckingWhere@
    -- We are no longer directly in a @where@ block if we enter a module.
    localTC (\ env -> env{ envCheckingWhere = C.NoWhere_ }) $
      checkWrappedModules p (splitModuleTelescope tel)
  where
    -- Andreas, 2013-12-10:
    -- If the module telescope contains open statements
    -- or module macros (Issue 1299),
    -- add an extra anonymous module around the current one.
    -- Otherwise, the open statements would create
    -- identifiers in the parent scope of the current module.
    -- But open statements in the module telescope should
    -- only affect the current module!
    -- Ulf, 2024-11-21 (#7440): We need the wrapper module to have to correct parameters, otherwise
    -- open public of a module created in the telescope will behave incorrectly when applying the
    -- outer module.
    splitModuleTelescope :: C.Telescope -> [C.Telescope]
    splitModuleTelescope [] = [[]]
    splitModuleTelescope (b : tel) =
      case b of
        C.TLet _ ds | any needsWrapper ds -> [] : addBind b (splitModuleTelescope tel)
        _ -> addBind b $ splitModuleTelescope tel
      where
        addBind b (tel : ms) = (b : tel) : ms
        addBind _ [] = __IMPOSSIBLE__

        needsWrapper C.ModuleMacro{}    = True
        needsWrapper C.Open{}           = True
        needsWrapper C.Import{}         = True -- not __IMPOSSIBLE__, see Issue #1718
          -- However, it does not matter what we return here, as this will
          -- become an error later: "Not a valid let-declaration".
          -- (Andreas, 2015-11-17)
        needsWrapper (C.Mutual   _ ds)  = any needsWrapper ds
        needsWrapper (C.Abstract _ ds)  = any needsWrapper ds
        needsWrapper (C.Private _ _ ds) = any needsWrapper ds
        needsWrapper _                  = False

    checkWrappedModules :: Access -> [C.Telescope] -> ScopeM A.Declaration
    checkWrappedModules _ []           = __IMPOSSIBLE__
    checkWrappedModules p [tel]        = scopeCheckNiceModule_ r p name tel checkDs
    checkWrappedModules p (tel : tels) =
      scopeCheckNiceModule_ r p noName_ tel $ singleton <$>
        checkWrappedModules PublicAccess tels -- Inner modules are PublicAccess (see #4350)

    -- The actual workhorse:
    scopeCheckNiceModule_ :: Range -> Access -> C.Name -> C.Telescope -> ScopeM [A.Declaration] -> ScopeM A.Declaration
    scopeCheckNiceModule_ r p name tel checkDs = do

      -- Check whether we are dealing with an anonymous module.
      -- This corresponds to a Coq/LEGO section.
      (name, p', open) <- do
        if isNoName name then do
          (i :: NameId) <- fresh
          return (C.NoName (getRange name) i, privateAccessInserted, True)
         else return (name, p, False)

      -- Check and bind the module, using the supplied check for its contents.
      aname <- toAbstract (NewModuleName name)
      d <- snd <$> do
        scopeCheckModule r e (C.QName name) aname tel checkDs
      bindModule p' name aname

      -- If the module was anonymous open it public
      -- unless it's private, in which case we just open it (#2099)
      when open $
       void $ -- We can discard the returned default A.ImportDirective.
        openModule TopOpenModule (Just aname) (C.QName name) $
          defaultImportDir { publicOpen = boolToMaybe (p == PublicAccess) empty }
      return d

-- | We for now disallow let-bindings in @data@ and @record@ telescopes.
--   This due "nested datatypes"; there is no easy interpretation of
--   @
--      data D (A : Set) (open M A) (b : B) : Set where
--        c : D (A × A) b → D A b
--   @
--   where @B@ is brought in scope by @open M A@.

class EnsureNoLetStms a where
  ensureNoLetStms :: a -> ScopeM ()

  default ensureNoLetStms :: (Foldable t, EnsureNoLetStms b, t b ~ a) => a -> ScopeM ()
  ensureNoLetStms = traverse_ ensureNoLetStms

instance EnsureNoLetStms C.Binder where
  ensureNoLetStms arg@(C.Binder p _ n) =
    when (isJust p) $ typeError $ IllegalPatternInTelescope arg

instance EnsureNoLetStms C.TypedBinding where
  ensureNoLetStms = \case
    tb@C.TLet{}    -> typeError $ IllegalLetInTelescope tb
    C.TBind _ xs _ -> traverse_ (ensureNoLetStms . namedArg) xs

instance EnsureNoLetStms a => EnsureNoLetStms (LamBinding' a) where
  ensureNoLetStms = \case
    -- GA: DO NOT use traverse here: `LamBinding'` only uses its parameter in
    --     the DomainFull constructor so we would miss out on some potentially
    --     illegal lets! Cf. #4402
    C.DomainFree a -> ensureNoLetStms a
    C.DomainFull a -> ensureNoLetStms a

instance EnsureNoLetStms a => EnsureNoLetStms (Named_ a) where
instance EnsureNoLetStms a => EnsureNoLetStms (NamedArg a) where
instance EnsureNoLetStms a => EnsureNoLetStms [a] where


-- | Returns the scope inside the checked module.
scopeCheckModule
  :: Range                   -- ^ The range of the module.
  -> Erased                  -- ^ Is the module erased?
  -> C.QName                 -- ^ The concrete name of the module.
  -> A.ModuleName            -- ^ The abstract name of the module.
  -> C.Telescope             -- ^ The module telescope.
  -> ScopeM [A.Declaration]  -- ^ The code for checking the module contents.
  -> ScopeM (ScopeInfo, A.Declaration)
       -- ^ The returned declaration is an 'A.Section'.
scopeCheckModule r e x qm tel checkDs = do
  printScope "module" 40 $ "checking module " ++ prettyShow x
  -- Andreas, 2013-12-10: Telescope does not live in the new module
  -- but its parent, so check it before entering the new module.
  -- This is important for Nicolas Pouillard's open parametrized modules
  -- statements inside telescopes.
  res <- withLocalVars $ do
    tel <- toAbstract (GenTel tel)
    withCurrentModule qm $ do
      -- pushScope m
      -- qm <- getCurrentModule
      printScope "module" 40 $ "inside module " ++ prettyShow x
      ds    <- checkDs
      scope <- getScope
      return (scope, A.Section r e (qm `withRangesOfQ` x) tel ds)

  -- Binding is done by the caller
  printScope "module" 40 $ "after module " ++ prettyShow x
  return res

-- | Temporary data type to scope check a file.
data TopLevel a = TopLevel
  { topLevelSourceFile     :: SourceFile
    -- ^ The file from which we loaded this module.
  , topLevelExpectedName   :: TopLevelModuleName
    -- ^ The expected module name
    --   (coming from the import statement that triggered scope checking this file).
  , topLevelTheThing       :: a
    -- ^ The file content.
  }

data TopLevelInfo = TopLevelInfo
        { topLevelDecls :: [A.Declaration]
        , topLevelScope :: ScopeInfo  -- ^ as seen from inside the module
        }

-- | The top-level module name.

topLevelModuleName :: TopLevelInfo -> A.ModuleName
topLevelModuleName = (^. scopeCurrent) . topLevelScope

-- | Top-level declarations are always
--   @
--     (import|open)*         -- a bunch of possibly opened imports
--     module ThisModule ...  -- the top-level module of this file
--   @
instance ToAbstract (TopLevel [C.Declaration]) where
    type AbsOfCon (TopLevel [C.Declaration]) = TopLevelInfo

    toAbstract (TopLevel src expectedMName ds) =
      -- A file is a bunch of preliminary decls (imports etc.)
      -- plus a single module decl.
      case C.spanAllowedBeforeModule ds of

        -- If there are declarations after the top-level module
        -- we have to report a parse error here.
        (_, C.Module{} : d : _) -> setCurrentRange d $ typeError DeclarationsAfterTopLevelModule

        -- Otherwise, proceed.
        (outsideDecls, [ C.Module r e m0 tel insideDecls ]) -> do
          -- If the module name is _ compute the name from the file path
          (m, top) <- if isNoName m0
                then do
                  -- Andreas, 2017-07-28, issue #1077
                  -- Check if the insideDecls end in a single module which has the same
                  -- name as the file.  In this case, it is highly likely that the user
                  -- put some non-allowed declarations before the top-level module in error.
                  -- Andreas, 2017-10-19, issue #2808
                  -- Widen this check to:
                  -- If the first module of the insideDecls has the same name as the file,
                  -- report an error.
                  case flip span insideDecls $ \case { C.Module{} -> False; _ -> True } of
                    (ds0, (C.Module _ _ m1 _ _ : _))
                       | rawTopLevelModuleNameForQName m1 ==
                         rawTopLevelModuleName expectedMName
                         -- If the anonymous module comes from the user,
                         -- the range cannot be the beginningOfFile.
                         -- That is the range if the parser inserted the anon. module.
                       , r == beginningOfFile (getRange insideDecls) -> do

                         -- GA #4888: We know we are in a bad place. But we still scopecheck
                         -- the initial segment on the off chance we generate a better error
                         -- message.
                         void importPrimitives
                         void $ toAbstract (Declarations outsideDecls)
                         void $ toAbstract (Declarations ds0)
                         -- Fail with a crude error otherwise
                         setCurrentRange ds0 $ typeError IllegalDeclarationBeforeTopLevelModule

                    -- Otherwise, reconstruct the top-level module name
                    _ -> do
                      file <- srcFilePath src
                      let m = C.QName $ setRange (getRange m0) $
                              C.simpleName $ stringToRawName $
                              rootNameModule file
                      top <- S.topLevelModuleName
                               (rawTopLevelModuleNameForQName m)
                      return (m, top)
                -- Andreas, 2017-05-17, issue #2574, keep name as jump target!
                -- Andreas, 2016-07-12, ALTERNATIVE:
                -- -- We assign an anonymous file module the name expected from
                -- -- its import.  For flat file structures, this is the same.
                -- -- For hierarchical file structures, this reverses the behavior:
                -- -- Loading the file by itself will fail, but it can be imported.
                -- -- The previous behavior is: it can be loaded by itself, but not
                -- -- be imported
                -- then return $ C.fromTopLevelModuleName expectedMName
                else do
                -- Andreas, 2014-03-28  Issue 1078
                -- We need to check the module name against the file name here.
                -- Otherwise one could sneak in a lie and confuse the scope
                -- checker.
                  top <- S.topLevelModuleName
                           (rawTopLevelModuleNameForQName m0)
                  checkModuleName top src (Just expectedMName)
                  return (m0, top)
          setTopLevelModule top
          am <- toAbstract (NewModuleQName m)
          primitiveImport <- importPrimitives
          -- Scope check the declarations outside
          outsideDecls <- toAbstract (Declarations outsideDecls)
          (insideScope, insideDecl) <- scopeCheckModule r e m am tel $
             toAbstract (Declarations insideDecls)
          -- Andreas, 2020-05-13, issue #1804, #4647
          -- Do not eagerly remove private definitions, only when serializing
          -- let scope = over scopeModules (fmap $ restrictLocalPrivate am) insideScope
          let scope = insideScope
          setScope scope

          -- While scope-checking the top-level module we might have
          -- encountered several (possibly nested) opaque blocks. We
          -- must now ensure that these have transitively-closed
          -- unfolding sets.
          saturateOpaqueBlocks

          return $ TopLevelInfo (primitiveImport ++ outsideDecls ++ [ insideDecl ]) scope

        -- We already inserted the missing top-level module, see
        -- 'Agda.Syntax.Parser.Parser.figureOutTopLevelModule',
        -- thus, this case is impossible:
        _ -> __IMPOSSIBLE__

-- | Declaration @open import Agda.Primitive using (Set)@ when 'optImportSorts'.
--   @Prop@ is added when 'optProp', and @SSet@ when 'optTwoLevel'.
importPrimitives :: ScopeM [A.Declaration]
importPrimitives = do
  ifNotM (optImportSorts <$> pragmaOptions) (return []) {- else -} do
    prop     <- optProp     <$> pragmaOptions
    twoLevel <- optTwoLevel <$> pragmaOptions
    -- Add implicit `open import Agda.Primitive using (Prop; Set; SSet)`
    let agdaPrimitiveName   = Qual (C.simpleName "Agda") $ C.QName $ C.simpleName "Primitive"
        usingDirective      = map (ImportedName . C.simpleName) $ concat
          [ [ "Prop" | prop     ]
          , [ "Set"  | True     ]
          , [ "SSet" | twoLevel ]
          ]
        directives          = ImportDirective noRange (Using usingDirective) [] [] Nothing
        importAgdaPrimitive = [C.Import noRange agdaPrimitiveName Nothing C.DoOpen directives]
    toAbstract (Declarations importAgdaPrimitive)

-- | runs Syntax.Concrete.Definitions.niceDeclarations on main module
niceDecls :: DoWarn -> [C.Declaration] -> ([NiceDeclaration] -> ScopeM a) -> ScopeM a
niceDecls warn ds ret = setCurrentRange ds $ computeFixitiesAndPolarities warn ds $ do

  -- Some pragmas are not allowed in safe mode unless we are in a builtin module.
  -- So we need to tell the nicifier whether it should yell about unsafe pragmas.
  isSafe <- Lens.getSafeMode <$> pragmaOptions
  safeButNotBuiltin <- and2M
    -- NB: BlockArguments allow bullet-point style argument lists using @do@, hehe!
    do pure isSafe
    do not <$> do isBuiltinModuleWithSafePostulates . fromMaybe __IMPOSSIBLE__ =<< asksTC envCurrentPath

  -- We need to pass the fixities to the nicifier for clause grouping.
  fixs <- useScope scopeFixities
  niceEnv <- NiceEnv safeButNotBuiltin <$> asksTC envCheckingWhere

  -- Run nicifier.
  let (result, warns) = runNice niceEnv $ niceDeclarations fixs ds

  -- Respect the @DoWarn@ directive. For this to be sound, we need to know for
  -- sure that each @Declaration@ is checked at least once with @DoWarn@.
  unless (warn == NoWarn || null warns) $ do
    -- If there are some warnings and the --safe flag is set,
    -- we check that none of the NiceWarnings are fatal
    when isSafe $ do
      let (errs, ws) = List.partition unsafeDeclarationWarning warns
      -- If some of them are, we fail
      List1.unlessNull errs \ errs -> do
        List1.unlessNull ws \ ws -> warnings $ fmap NicifierIssue ws
        tcerrs <- mapM (warning_ . NicifierIssue) errs
        setCurrentRange errs $ typeError $ NonFatalErrors $ Set1.fromList tcerrs
    -- Otherwise we simply record the warnings
    mapM_ (\ w -> warning' (dwLocation w) $ NicifierIssue w) warns
  case result of
    Left (DeclarationException loc e) -> do
      reportSLn "error" 2 $ "Error raised at " ++ prettyShow loc
      setCurrentRange e $ typeError $ NicifierError e
    Right ds -> ret ds

-- | Wrapper to avoid instance conflict with generic list instance.
newtype Declarations = Declarations [C.Declaration]

instance ToAbstract Declarations where
  type AbsOfCon Declarations = [A.Declaration]

  toAbstract (Declarations ds) = niceDecls DoWarn ds toAbstract

-- | Where did these 'LetDef's come from?
data LetDefOrigin
  = ExprLetDef
  -- ^ A let expression or do statement
  | RecordWhereLetDef
  -- ^ A @record where@ expression
  | RecordLetDef
  -- ^ Definitions in a record declaration, before the last field
  deriving (Eq, Show)

data LetDefs = LetDefs LetDefOrigin (List1 C.Declaration)
data LetDef = LetDef LetDefOrigin NiceDeclaration

instance ToAbstract LetDefs where
  type AbsOfCon LetDefs = [A.LetBinding]

  toAbstract :: LetDefs -> ScopeM (AbsOfCon LetDefs)
  toAbstract (LetDefs wh ds) =
    List1.concat <$> niceDecls DoWarn (List1.toList ds) (toAbstract . map (LetDef wh))

-- | Raise appropriate (error-)warnings for if a declaration with
-- illegal access, macro flag, or abstractness appear in a let
-- expression.
checkLetDefInfo :: LetDefOrigin -> Access -> IsMacro -> IsAbstract -> ScopeM ()
checkLetDefInfo wh access macro abstract = do
  when (abstract == AbstractDef) $ warning AbstractInLetBindings

  when (macro == MacroDef) $ warning MacroInLetBindings

  case access of
    -- Marking a let declaration as private should only raise a warning
    -- in explicit, user-written expressions.
    --
    -- It should not raise a warning when scope-checking the type of a
    -- record constructor (it has an effect there), or when elaborating
    -- the lets generated by a 'record where' expression.
    PrivateAccess rng _
      | wh == ExprLetDef -> scopeWarning (UselessPrivate rng)
    _ -> pure ()

instance ToAbstract LetDef where
  type AbsOfCon LetDef = List1 A.LetBinding
  toAbstract :: LetDef -> ScopeM (AbsOfCon LetDef)
  toAbstract (LetDef wh d) = setCurrentRange d case d of
    NiceMutual _ _ _ _ d@[C.FunSig _ access _ instanc macro info _ _ x t, C.FunDef _ _ abstract _ _ _ _ (cl :| [])] -> do
      checkLetDefInfo wh access macro abstract

      t <- toAbstract t
      -- We bind the name here to make sure it's in scope for the LHS (#917).
      -- It's unbound for the RHS in letToAbstract.
      fx <- getConcreteFixity x

      x <- A.unBind <$> toAbstract (NewName LetBound $ mkBoundName x fx)
      (x', e) <- letToAbstract cl

      -- There are sometimes two instances of the let-bound variable,
      -- one declaration and one definition (see issue #1618).
      -- Andreas, 2015-08-27 keeping both the range of x and x' solves Issue 1618.
      -- The situation is
      -- @
      --    let y : t
      --        y = e
      -- @
      -- and we need to store the ranges of both occurences of y so that
      -- the highlighter does the right thing.
      let x2 = setRange (fuseRange x x') x

      -- If InstanceDef set info to Instance
      let info' = case instanc of
            InstanceDef _  -> makeInstance info
            NotInstanceDef -> info

      return $
        A.LetBind (LetRange $ getRange d) info' (A.mkBindName x2) t e :|
        []

    -- Function signature without a body
    C.Axiom _ acc abs instanc info x t -> do
      checkLetDefInfo wh acc NotMacroDef abs

      t <- toAbstract t
      fx <- getConcreteFixity x
      x  <- toAbstract (NewName LetBound $ mkBoundName x fx)

      let
        info' = case instanc of
          InstanceDef _  -> makeInstance info
          NotInstanceDef -> info

      pure $ A.LetAxiom (LetRange $ getRange d) info' x t :| []

    -- irrefutable let binding, like  .(x , y) = rhs
    NiceFunClause r PublicAccess ConcreteDef tc cc catchall d@(C.FunClause ai lhs@(C.LHS p0 [] []) rhs0 whcl ca) -> do
      noWhereInLetBinding whcl
      rhs <- letBindingMustHaveRHS rhs0
      -- Expand puns if optHiddenArgumentPuns is True.
      p0   <- expandPunsOpt p0
      mp   <- setCurrentRange p0 $
                (Right <$> parsePattern p0)
                  `catchError`
                (return . Left)
      case mp of
        Right p -> do
          rhs <- toAbstract rhs
          setCurrentRange p0 $ do
            p   <- toAbstract p
            checkValidLetPattern p
            checkPatternLinearity p $ \ys ->
              typeError $ RepeatedVariablesInPattern ys
            bindVarsToBind
            p   <- toAbstract p
            return $ singleton $ A.LetPatBind (LetRange r) ai p rhs
        -- It's not a record pattern, so it should be a prefix left-hand side
        Left err ->
          case definedName p0 of
            Nothing -> throwError err
            Just x  -> toAbstract $ LetDef wh $ NiceMutual empty tc cc YesPositivityCheck
              [ C.FunSig r PublicAccess ConcreteDef NotInstanceDef NotMacroDef
                  info tc cc x (C.Underscore (getRange x) Nothing)
              , C.FunDef r __IMPOSSIBLE__ ConcreteDef NotInstanceDef __IMPOSSIBLE__ __IMPOSSIBLE__ __IMPOSSIBLE__
                $ singleton $ C.Clause x (ca <> catchall) ai lhs (C.RHS rhs) NoWhere []
              ]
              where info = setOrigin Inserted ai
          where
            definedName (C.IdentP _ (C.QName x)) = Just x
            definedName C.IdentP{}             = Nothing
            definedName (C.RawAppP _ (List2 p _ _)) = definedName p
            definedName (C.ParenP _ p)         = definedName p
            definedName C.WildP{}              = Nothing   -- for instance let _ + x = x in ... (not allowed)
            definedName C.AbsurdP{}            = Nothing
            definedName C.AsP{}                = Nothing
            definedName C.DotP{}               = Nothing
            definedName C.EqualP{}             = Nothing
            definedName C.LitP{}               = Nothing
            definedName C.RecP{}               = Nothing
            definedName C.QuoteP{}             = Nothing
            definedName C.HiddenP{}            = Nothing -- Not impossible, see issue #2291
            definedName C.InstanceP{}          = Nothing
            definedName C.WithP{}              = Nothing
            definedName C.AppP{}               = Nothing -- Not impossible, see issue #4586
            definedName C.OpAppP{}             = __IMPOSSIBLE__
            definedName C.EllipsisP{}          = Nothing -- Not impossible, see issue #3937

    -- You can't open public in a let
    NiceOpen r x dir -> do
      dir  <- uselessPublic UselessPublicLet dir
      m    <- toAbstract (OldModuleName x)
      adir <- openModule_ LetOpenModule x dir
      let minfo = ModuleInfo
            { minfoRange  = r
            , minfoAsName = Nothing
            , minfoAsTo   = renamingRange dir
            , minfoOpenShort = Nothing
            , minfoDirective = Just dir
            }
      return $ singleton $ A.LetOpen minfo m adir

    NiceModuleMacro r p erased x modapp open dir -> do
      dir <- uselessPublic UselessPublicLet dir
      -- Andreas, 2014-10-09, Issue 1299: module macros in lets need
      -- to be private
      singleton <$> checkModuleMacro LetApply LetOpenModule r
                      privateAccessInserted erased x modapp open dir

    _ -> notAValidLetBinding Nothing

    where
      letToAbstract (C.Clause top _catchall _ai (C.LHS p [] []) rhs0 wh []) = do
        noWhereInLetBinding wh
        rhs <- letBindingMustHaveRHS rhs0
        (x, args) <- do
          res <- setCurrentRange p $ parseLHS NoDisplayLHS (C.QName top) p
          case res of
            C.LHSHead x args -> return (x, args)
            C.LHSProj{}      -> __IMPOSSIBLE__  -- notAValidLetBinding $ Just CopatternsNotAllowed
            C.LHSWith{}      -> __IMPOSSIBLE__  -- notAValidLetBinding $ Just WithPatternsNotAllowed
            C.LHSEllipsis{}  -> __IMPOSSIBLE__  -- notAValidLetBinding $ Just EllipsisNotAllowed

        e <- localToAbstract args $ \args -> do
          bindVarsToBind
          -- Make sure to unbind the function name in the RHS, since lets are non-recursive.
          rhs <- unbindVariable top $ toAbstract rhs
          foldM lambda rhs (reverse args)  -- just reverse because these are DomainFree
        return (x, e)

      letToAbstract _ = notAValidLetBinding Nothing

      -- These patterns all have a chance of being accepted in a lambda:
      allowedPat A.VarP{}      = True
      allowedPat A.ConP{}      = True
      allowedPat A.WildP{}     = True
      allowedPat (A.AsP _ _ x) = allowedPat x
      allowedPat (A.RecP _ _ as) = all (allowedPat . view exprFieldA) as
      allowedPat (A.PatternSynP _ _ as) = all (allowedPat . namedArg) as

      -- These have no chance:
      allowedPat A.AbsurdP{}     = False
      allowedPat A.ProjP{}       = False
      allowedPat A.DefP{}        = False
      allowedPat A.EqualP{}      = False
      allowedPat A.WithP{}       = False
      allowedPat A.DotP{}        = False
      allowedPat A.LitP{}        = False

      patternName (A.VarP bn)    = Just bn
      patternName (A.AsP _ bn _) = Just bn
      patternName _ = Nothing

      -- Named patterns not allowed in let definitions
      lambda :: A.Expr -> A.NamedArg (A.Pattern' C.Expr) -> TCM A.Expr
      lambda e ai@(Arg info (Named thing pat)) | allowedPat pat = do
        let
          i = ExprRange (fuseRange pat e)

        pat <- toAbstract pat

        bn <- case pat of
          A.VarP bn    -> pure bn
          A.AsP _ bn _ -> pure bn
          _ -> fmap mkBindName . freshAbstractName_ =<< freshConcreteName (getRange pat) 0 patternInTeleName

        -- Annoyingly, for the lambdas to be elaborated properly, we
        -- have to generate domainful binders. Domain-free binders can
        -- not be named (or have pattern matching!).
        --
        -- Moreover, we need to avoid generating named patterns that are
        -- like {B = B @ B}.

        let
          pat' = case pat of
            A.VarP{} -> Nothing
            pat -> Just pat
          binder = Arg info (Named thing (A.Binder pat' InsertedBinderName bn)) :| []

        pure $ A.Lam i (A.DomainFull (A.TBind (getRange ai) empty binder (A.Underscore empty))) e

      lambda _ _ = notAValidLetBinding Nothing

      noWhereInLetBinding :: C.WhereClause -> ScopeM ()
      noWhereInLetBinding = \case
        NoWhere -> return ()
        wh -> setCurrentRange wh $ notAValidLetBinding $ Just WhereClausesNotAllowed
      letBindingMustHaveRHS :: C.RHS -> ScopeM C.Expr
      letBindingMustHaveRHS = \case
        C.RHS e -> return e
        C.AbsurdRHS -> notAValidLetBinding $ Just MissingRHS

      -- Only record patterns allowed, but we do not exclude data constructors here.
      -- They will fail in the type checker.
      checkValidLetPattern :: A.Pattern' e -> ScopeM ()
      checkValidLetPattern a = unless (allowedPat a) do
        notAValidLetBinding $ Just NotAValidLetPattern

checkFieldArgInfo :: Bool -> ArgInfo -> ScopeM ArgInfo
checkFieldArgInfo warn =
    ensureContinuous msg >=>
    ensureMixedPolarity msg
  where
    msg = if warn then Just "of field" else Nothing

instance ToAbstract NiceDeclaration where
  type AbsOfCon NiceDeclaration = A.Declaration

  toAbstract d = annotateDecls $
    traceS "scope.decl.trace" 50
      [ "scope checking declaration"
      , "  " ++  prettyShow d
      ] $
    traceS "scope.decl.trace" 80  -- keep this debug message for testing issue #4016
      [ "scope checking declaration (raw)"
      , "  " ++  show d
      ] $
    traceCall (ScopeCheckDeclaration d) $
    -- Andreas, 2015-10-05, Issue 1677:
    -- We record in the environment whether we are scope checking an
    -- abstract definition.  This way, we can propagate this attribute
    -- the extended lambdas.
    applyWhenJust (niceHasAbstract d) (\ a -> localTC $ \ e -> e { envAbstractMode = aDefToMode a }) $
    case d of

  -- Axiom (actual postulate)
    C.Axiom r p a i rel x t -> do
      (y, decl) <- toAbstractNiceAxiom AxiomName d
      -- check that we do not postulate in --safe mode, unless it is a
      -- builtin module with safe postulates, or the axiom is generated
      -- from a lone signature
      whenM (andM [ Lens.getSafeMode <$> commandLineOptions
                  , not <$> (isBuiltinModuleWithSafePostulates . fromMaybe __IMPOSSIBLE__ =<< asksTC envCurrentPath)
                  , pure $ getOrigin rel /= Inserted
                  ])
            (warning $ SafeFlagPostulate y)
      -- check the postulate
      return $ singleton decl

    C.NiceGeneralize r p i tac x t -> do
      reportSLn "scope.decl" 30 $ "found nice generalize: " ++ prettyShow x
      tac <- traverse (toAbstractCtx TopCtx) tac
      t_ <- toAbstractCtx TopCtx t
      let (s, t) = unGeneralized t_
      reportSLn "scope.decl" 50 $ "generalizations: " ++ show (Set.toList s, t)
      f <- getConcreteFixity x
      y <- freshAbstractQName f x
      bindName p GeneralizeName x y
      let info = (mkDefInfo x f p ConcreteDef r) { defTactic = tac }
      return [A.Generalize s info i y t]

  -- Fields
    C.NiceField r p a i tac x (Arg ai t) -> do
      unless (p == PublicAccess) $ typeError PrivateRecordField
      ai  <- checkFieldArgInfo False ai  -- we already warned in recordConstructorType
      tac <- traverse (toAbstractCtx TopCtx) tac
      -- Interaction points for record fields have already been introduced
      -- when checking the type of the record constructor.
      -- To avoid introducing interaction points (IP) twice, we turn
      -- all question marks to underscores.  (See issue 1138.)
      let maskIP (C.QuestionMark r _) = C.Underscore r Nothing
          maskIP e                     = e
      t  <- toAbstractCtx TopCtx $ mapExpr maskIP t
      f  <- getConcreteFixity x
      y  <- freshAbstractQName f x
      -- Andreas, 2018-06-09 issue #2170
      -- We want dependent irrelevance without irrelevant projections,
      -- thus, do not disable irrelevant projections via the scope checker.
      -- irrProj <- optIrrelevantProjections <$> pragmaOptions
      -- unless (isIrrelevant t && not irrProj) $
      --   -- Andreas, 2010-09-24: irrelevant fields are not in scope
      --   -- this ensures that projections out of irrelevant fields cannot occur
      --   -- Ulf: unless you turn on --irrelevant-projections
      bindName p FldName x y
      let info = (mkDefInfoInstance x f p a i NotMacroDef r) { defTactic = tac }
      return [ A.Field info y (Arg ai t) ]

  -- Primitive function
    PrimitiveFunction r p a x t -> notAffectedByOpaque $ do
      t' <- traverse (toAbstractCtx TopCtx) t
      f  <- getConcreteFixity x
      y  <- freshAbstractQName f x
      bindName p PrimName x y
      unfoldFunction y
      let di = mkDefInfo x f p a r
      return [ A.Primitive di y t' ]

  -- Definitions (possibly mutual)
    NiceMutual kwr tc cc pc ds -> do
      reportSLn "scope.mutual" 40 ("starting checking mutual definitions: " ++ prettyShow ds)
      ds' <- toAbstract ds
      reportSLn "scope.mutual" 40 ("finishing checking mutual definitions")
      -- We only termination check blocks that do not have a measure.
      return [ A.Mutual (MutualInfo tc cc pc (fuseRange kwr ds)) ds' ]

    C.NiceRecSig r er p a _pc _uc x ls t -> do
      ensureNoLetStms ls
      withLocalVars $ do
        (ls', _) <- withCheckNoShadowing $
          -- Minor hack: record types don't have indices so we include t when
          -- computing generalised parameters, but in the type checker any named
          -- generalizable arguments in the sort should be bound variables.
          toAbstract (GenTelAndType (map makeDomainFull ls) t)
        t' <- toAbstract t
        f  <- getConcreteFixity x
        x' <- freshAbstractQName f x
        bindName' p RecName (GeneralizedVarsMetadata $ generalizeTelVars ls') x x'
        return [ A.RecSig (mkDefInfo x f p a r) er x' ls' t' ]

    C.NiceDataSig r er p a pc uc x ls t -> do
        reportSLn "scope.data.sig" 40 ("checking DataSig for " ++ prettyShow x)
        ensureNoLetStms ls
        withLocalVars $ do
          ls' <- withCheckNoShadowing $
            toAbstract $ GenTel $ map makeDomainFull ls
          t'  <- toAbstract $ C.Generalized t
          f  <- getConcreteFixity x
          x' <- freshAbstractQName f x
          mErr <- bindName'' p DataName (GeneralizedVarsMetadata $ generalizeTelVars ls') x x'
          whenJust mErr $ \case
            err@(ClashingDefinition cn an _) -> do
              resolveName (C.QName x) >>= \case
                -- #4435: if a data type signature causes a ClashingDefinition error, and if
                -- the data type name is bound to an Axiom, then the error may be caused by
                -- the illegal type signature. Convert the NiceDataSig into a NiceDataDef
                -- (which removes the type signature) and suggest it as a possible fix.
                DefinedName p ax NoSuffix | anameKind ax == AxiomName -> do
                  let suggestion = NiceDataDef r Inserted a pc uc x ls []
                  typeError $ ClashingDefinition cn an (Just suggestion)
                _ -> typeError err
            otherErr -> typeError otherErr
          return [ A.DataSig (mkDefInfo x f p a r) er x' ls' t' ]

  -- Type signatures
    C.FunSig r p a i m rel _ _ x t -> do
        let kind = if m == MacroDef then MacroName else FunName
        singleton . snd <$> toAbstractNiceAxiom kind (C.Axiom r p a i rel x t)

  -- Function definitions
    C.FunDef r ds a i _ _ x cs -> do
        printLocals 30 $ "checking def " ++ prettyShow x
        (x',cs) <- toAbstract (OldName x, cs)
        -- Andreas, 2017-12-04 the name must reside in the current module
        unlessM ((A.qnameModule x' ==) <$> getCurrentModule) $
          __IMPOSSIBLE__
        f <- getConcreteFixity x

        unfoldFunction x'
        di <- updateDefInfoOpacity (mkDefInfoInstance x f PublicAccess a i NotMacroDef r)
        return [ A.FunDef di x' cs ]

  -- Uncategorized function clauses
    C.NiceFunClause _ _ _ _ _ _ (C.FunClause _ lhs _ _ _) ->
      typeError $ MissingTypeSignature $ MissingFunctionSignature lhs
    C.NiceFunClause{} -> __IMPOSSIBLE__

  -- Data definitions
    C.NiceDataDef r o a _ uc x pars cons -> notAffectedByOpaque $ do
        reportSLn "scope.data.def" 40 ("checking " ++ show o ++ " DataDef for " ++ prettyShow x)
        (p, ax) <- resolveName (C.QName x) >>= \case
          DefinedName p ax NoSuffix -> do
            clashUnless x DataName ax  -- Andreas 2019-07-07, issue #3892
            livesInCurrentModule ax  -- Andreas, 2017-12-04, issue #2862
            clashIfModuleAlreadyDefinedInCurrentModule x ax
            return (p, ax)
          _ -> typeError $ MissingTypeSignature $ MissingDataSignature x
        ensureNoLetStms pars
        withLocalVars $ do
          gvars <- bindGeneralizablesIfInserted o ax
          -- Check for duplicate constructors
          do cs <- mapM conName cons
             List1.unlessNull (duplicates cs) $ \ dups -> do
               let bad = filter (`elem` dups) cs
               setCurrentRange bad $
                 typeError $ DuplicateConstructors dups

          pars <- catMaybes <$> toAbstract pars
          let x' = anameName ax
          -- Create the module for the qualified constructors
          checkForModuleClash x -- disallow shadowing previously defined modules
          let m = qnameToMName x'
          createModule (Just IsDataModule) m
          bindModule p x m  -- make it a proper module
          cons <- toAbstract (map (DataConstrDecl m a p) cons)
          printScope "data" 40 $ "Checked data " ++ prettyShow x
          f <- getConcreteFixity x
          return [ A.DataDef (mkDefInfo x f PublicAccess a r) x' uc (DataDefParams gvars pars) cons ]
      where
        conName (C.Axiom _ _ _ _ _ c _) = return c
        conName d = errorNotConstrDecl d

  -- Record definitions (mucho interesting)
    C.NiceRecDef r o a _ uc x directives pars fields -> notAffectedByOpaque $ do
      reportSLn "scope.rec.def" 40 ("checking " ++ show o ++ " RecDef for " ++ prettyShow x)
      -- #3008: Termination pragmas are ignored in records
      checkNoTerminationPragma InRecordDef fields
      RecordDirectives ind eta pat cm <- gatherRecordDirectives directives
      -- Andreas, 2020-04-19, issue #4560
      -- 'pattern' declaration is incompatible with 'coinductive' or 'eta-equality'.
      pat <- case pat of
        Just r
          | Just (Ranged _ CoInductive) <- ind -> Nothing <$ warn "coinductive"
          | Just (Ranged _ YesEta)      <- eta -> Nothing <$ warn "eta"
          | otherwise -> return pat
          where warn = setCurrentRange r . warning . UselessPatternDeclarationForRecord
        Nothing -> return pat

      (p, ax) <- resolveName (C.QName x) >>= \case
        DefinedName p ax NoSuffix -> do
          clashUnless x RecName ax  -- Andreas 2019-07-07, issue #3892
          livesInCurrentModule ax  -- Andreas, 2017-12-04, issue #2862
          clashIfModuleAlreadyDefinedInCurrentModule x ax
          return (p, ax)
        _ -> typeError $ MissingTypeSignature $ MissingRecordSignature x
      ensureNoLetStms pars
      withLocalVars $ do
        gvars <- bindGeneralizablesIfInserted o ax
        -- Check that the generated module doesn't clash with a previously
        -- defined module
        checkForModuleClash x
        pars   <- catMaybes <$> toAbstract pars
        let x' = anameName ax
        -- We scope check the fields a first time when putting together
        -- the type of the constructor.
        contel <- localToAbstract (RecordConstructorType fields) return
        m0     <- getCurrentModule
        let m = A.qualifyM m0 $ mnameFromList1 $ singleton $ List1.last $ qnameToList x'
        printScope "rec" 25 "before record"
        createModule (Just IsRecordModule) m
        -- We scope check the fields a second time, as actual fields.
        afields <- withCurrentModule m $ do
          afields <- toAbstract (Declarations fields)
          printScope "rec" 25 "checked fields"
          return afields
        -- Andreas, 2017-07-13 issue #2642 disallow duplicate fields
        -- Check for duplicate fields. (See "Check for duplicate constructors")
        do let fs :: [C.Name]
               fs = concat $ forMaybe fields $ \case
                 C.Field _ fs -> Just $ fs <&> \case
                   -- a Field block only contains field signatures
                   C.FieldSig _ _ f _ -> f
                   _ -> __IMPOSSIBLE__
                 _ -> Nothing
           List1.unlessNull (duplicates fs) $ \ dups -> do
             let bad = filter (`elem` dups) fs
             setCurrentRange bad $
               typeError $ DuplicateFields dups

        bindModule p x m
        let kind = maybe ConName (conKindOfName . rangedThing) ind

        cm' <- case cm of
          -- Andreas, 2019-11-11, issue #4189, no longer add record constructor to record module.
          Just (c, _) -> NamedRecCon <$> bindRecordConstructorName c kind a p

          -- Amy, 2024-09-25: if the record does not have a named
          -- constructor, then generate the QName here, and record it in
          -- the TC state so that 'Record.constructor' can be resolved.
          Nothing -> do
            -- Technically it doesn't matter with what this name is
            -- qualified since record constructor names have a special
            -- printing rule in lookupQName.
            constr <- withCurrentModule m $
              freshAbstractQName noFixity' $ simpleName "constructor"
            pure $ FreshRecCon constr

        setRecordConstructor x' (recordConName cm', fmap rangedThing ind)

        let inst = caseMaybe cm NotInstanceDef snd
        printScope "rec" 25 "record complete"
        f <- getConcreteFixity x
        let params = DataDefParams gvars pars
        let dir' = RecordDirectives ind eta pat cm'
        return [ A.RecDef (mkDefInfoInstance x f PublicAccess a inst NotMacroDef r) x' uc dir' params contel afields ]

    NiceModule r p a e x@(C.QName name) tel ds -> notAffectedByOpaque $ do
      reportSDoc "scope.decl" 70 $ vcat $
        [ text $ "scope checking NiceModule " ++ prettyShow x
        ]

      adecl <- traceCall (ScopeCheckDeclaration $
                          NiceModule r p a e x tel []) $ do
        scopeCheckNiceModule r p e name tel $
          toAbstract (Declarations ds)

      reportSDoc "scope.decl" 70 $ vcat $
        [ text $ "scope checked NiceModule " ++ prettyShow x
        , nest 2 $ prettyA adecl
        ]
      return [ adecl ]

    NiceModule _ _ _ _ m@C.Qual{} _ _ -> typeError QualifiedLocalModule

    NiceModuleMacro r p e x modapp open dir -> do
      reportSDoc "scope.decl" 70 $ vcat $
        [ text $ "scope checking NiceModuleMacro " ++ prettyShow x
        ]

      adecl <- checkModuleMacro Apply TopOpenModule
                 r p e x modapp open dir

      reportSDoc "scope.decl" 70 $ vcat $
        [ text $ "scope checked NiceModuleMacro " ++ prettyShow x
        , nest 2 $ prettyA adecl
        ]
      return [ adecl ]

    NiceOpen r x dir -> do
      (minfo, m, adir) <- checkOpen r Nothing x dir
      return [A.Open minfo m adir]

    NicePragma r p -> do
      ps <- toAbstract p  -- could result in empty list of pragmas
      return $ map (A.Pragma r) ps

    NiceImport r x as open dir -> setCurrentRange r $ do
      dir <- notPublicWithoutOpen open dir

      -- Andreas, 2018-11-03, issue #3364, parse expression in as-clause as Name.
      let illformedAs s = setCurrentRange as $ do
            -- If @as@ is followed by something that is not a simple name,
            -- throw a warning and discard the as-clause.
            Nothing <$ warning (IllformedAsClause s)
      as <- case as of
        -- Ok if no as-clause or it (already) contains a Name.
        Nothing -> return Nothing
        Just (AsName (Right asName) r)                    -> return $ Just $ AsName asName r
        Just (AsName (Left (C.Ident (C.QName asName))) r) -> return $ Just $ AsName asName r
        Just (AsName (Left C.Underscore{})     r)         -> return $ Just $ AsName underscore r
        Just (AsName (Left (C.Ident C.Qual{})) r) -> illformedAs "; a qualified name is not allowed here"
        Just (AsName (Left e)                  r) -> illformedAs ""

      top <- S.topLevelModuleName (rawTopLevelModuleNameForQName x)
      -- First scope check the imported module and return its name and
      -- interface. This is done with that module as the top-level module.
      -- This is quite subtle. We rely on the fact that when setting the
      -- top-level module and generating a fresh module name, the generated
      -- name will be exactly the same as the name generated when checking
      -- the imported module.
      (m, i) <- withCurrentModule noModuleName $
                withTopLevelModule top $ do
        printScope "import" 30 "before import:"
        (m0, i) <- scopeCheckImport top
        printScope "import" 30 $ "scope checked import: " ++ prettyShow i
        -- We don't want the top scope of the imported module (things happening
        -- before the module declaration)
        return (m0 `withRangesOfQ` x, Map.delete noModuleName i)

      -- Bind the desired module name to the right abstract name.
      (name, theAsSymbol, theAsName) <- case as of

         Just a | let y = asName a, not (isNoName y) -> do
           bindModule privateAccessInserted y m
           return (C.QName y, asRange a, Just y)

         _ -> do
           -- Don't bind if @import ... as _@ with "no name"
           whenNothing as $ bindQModule (privateAccessInserted) x m
           return (x, noRange, Nothing)

      -- Open if specified, otherwise apply import directives
      adir <- case open of

        -- With @open@ import directives apply to the opening.
        -- The module is thus present in its qualified form without restrictions.
        DoOpen   -> do

          -- Merge the imported scopes with the current scopes.
          -- This might override a previous import of @m@, but monotonously (add stuff).
          modifyScopes $ \ ms -> Map.unionWith mergeScope (Map.delete m ms) i

          -- Andreas, 2019-05-29, issue #3818.
          -- Pass the resolved name to open instead triggering another resolution.
          -- This helps in situations like
          -- @
          --    module Top where
          --    module M where
          --    open import M
          -- @
          -- It is clear than in @open import M@, name @M@ must refer to a file
          -- rather than the above defined local module @M@.
          -- This already worked in the situation
          -- @
          --    module Top where
          --    module M where
          --    import M
          -- @
          -- Note that the manual desugaring of @open import@ as
          -- @
          --    module Top where
          --    module M where
          --    import M
          --    open M
          -- @
          -- will not work, as @M@ is now ambiguous in @open M@;
          -- the information that @M@ is external is lost here.
          (_minfo, _m, adir) <- checkOpen r (Just m) name dir
          return adir

        -- If not opening, import directives are applied to the original scope.
        DontOpen -> do
          (adir, i') <- Map.adjustM' (applyImportDirectiveM x dir) m i
          -- Andreas, 2020-05-18, issue #3933
          -- We merge the new imports without deleting old imports, to be monotone.
          modifyScopes $ \ ms -> Map.unionWith mergeScope ms i'
          return adir

      printScope "import" 30 "merged imported sig:"
      let minfo = ModuleInfo
            { minfoRange     = r
            , minfoAsName    = theAsName
            , minfoAsTo      = getRange (theAsSymbol, renamingRange dir)
            , minfoOpenShort = Just open
            , minfoDirective = Just dir
            }
      return [ A.Import minfo m adir ]

    NiceUnquoteDecl r p a i tc cc xs e -> do
      fxs <- mapM getConcreteFixity xs
      ys <- zipWithM freshAbstractQName fxs xs
      zipWithM_ (bindName p QuotableName) xs ys
      e <- toAbstract e
      zipWithM_ (rebindName p OtherDefName) xs ys
      let mi = MutualInfo tc cc YesPositivityCheck r
      mapM_ unfoldFunction ys
      opaque <- contextIsOpaque
      return [ A.Mutual mi
        [ A.UnquoteDecl mi
            [ (mkDefInfoInstance x fx p a i NotMacroDef r) { Info.defOpaque = opaque } | (fx, x) <- zip fxs xs ]
          ys e
        ] ]

    NiceUnquoteDef r p a _ _ xs e -> do
      fxs <- mapM getConcreteFixity xs
      ys <- mapM (toAbstract . OldName) xs
      zipWithM_ (rebindName p QuotableName) xs ys
      e <- toAbstract e
      zipWithM_ (rebindName p OtherDefName) xs ys
      mapM_ unfoldFunction ys
      opaque <- contextIsOpaque
      return [ A.UnquoteDef [ (mkDefInfo x fx PublicAccess a r) { Info.defOpaque = opaque } | (fx, x) <- zip fxs xs ] ys e ]

    NiceUnquoteData r p a pc uc x cs e -> notAffectedByOpaque $ do
      fx <- getConcreteFixity x
      x' <- freshAbstractQName fx x
      bindName p QuotableName x x'

      -- Create the module for the qualified constructors
      checkForModuleClash x
      let m = qnameToMName x'
      createModule (Just IsDataModule) m
      bindModule p x m  -- make it a proper module

      cs' <- mapM (bindUnquoteConstructorName m p) cs

      e <- withCurrentModule m $ toAbstract e

      rebindName p DataName x x'
      zipWithM_ (rebindName p ConName) cs cs'
      withCurrentModule m $ zipWithM_ (rebindName p ConName) cs cs'

      fcs <- mapM getConcreteFixity cs
      let mi = MutualInfo TerminationCheck YesCoverageCheck pc r
      return
        [ A.Mutual
          mi [A.UnquoteData
            [ mkDefInfo x fx p a r ] x' uc
            [ mkDefInfo c fc p a r | (fc, c) <- zip fcs cs] cs' e ]
        ]

    NicePatternSyn r a n as p -> do
      reportSLn "scope.pat" 30 $ "found nice pattern syn: " ++ prettyShow n
      (as, p) <- withLocalVars $ do
         -- Expand puns if optHiddenArgumentPuns is True.
         p <- parsePatternSyn =<< expandPunsOpt p
         p <- toAbstract p
         when (containsAsPattern p) $
           typeError AsPatternInPatternSynonym
         checkPatternLinearity p $ \ys ->
           typeError $ RepeatedVariablesInPattern ys
         -- Bind the pattern variables accumulated by @ToAbstract Pattern@ applied to the rhs.
         bindVarsToBind
         p <- A.noDotOrEqPattern (typeError DotPatternInPatternSynonym) p
         as <- mapM checkPatSynParam as
         List1.unlessNull (patternVars p List.\\ map whThing as) $ \ xs -> do
           typeError $ UnboundVariablesInPatternSynonym xs
         return (as, p)
      y <- freshAbstractQName' n
      bindName a PatternSynName n y
      -- Expanding pattern synonyms already at definition makes it easier to
      -- fold them back when printing (issue #2762).
      ep <- expandPatternSynonyms p
      modifyPatternSyns (Map.insert y (as, ep))
      return [A.PatternSynDef y (map (fmap BindName) as) p]   -- only for highlighting, so use unexpanded version
      where
        checkPatSynParam :: WithHiding C.Name -> ScopeM (WithHiding A.Name)
        checkPatSynParam (WithHiding h x) = do
          let err = setCurrentRange x . typeError
          resolveName (C.QName x) >>= \case
            VarName a (PatternBound h')
              | isInstance h, not (isInstance h') -> err $ IllegalInstanceVariableInPatternSynonym x
              | otherwise -> return $ WithHiding h a
            ConstructorName _ ys -> err $ PatternSynonymArgumentShadows IsConstructor x ys
            PatternSynResName ys -> err $ PatternSynonymArgumentShadows IsPatternSynonym x ys
            UnknownName -> err $ UnusedVariableInPatternSynonym x
            -- Other cases are impossible because parsing the pattern syn rhs would have failed.
            _ -> __IMPOSSIBLE__

    d@NiceLoneConstructor{} -> withCurrentCallStack $ \ stk -> do
      warning $ NicifierIssue (DeclarationWarning stk (InvalidConstructorBlock (getRange d)))
      pure []

    d@(NiceOpaque kwr xs decls) -> do
      -- The names in an 'unfolding' clause must be unambiguous names of definitions:
      -- Resolve all the names, and use them as an initial unfolding set:
      names  <- catMaybes <$> forM xs \ x -> do
        setCurrentRange x $ unambiguousConOrDef (const . UnfoldingWrongName) x
      -- Generate the identifier for this block:
      oid    <- fresh
      -- Record the parent unfolding block, if any:
      parent <- asksTC envCurrentOpaqueId

      let r = getRange d
      stOpaqueBlocks `modifyTCLens` Map.insert oid OpaqueBlock
        { opaqueId        = oid
        , opaqueUnfolding = HashSet.fromList names
        , opaqueDecls     = mempty
        , opaqueParent    = parent
        , opaqueRange     = r
        }

      -- Keep going!
      localTC (\e -> e { envCurrentOpaqueId = Just oid }) $ do
        out <- traverse toAbstract decls
        unless (any interestingOpaqueDecl out) $ setCurrentRange kwr $ warning UselessOpaque
        pure $ UnfoldingDecl r names : out

-- | Checking postulate or type sig. without checking safe flag.
toAbstractNiceAxiom :: KindOfName -> C.NiceDeclaration -> ScopeM (A.QName, A.Declaration)
toAbstractNiceAxiom kind (C.Axiom r p a i info x t) = do
  -- Amy, 2025-05-04, issue 7856: type signatures (more
  -- importantly extended lambdas within them) should not belong
  -- to opaque blocks
  --
  -- Note that only scope checking the type happens outside the
  -- block since a bit below we need the proper opaque id to
  -- possibly update the info.
  t' <- notUnderOpaque $ toAbstractCtx TopCtx t

  f  <- getConcreteFixity x
  mp <- getConcretePolarity x
  y  <- freshAbstractQName f x
  let isMacro | kind == MacroName = MacroDef
              | otherwise         = NotMacroDef
  bindName p kind x y
  definfo <- updateDefInfoOpacity $ mkDefInfoInstance x f p a i isMacro r
  return (y, A.Axiom kind definfo info mp y t')
toAbstractNiceAxiom _ _ = __IMPOSSIBLE__

interestingOpaqueDecl :: A.Declaration -> Bool
interestingOpaqueDecl (A.Mutual _ ds)     = any interestingOpaqueDecl ds
interestingOpaqueDecl (A.ScopedDecl _ ds) = any interestingOpaqueDecl ds

interestingOpaqueDecl A.FunDef{}      = True
interestingOpaqueDecl A.UnquoteDecl{} = True
interestingOpaqueDecl A.UnquoteDef{}  = True

interestingOpaqueDecl _ = False

-- ** Helper functions for @opaque@
------------------------------------------------------------------------

-- | Add a 'QName' to the set of declarations /contained in/ the current
-- opaque block.
unfoldFunction :: A.QName -> ScopeM ()
unfoldFunction qn = asksTC envCurrentOpaqueId >>= \case
  Just id -> do
    let go Nothing   = __IMPOSSIBLE__
        go (Just ob) = Just ob{ opaqueDecls = qn `HashSet.insert` opaqueDecls ob }
    stOpaqueBlocks `modifyTCLens` Map.alter go id
  Nothing -> pure ()

-- | Look up the current opaque identifier as a value in 'IsOpaque'.
contextIsOpaque :: ScopeM IsOpaque
contextIsOpaque =  maybe TransparentDef OpaqueDef <$> asksTC envCurrentOpaqueId

updateDefInfoOpacity :: DefInfo -> ScopeM DefInfo
updateDefInfoOpacity di = (\a -> di { Info.defOpaque = a }) <$> contextIsOpaque

-- | Raise a warning indicating that the current Declaration is not
-- affected by opacity, but only if we are actually in an Opaque block.
notAffectedByOpaque :: ScopeM a -> ScopeM a
notAffectedByOpaque k = do
  whenM ((NoWhere_ ==) <$> asksTC envCheckingWhere) $
    whenJustM (asksTC envCurrentOpaqueId) \ _ ->
      warning NotAffectedByOpaque
  notUnderOpaque k

-- * Helper functions for @variable@ generalization
------------------------------------------------------------------------

unGeneralized :: A.Expr -> (Set A.QName, A.Expr)
unGeneralized (A.Generalized s t) = (Set1.toSet s, t)
unGeneralized (A.ScopedExpr si e) = A.ScopedExpr si <$> unGeneralized e
unGeneralized t = (mempty, t)

alreadyGeneralizing :: ScopeM Bool
alreadyGeneralizing = isJust <$> useTC stGeneralizedVars

-- | In the context of scope checking an expression, given a resolved name @d@:
--
--   * If @d@ is a @variable@ (generalizable), add it to the collection 'stGeneralizedVars'
--     of variables we wish to abstract over.
--
--   * Otherwise, do nothing.
--
class AddGeneralizable a where
  addGeneralizable :: a -> ScopeM ()

instance AddGeneralizable AbstractName where
  addGeneralizable :: AbstractName -> ScopeM ()
  addGeneralizable d = case anameKind d of
    GeneralizeName -> do
      gvs <- useTC stGeneralizedVars
      case gvs of   -- Subtle: Use (left-biased) union instead of insert to keep the old name if
                    -- already present. This way we can sort by source location when generalizing
                    -- (Issue 3354).
          Just s -> stGeneralizedVars `setTCLens` Just (s `Set.union` Set.singleton (anameName d))
          Nothing -> typeError $ GeneralizeNotSupportedHere $ anameName d
    DisallowedGeneralizeName -> typeError $ GeneralizedVarInLetOpenedModule $ anameName d
    _ -> return ()

instance AddGeneralizable ResolvedName where
  addGeneralizable = \case
    -- Only 'DefinedName' can be a @variable@.
    DefinedName _ d NoSuffix -> addGeneralizable d
    DefinedName _ d Suffix{} -> return ()
    VarName{}                -> return ()
    FieldName{}              -> return ()
    ConstructorName{}        -> return ()
    PatternSynResName{}      -> return ()
    UnknownName{}            -> return ()

collectGeneralizables :: ScopeM a -> ScopeM (Set A.QName, a)
collectGeneralizables m =
  -- #5683: No nested generalization
  ifM alreadyGeneralizing ((Set.empty,) <$> m) $
  {-else-} bracket_ open close $ do
      a <- m
      s <- useTC stGeneralizedVars
      case s of
          Nothing -> __IMPOSSIBLE__
          Just s -> return (s, a)
  where
    open = do
        gvs <- useTC stGeneralizedVars
        stGeneralizedVars `setTCLens` Just mempty
        pure gvs
    close = (stGeneralizedVars `setTCLens`)

createBoundNamesForGeneralizables :: Set A.QName -> ScopeM (Map A.QName A.Name)
createBoundNamesForGeneralizables vs =
  flip Map.traverseWithKey (Map.fromSet (const ()) vs) $ \ q _ -> do
    let x  = nameConcrete $ qnameName q
        fx = nameFixity   $ qnameName q
    freshAbstractName fx x

collectAndBindGeneralizables :: ScopeM a -> ScopeM (Map A.QName A.Name, a)
collectAndBindGeneralizables m = do
  fvBefore <- length <$> getLocalVars
  (s, res) <- collectGeneralizables m
  fvAfter  <- length <$> getLocalVars
  -- We should bind the named generalizable variables as fresh variables
  binds <- createBoundNamesForGeneralizables s
  -- Issue #3735: We need to bind the generalizable variables outside any variables bound by `m`.
  outsideLocalVars (fvAfter - fvBefore) $ bindGeneralizables binds
  return (binds, res)

bindGeneralizables :: Map A.QName A.Name -> ScopeM ()
bindGeneralizables vars =
  forM_ (Map.toList vars) $ \ (q, y) ->
    bindVariable LambdaBound (nameConcrete $ qnameName q) y

-- | Bind generalizable variables if data or record decl was split by the system
--   (origin == Inserted)
bindGeneralizablesIfInserted :: Origin -> AbstractName -> ScopeM (Set A.Name)
bindGeneralizablesIfInserted Inserted y = bound <$ bindGeneralizables gvars
  where gvars = case anameMetadata y of
          GeneralizedVarsMetadata gvars -> gvars
          NoMetadata                    -> Map.empty
        bound = Set.fromList (Map.elems gvars)
bindGeneralizablesIfInserted UserWritten _ = return Set.empty
bindGeneralizablesIfInserted _ _           = __IMPOSSIBLE__

newtype GenTel = GenTel C.Telescope
data GenTelAndType = GenTelAndType C.Telescope C.Expr

instance ToAbstract GenTel where
  type AbsOfCon GenTel = A.GeneralizeTelescope
  toAbstract (GenTel tel) =
    uncurry A.GeneralizeTel <$> collectAndBindGeneralizables (catMaybes <$> toAbstract tel)

instance ToAbstract GenTelAndType where
  type AbsOfCon GenTelAndType = (A.GeneralizeTelescope, A.Expr)

  toAbstract (GenTelAndType tel t) = do
    (binds, (tel, t)) <- collectAndBindGeneralizables $
                          (,) <$> toAbstract tel <*> toAbstract t
    return (A.GeneralizeTel binds (catMaybes tel), t)

-- ** Record directives
------------------------------------------------------------------------

-- | Check for duplicate record directives.
gatherRecordDirectives :: [C.RecordDirective] -> ScopeM C.RecordDirectives
gatherRecordDirectives ds = mapM_ gatherRecordDirective ds `execStateT` empty

-- | Fill the respective field of 'C.RecordDirectives' by the given 'C.RecordDirective'.
--
-- Ignore it with a dead-code warning if the field is already filled.
--
gatherRecordDirective :: C.RecordDirective -> StateT C.RecordDirectives ScopeM ()
gatherRecordDirective d = do
  dir@RecordDirectives{ recInductive = ind, recHasEta = eta, recPattern = pat, recConstructor = con } <- get
  case d of
    Induction ri         -> assertNothing ind $ put dir{ recInductive   = Just ri }
    Eta re               -> assertNothing eta $ put dir{ recHasEta      = Just re }
    PatternOrCopattern r -> assertNothing pat $ put dir{ recPattern     = Just r  }
    C.Constructor x inst -> assertNothing con $ put dir{ recConstructor = Just (x, inst) }
  where
    assertNothing :: Maybe a -> StateT C.RecordDirectives ScopeM () -> StateT C.RecordDirectives ScopeM ()
    assertNothing Nothing cont = cont
    assertNothing Just{}  _    = lift $ setCurrentRange d $ warning $ DuplicateRecordDirective d

-- ** Helper functions for name clashes
------------------------------------------------------------------------

-- | Make sure definition is in same module as signature.
class LivesInCurrentModule a where
  livesInCurrentModule :: a -> ScopeM ()

instance LivesInCurrentModule AbstractName where
  livesInCurrentModule = livesInCurrentModule . anameName

instance LivesInCurrentModule A.QName where
  livesInCurrentModule x = do
    m <- getCurrentModule
    reportS "scope.data.def" 30
      [ "  A.QName of data type: " ++ prettyShow x
      , "  current module: " ++ prettyShow m
      ]
    unless (A.qnameModule x == m) $
      typeError $ DefinitionInDifferentModule x

-- | Unless the resolved 'AbstractName' has the given 'KindOfName',
--   report a 'ClashingDefinition' for the 'C.Name'.
clashUnless :: C.Name -> KindOfName -> AbstractName -> ScopeM ()
clashUnless x k ax = unless (anameKind ax == k) $
  typeError $ ClashingDefinition (C.QName x) (anameName ax) Nothing

-- | If a (data/record) module with the given name is already present in the current module,
--   we take this as evidence that a data/record with that name is already defined.
clashIfModuleAlreadyDefinedInCurrentModule :: C.Name -> AbstractName -> ScopeM ()
clashIfModuleAlreadyDefinedInCurrentModule x ax = do
  datRecMods <- catMaybes <$> do
    mapM (isDatatypeModule . amodName) =<< lookupModuleInCurrentModule x
  unlessNull datRecMods $ const $
    typeError $ ClashingDefinition (C.QName x) (anameName ax) Nothing

lookupModuleInCurrentModule :: C.Name -> ScopeM [AbstractModule]
lookupModuleInCurrentModule x =
  List1.toList' . Map.lookup x . nsModules . thingsInScope [PublicNS, PrivateNS] <$> getCurrentScope

-- ** Helper functions for constructor declarations
------------------------------------------------------------------------

data DataConstrDecl = DataConstrDecl A.ModuleName IsAbstract Access C.NiceDeclaration

-- | Bind a @data@ constructor.
bindConstructorName
  :: ModuleName      -- ^ Name of @data@/@record@ module.
  -> C.Name          -- ^ Constructor name.
  -> IsAbstract
  -> Access
  -> ScopeM A.QName
bindConstructorName m x a p = do
  f <- getConcreteFixity x
  -- The abstract name is the qualified one
  y <- withCurrentModule m $ freshAbstractQName f x
  -- Bind it twice, once unqualified and once qualified
  bindName p' ConName x y
  withCurrentModule m $ bindName p'' ConName x y
  return y
  where
    -- An abstract constructor is private (abstract constructor means
    -- abstract datatype, so the constructor should not be exported).
    p' = case a of
           AbstractDef -> privateAccessInserted
           _           -> p
    p'' = case a of
            AbstractDef -> privateAccessInserted
            _           -> PublicAccess

-- | Record constructors do not live in the record module (as it is parameterized).
--   Abstract constructors are bound privately, so that they are not exported.
bindRecordConstructorName :: C.Name -> KindOfName -> IsAbstract -> Access -> ScopeM A.QName
bindRecordConstructorName x kind a p = do
  y <- freshAbstractQName' x
  bindName p' kind x y
  return y
  where
    -- An abstract constructor is private (abstract constructor means
    -- abstract datatype, so the constructor should not be exported).
    p' = case a of
           AbstractDef -> privateAccessInserted
           _           -> p

bindUnquoteConstructorName :: ModuleName -> Access -> C.Name -> TCM A.QName
bindUnquoteConstructorName m p c = do

  r <- resolveName (C.QName c)
  fc <- getConcreteFixity c
  c' <- withCurrentModule m $ freshAbstractQName fc c
  let aname qn = AbsName qn QuotableName Defined NoMetadata
      addName = modifyCurrentScope $ addNameToScope (localNameSpace p) c $ aname c'
      success = addName >> (withCurrentModule m $ addName)
      failure y = typeError $ ClashingDefinition (C.QName c) y Nothing
  case r of
    _ | isNoName c       -> success
    UnknownName          -> success
    ConstructorName i ds -> if all (isJust . isConName . anameKind) ds
      then success
      else failure $ anameName $ List1.head ds
    DefinedName _ d _    -> failure $ anameName d
    FieldName ds         -> failure $ anameName $ List1.head ds
    PatternSynResName ds -> failure $ anameName $ List1.head ds
    VarName y _          -> failure $ qualify_ y
  return c'

instance ToAbstract DataConstrDecl where
  type AbsOfCon DataConstrDecl = A.Declaration

  toAbstract (DataConstrDecl m a p d) = traceCall (ScopeCheckDeclaration d) do
    case d of
      C.Axiom r p1 a1 i ai x t -> do
        -- unless (p1 == p) __IMPOSSIBLE__  -- This invariant is currently violated by test/Succeed/Issue282.agda
        unless (a1 == a) __IMPOSSIBLE__
        ai <- checkConstructorArgInfo ai
        t' <- toAbstractCtx TopCtx t
        -- The abstract name is the qualified one
        -- Bind it twice, once unqualified and once qualified
        f <- getConcreteFixity x
        y <- bindConstructorName m x a p
        printScope "con" 25 "bound constructor"
        let defInfo = mkDefInfoInstance x f p a i NotMacroDef r
        return $ A.Axiom ConName defInfo ai Nothing y t'
      _ -> errorNotConstrDecl d

-- | Delete (with warning) attributes that are illegal for constructor declarations.
checkConstructorArgInfo :: ArgInfo -> ScopeM ArgInfo
checkConstructorArgInfo =
    ensureRelevant msg >=>
    ensureNotLinear msg >=>
    ensureContinuous msg >=>
    ensureMixedPolarity msg
  where
    msg = Just "of constructor"

errorNotConstrDecl :: C.NiceDeclaration -> ScopeM a
errorNotConstrDecl d = setCurrentRange d $
  typeError $ IllegalDeclarationInDataDefinition $ notSoNiceDeclarations d

ensureRelevant :: LensRelevance a => Maybe String -> a -> ScopeM a
ensureRelevant ms info = do
  if isRelevant info then return info else do
    whenJust ms \ s -> warning $ FixingRelevance s (getRelevance info) relevant
    return $ setRelevance relevant info

ensureNotLinear :: LensQuantity a => Maybe String -> a -> ScopeM a
ensureNotLinear s info = do
  case getQuantity info of
    Quantityω{} -> return info
    Quantity0{} -> return info
    q@Quantity1{} -> do
      -- Andreas, 2024-08-24, "@1" is still not parsed, so this is impossible.
      __IMPOSSIBLE__
      -- TODO: linearity
      -- let q' = Quantityω QωInferred
      -- warning $ FixingQuantity s q q'
      -- return $ setQuantity q' info

ensureContinuous :: LensCohesion a => Maybe String -> a -> ScopeM a
ensureContinuous ms info
  | isContinuous info = return info
  | otherwise = setCohesion Continuous info <$ do
      whenJust ms \ s -> warning $ FixingCohesion s (getCohesion info) Continuous

ensureMixedPolarity :: LensModalPolarity a => Maybe String -> a -> ScopeM a
ensureMixedPolarity ms info
  | splittablePolarity info = return info
  | otherwise = setModalPolarity mixedPolarity info <$ do
      whenJust ms \ s -> warning $ FixingPolarity s (getModalPolarity info) mixedPolarity

-- ** More scope checking
------------------------------------------------------------------------

instance ToAbstract C.Pragma where
  type AbsOfCon C.Pragma = [A.Pragma]

  toAbstract (C.ImpossiblePragma _ strs) =
    case strs of
      "ReduceM" : _ -> impossibleTestReduceM strs
      _ -> impossibleTest strs

  toAbstract (C.OptionsPragma _ opts) = return [ A.OptionsPragma opts ]

  toAbstract (C.RewritePragma _ r xs) = do
    (optRewriting <$> pragmaOptions) >>= \case

      -- If --rewriting is off, ignore the pragma.
      False -> [] <$ do
        warning $ UselessPragma r "Ignoring REWRITE pragma since option --rewriting is off"

      -- Warn about empty pragmas.
      True -> if null xs then [] <$ warning EmptyRewritePragma else do

        -- Check that names of rewrite rules are unambiguous.
        singleton . A.RewritePragma r . catMaybes <$> do
          forM xs \ x -> setCurrentRange x $ unambiguousConOrDef NotARewriteRule x

  toAbstract (C.ForeignPragma _ rb s) = [] <$ addForeignCode (rangedThing rb) s

  toAbstract (C.CompilePragma _ rb x s) =
    maybe [] (\ y -> [ A.CompilePragma rb y s ]) <$>
      unambiguousConOrDef PragmaCompileWrongName x

  toAbstract (C.StaticPragma _ x) = do
    map A.StaticPragma . maybeToList <$> do
      unambiguousDef (PragmaExpectsUnambiguousProjectionOrFunction "STATIC") x

  toAbstract (C.InjectivePragma _ x) = do
    map A.InjectivePragma . maybeToList <$> do
      unambiguousDef (PragmaExpectsUnambiguousProjectionOrFunction "INJECTIVE") x

  toAbstract (C.InjectiveForInferencePragma _ x) = do
    map A.InjectiveForInferencePragma . maybeToList <$> do
      scopeCheckDef (PragmaExpectsDefinedSymbol "INJECTIVE_FOR_INFERENCE") x

  toAbstract pragma@(C.InlinePragma _ b x) = do
      caseMaybeM (toAbstract $ MaybeOldQName $ OldQName x Nothing) notInScope \case
        A.Con (AmbQ xs)                -> concatMapM ret $ List1.toList xs
        A.Def x                        -> ret x
        A.Proj _ p
          | Just x <- getUnambiguous p -> ret x
          | otherwise                  -> uselessPragma pragma $ sINLINE ++ " used on ambiguous name " ++ prettyShow x
        _ -> uselessPragma pragma $ "Target of " ++ sINLINE ++ " pragma should be a function or constructor"
    where
      sINLINE    = if b then "INLINE" else "NOINLINE"
      notInScope = [] <$ notInScopeWarning x
      ret y      = return [ A.InlinePragma b y ]

  toAbstract (C.NotProjectionLikePragma _ x) = do
    map A.NotProjectionLikePragma . maybeToList <$> do
      unambiguousDef (PragmaExpectsUnambiguousProjectionOrFunction "NOT_PROJECTION_LIKE") x

  toAbstract (C.OverlapPragma _ xs i) = do
    map (flip A.OverlapPragma i) . catMaybes <$> do
      mapM (unambiguousConOrDef $ PragmaExpectsUnambiguousConstructorOrFunction pragma) xs
    where
      pragma = case i of
        Overlappable -> "OVERLAPPABLE"
        Overlapping  -> "OVERLAPPING"
        Overlaps     -> "OVERLAPS"
        Incoherent   -> "INCOHERENT"
        -- Never written by the user:
        DefaultOverlap -> __IMPOSSIBLE__
        FieldOverlap   -> __IMPOSSIBLE__

  toAbstract pragma@(C.BuiltinPragma _ rb qx)
    | Just b' <- b, isUntypedBuiltin b' = do
        q <- resolveQName qx
        bindUntypedBuiltin b' q
        return [ A.BuiltinPragma rb q ]
        -- Andreas, 2015-02-14
        -- Some builtins cannot be given a valid Agda type,
        -- thus, they do not come with accompanying postulate or definition.
    | Just b' <- b, isBuiltinNoDef b' = do
          case qx of
            C.QName x -> do
              -- The name shouldn't exist yet. If it does, we raise a warning
              -- and drop the existing definition.
              unlessM ((UnknownName ==) <$> resolveName qx) $ do
                warning $ BuiltinDeclaresIdentifier b'
                modifyCurrentScope $ removeNameFromScope PublicNS x
              -- We then happily bind the name
              y <- freshAbstractQName' x
              let kind = fromMaybe __IMPOSSIBLE__ $ builtinKindOfName b'
              bindName PublicAccess kind x y
              return [ A.BuiltinNoDefPragma rb kind y ]
            _ -> uselessPragma pragma $
              "Pragma BUILTIN " ++ getBuiltinId b' ++ ": expected unqualified identifier, " ++
              "but found " ++ prettyShow qx
    | otherwise = do
          q0 <- resolveQName qx

          -- Andreas, 2020-04-12, pr #4574.  For highlighting purposes:
          -- Rebind 'BuiltinPrim' as 'PrimName' and similar.
          q <- case (q0, b >>= builtinKindOfName, qx) of
            (DefinedName acc y suffix, Just kind, C.QName x)
              | anameKind y /= kind
              , kind `elem` [ PrimName, AxiomName ] -> do
                  rebindName acc kind x $ anameName y
                  return $ DefinedName acc y{ anameKind = kind } suffix
            _ -> return q0

          return [ A.BuiltinPragma rb q ]
    where b = builtinById (rangedThing rb)

  toAbstract (C.EtaPragma _ x) = do
    map A.EtaPragma . maybeToList <$> do
      scopeCheckDef (PragmaExpectsDefinedSymbol "ETA") x

  toAbstract pragma@(C.DisplayPragma _ lhs rhs) = do
    maybeToList <$> do
      withLocalVars $ runMaybeT do
        let err = failure "DISPLAY pragma left-hand side must have form 'f e1 .. en'"
            getHead (C.IdentP _ x)              = return x
            getHead (C.RawAppP _ (List2 p _ _)) = getHead p
            getHead _ = err

        top <- getHead lhs

        (isPatSyn, hd) <- do
          qx <- liftTCM $ resolveName' allKindsOfNames Nothing top
          case qx of
            VarName x' _                -> return . (False,) $ A.qnameFromList $ singleton x'
            DefinedName _ d NoSuffix    -> return . (False,) $ anameName d
            DefinedName _ d Suffix{}    -> failure $ "Invalid pattern " ++ prettyShow top
            FieldName     (d :| [])     -> return . (False,) $ anameName d
            FieldName ds                -> failure $ "Ambiguous projection " ++ prettyShow top ++ ": " ++ prettyShow (AmbQ $ fmap anameName ds)
            ConstructorName _ (d :| []) -> return . (False,) $ anameName d
            ConstructorName _ ds        -> failure $ "Ambiguous constructor " ++ prettyShow top ++ ": " ++ prettyShow (AmbQ $ fmap anameName ds)
            UnknownName                 -> do liftTCM $ notInScopeWarning top; mzero
            PatternSynResName (d :| []) -> return . (True,) $ anameName d
            PatternSynResName ds        -> failure $ "Ambiguous pattern synonym" ++ prettyShow top ++ ": " ++ prettyShow (fmap anameName ds)

        lhs <- liftTCM $ toAbstract $ LeftHandSide top lhs YesDisplayLHS
        ps  <- case lhs of
                 A.LHS _ (A.LHSHead _ ps) -> return ps
                 _ -> err

        -- Andreas, 2016-08-08, issue #2132
        -- Remove pattern synonyms on lhs
        (hd, ps) <- do
          p <- liftTCM $ expandPatternSynonyms $
            (if isPatSyn then A.PatternSynP else A.DefP) (PatRange $ getRange lhs) (unambiguous hd) ps
          case p of
            A.DefP _ f ps | Just hd <- getUnambiguous f -> return (hd, ps)
            A.ConP _ c ps | Just hd <- getUnambiguous c -> return (hd, ps)
            A.PatternSynP{} -> __IMPOSSIBLE__
            _ -> err

        rhs <- liftTCM $ toAbstract rhs

        -- Andreas, 2024-10-06, issue #7533:
        -- Check that all pattern variables occur on the rhs.
        -- Otherwise, there might be a misunderstanding of what display forms do.
        let used = allUsedNames rhs
        List1.unlessNull (filter (not . (isNoName || (`Set.member` used))) $ patternVars ps) $
          warning . UnusedVariablesInDisplayForm

        return $ A.DisplayPragma hd ps rhs
    where
      failure :: forall a. String -> MaybeT ScopeM a
      failure msg = do warning (UselessPragma (getRange pragma) $ P.fwords msg); mzero

  -- A warning attached to an ambiguous name shall apply to all disambiguations.
  toAbstract pragma@(C.WarningOnUsage _ x str) = do
    ys <- resolveName x >>= \case
      ConstructorName _ ds     -> return $ List1.toList ds
      FieldName ds             -> return $ List1.toList ds
      PatternSynResName ds     -> return $ List1.toList ds
      DefinedName _ d NoSuffix -> return $ singleton d
      DefinedName _ d Suffix{} -> [] <$ notInScopeWarning x
      UnknownName              -> [] <$ notInScopeWarning x
      VarName x _              -> [] <$ do
        uselessPragma pragma $ "Not a defined name: " ++ prettyShow x
    forM_ ys $ \ y -> stLocalUserWarnings `modifyTCLens` Map.insert (anameName y) str
    return []

  toAbstract (C.WarningOnImport _ str) = do
    stWarningOnImport `setTCLens` Just str
    pure []

  -- Termination, Coverage, Positivity, Universe, and Catchall
  -- pragmes are handled by the nicifier
  toAbstract C.TerminationCheckPragma{}  = __IMPOSSIBLE__
  toAbstract C.NoCoverageCheckPragma{}   = __IMPOSSIBLE__
  toAbstract C.NoPositivityCheckPragma{} = __IMPOSSIBLE__
  toAbstract C.NoUniverseCheckPragma{}   = __IMPOSSIBLE__
  toAbstract C.CatchallPragma{}          = __IMPOSSIBLE__

  -- Polarity pragmas are handled by the niceifier.
  toAbstract C.PolarityPragma{} = __IMPOSSIBLE__

uselessPragma :: HasRange p => p -> String -> ScopeM [a]
uselessPragma pragma = ([] <$) . warning . UselessPragma (getRange pragma) . P.fwords

unambiguousConOrDef :: (C.QName -> IsAmbiguous -> Warning) -> C.QName -> ScopeM (Maybe A.QName)
unambiguousConOrDef warn x = do
    caseMaybeM (toAbstract $ MaybeOldQName $ OldQName x Nothing) notInScope $ \case
      A.Def' y NoSuffix              -> ret y
      A.Def' y Suffix{}              -> failure NotAmbiguous
      A.Proj _ p
        | Just y <- getUnambiguous p -> ret y
        | otherwise                  -> failure $ YesAmbiguous p
      A.Con c
        | Just y <- getUnambiguous c -> ret y
        | otherwise                  -> failure $ YesAmbiguous c
      A.Var{}                        -> failure NotAmbiguous
      A.PatternSyn{}                 -> failure NotAmbiguous
      _ -> __IMPOSSIBLE__
  where
    notInScope = Nothing <$ notInScopeWarning x
    failure = (Nothing <$) . warning . warn x
    ret = return . Just

unambiguousDef :: (C.QName -> IsAmbiguous -> Warning) -> C.QName -> ScopeM (Maybe A.QName)
unambiguousDef warn x = do
    caseMaybeM (toAbstract $ MaybeOldQName $ OldQName x Nothing) notInScope $ \case
      A.Def' y NoSuffix              -> ret y
      A.Def' y Suffix{}              -> failure NotAmbiguous
      A.Proj _ p
        | Just y <- getUnambiguous p -> ret y
        | otherwise                  -> failure $ YesAmbiguous p
      A.Con{}                        -> failure NotAmbiguous
      A.Var{}                        -> failure NotAmbiguous
      A.PatternSyn{}                 -> failure NotAmbiguous
      _ -> __IMPOSSIBLE__
  where
    notInScope = Nothing <$ notInScopeWarning x
    failure = (Nothing <$) . warning . warn x
    ret = return . Just

scopeCheckDef :: (C.QName -> Warning) -> C.QName -> ScopeM (Maybe A.QName)
scopeCheckDef warn x = do
    caseMaybeM (toAbstract $ MaybeOldQName $ OldQName x Nothing) notInScope $ \case
      A.Def' y NoSuffix -> ret y
      A.Def' y Suffix{} -> failure
      A.Proj{}          -> failure
      A.Con{}           -> failure
      A.Var{}           -> failure
      A.PatternSyn{}    -> failure
      _ -> __IMPOSSIBLE__
  where
    notInScope = Nothing <$ notInScopeWarning x
    failure = Nothing <$ do warning $ warn x
    ret = return . Just

instance ToAbstract C.Clause where
  type AbsOfCon C.Clause = A.Clause

  toAbstract (C.Clause top catchall ai lhs@(C.LHS p eqs with) rhs wh wcs) = withLocalVars $ do
    -- Jesper, 2018-12-10, #3095: pattern variables bound outside the
    -- module are locally treated as module parameters
    modifyScope_ $ updateScopeLocals $ map $ second patternToModuleBound
    -- Andreas, 2012-02-14: need to reset local vars before checking subclauses
    vars0 <- getLocalVars
    lhs' <- toAbstract $ LeftHandSide (C.QName top) p NoDisplayLHS
    printLocals 30 "after lhs:"
    vars1 <- getLocalVars
    eqs <- mapM (toAbstractCtx TopCtx) eqs
    vars2 <- getLocalVars
    let vars = dropEnd (length vars1) vars2 ++ vars0
    let wcs' = (vars, wcs)

    -- Handle rewrite equations first.
    if not (null eqs)
      then do
        rhs <- toAbstractCtx TopCtx $ RightHandSide eqs with wcs' rhs wh
        rhs <- toAbstract rhs
        return $ A.Clause lhs' [] rhs A.noWhereDecls catchall
      else do
        -- the right hand side is checked with the module of the local definitions opened
        (rhs, ds) <- whereToAbstract (getRange wh) wh $
                       toAbstractCtx TopCtx $ RightHandSide [] with wcs' rhs NoWhere
        rhs <- toAbstract rhs
        return $ A.Clause lhs' [] rhs ds catchall


whereToAbstract
  :: Range                            -- ^ The range of the @where@ block.
  -> C.WhereClause                    -- ^ The @where@ block.
  -> ScopeM a                         -- ^ The scope-checking task to be run in the context of the @where@ module.
  -> ScopeM (a, A.WhereDeclarations)  -- ^ Additionally return the scope-checked contents of the @where@ module.
whereToAbstract r wh inner = do
  case wh of
    NoWhere       -> ret
    AnyWhere _ [] -> warnEmptyWhere
    AnyWhere _ ds -> enter do
      -- Andreas, 2016-07-17 issues #2081 and #2101
      -- where-declarations are automatically private.
      -- Andreas, 2025-03-29
      -- While since PR #5192 (Feb 2021, issue #481) it is no longer the case
      -- that we check their type signatures in abstract mode,
      -- we still need to mark the declaration as private
      -- e.g. to avoid spurious UnknownFixityInMixfixDecl warnings (issue #2889).
      whereToAbstract1 r defaultErased Nothing
        (singleton $ C.Private empty Inserted ds) inner
    SomeWhere _ e m a ds0 -> enter $
      List1.ifNull ds0 warnEmptyWhere {-else-} \ ds ->
      -- Named where-modules do not default to private.
      whereToAbstract1 r e (Just (m, a)) ds inner
  where
  enter = localTC \ env -> env { envCheckingWhere = C.whereClause_ wh }
  ret = (,A.noWhereDecls) <$> inner
  warnEmptyWhere = do
    setCurrentRange r $ warning EmptyWhere
    ret

whereToAbstract1
  :: Range                            -- ^ The range of the @where@-block.
  -> Erased                           -- ^ Is the where module erased?
  -> Maybe (C.Name, Access)           -- ^ The name of the @where@ module (if any).
  -> List1 C.Declaration              -- ^ The contents of the @where@ module.
  -> ScopeM a                         -- ^ The scope-checking task to be run in the context of the @where@ module.
  -> ScopeM (a, A.WhereDeclarations)  -- ^ Additionally return the scope-checked contents of the @where@ module.
whereToAbstract1 r e whname whds inner = do
  -- ASR (16 November 2015) Issue 1137: We ban termination
  -- pragmas inside `where` clause.
  checkNoTerminationPragma InWhereBlock whds

  -- Create a fresh concrete name if there isn't (a proper) one.
  (m, acc) <- do
    case whname of
      Just (m, acc) | not (isNoName m) -> return (m, acc)
      _ -> fresh <&> \ x -> (C.NoName (getRange whname) x, privateAccessInserted)
           -- unnamed where's are private
  old <- getCurrentModule
  am  <- toAbstract (NewModuleName m)
  (scope, d) <- scopeCheckModule r e (C.QName m) am [] $
                toAbstract $ Declarations $ List1.toList whds
  setScope scope
  x <- inner
  setCurrentModule old
  bindModule acc m am
  -- Issue 848: if the module was anonymous (module _ where) open it public
  let anonymousSomeWhere = maybe False (isNoName . fst) whname
  when anonymousSomeWhere $
   void $ -- We can ignore the returned default A.ImportDirective.
    openModule TopOpenModule (Just am) (C.QName m) $
      defaultImportDir { publicOpen = Just empty }
  return (x, A.WhereDecls (Just am) (isNothing whname) $ singleton d)

data TerminationOrPositivity = Termination | Positivity
  deriving (Show)

data WhereOrRecord = InWhereBlock | InRecordDef

checkNoTerminationPragma :: FoldDecl a => WhereOrRecord -> a -> ScopeM ()
checkNoTerminationPragma b ds =
  -- foldDecl traverses into all sub-declarations.
  forM_ (foldDecl (isPragma >=> isTerminationPragma) ds) \ (p, r) ->
    setCurrentRange r $ warning $ UselessPragma r $ P.vcat
      [ P.text $ show p ++ " pragmas are ignored in " ++ what b
      , "(see " <> issue b <> ")"
      ]
  where
    what InWhereBlock = "where clauses"
    what InRecordDef  = "record definitions"
    issue InWhereBlock = P.githubIssue 3355
    issue InRecordDef  = P.githubIssue 3008

    isTerminationPragma :: C.Pragma -> [(TerminationOrPositivity, Range)]
    isTerminationPragma = \case
      C.TerminationCheckPragma r _  -> [(Termination, r)]
      C.NoPositivityCheckPragma r   -> [(Positivity, r)]
      C.OptionsPragma _ _           -> []
      C.BuiltinPragma _ _ _         -> []
      C.RewritePragma _ _ _         -> []
      C.ForeignPragma _ _ _         -> []
      C.CompilePragma _ _ _ _       -> []
      C.StaticPragma _ _            -> []
      C.InlinePragma _ _ _          -> []
      C.ImpossiblePragma _ _        -> []
      C.EtaPragma _ _               -> []
      C.WarningOnUsage _ _ _        -> []
      C.WarningOnImport _ _         -> []
      C.InjectivePragma _ _         -> []
      C.InjectiveForInferencePragma{} -> []
      C.DisplayPragma _ _ _         -> []
      C.CatchallPragma _            -> []
      C.NoCoverageCheckPragma _     -> []
      C.PolarityPragma _ _ _        -> []
      C.NoUniverseCheckPragma _     -> []
      C.NotProjectionLikePragma _ _ -> []
      C.OverlapPragma _ _ _         -> []

data RightHandSide = RightHandSide
  { _rhsRewriteEqn :: [RewriteEqn' () A.BindName A.Pattern A.Expr]
    -- ^ @rewrite e | with p <- e in eq@ (many)
  , _rhsWithExpr   :: [C.WithExpr]
    -- ^ @with e@ (many)
  , _rhsSubclauses :: (LocalVars, [C.Clause])
    -- ^ the subclauses spawned by a with (monadic because we need to reset the local vars before checking these clauses)
  , _rhs           :: C.RHS
  , _rhsWhere      :: WhereClause
      -- ^ @where@ module.
  }

data AbstractRHS
  = AbsurdRHS'
  | WithRHS' (List1 A.WithExpr) (List1 (ScopeM C.Clause))
    -- ^ The with clauses haven't been translated yet
  | RHS' A.Expr C.Expr
  | RewriteRHS' [RewriteEqn' () A.BindName A.Pattern A.Expr] AbstractRHS A.WhereDeclarations

qualifyName_ :: A.Name -> ScopeM A.QName
qualifyName_ x = do
  m <- getCurrentModule
  return $ A.qualify m x

withFunctionName :: String -> ScopeM A.QName
withFunctionName s = do
  NameId i _ <- fresh
  qualifyName_ =<< freshName_ (s ++ show i)

instance ToAbstract (RewriteEqn' () A.BindName A.Pattern A.Expr) where
  type AbsOfCon (RewriteEqn' () A.BindName A.Pattern A.Expr) = A.RewriteEqn
  toAbstract = \case
    Rewrite es -> fmap Rewrite $ forM es $ \ (_, e) -> do
      qn <- withFunctionName "-rewrite"
      pure (qn, e)
    Invert _ pes -> do
      qn <- withFunctionName "-invert"
      pure $ Invert qn pes
    LeftLet pes -> pure $ LeftLet pes

instance ToAbstract C.RewriteEqn where
  type AbsOfCon C.RewriteEqn = RewriteEqn' () A.BindName A.Pattern A.Expr
  toAbstract = \case
    Rewrite es   -> Rewrite <$> mapM toAbstract es
    Invert _ npes -> Invert () <$> do
      -- Given a list of irrefutable with expressions of the form @p <- e in q@
      let (nps, es) = List1.unzip
                    $ fmap (\ (Named nm (p, e)) -> ((nm, p), e)) npes
      -- we first check the expressions @e@: the patterns may shadow some of the
      -- variables mentioned in them!
      es <- toAbstract es
      -- we then parse the pairs of patterns @p@ and names @q@ for the equality
      -- constraints of the form @p ≡ e@.
      nps <- forM nps $ \ (n, p) -> do
        -- first the pattern
        p <- toAbsPat p
        -- and then the name
        n <- toAbstract $ fmap (NewName WithBound . C.mkBoundName_) n
        pure (n, p)
      -- we finally reassemble the telescope
      pure $ List1.zipWith (\ (n,p) e -> Named n (p, e)) nps es
    LeftLet pes -> fmap LeftLet $ forM pes $ \ (p, e) -> do
      -- first check the expression: the pattern may shadow
      -- some of the variables mentioned in it!
      e <- toAbstract e
      p <- toAbsPat p
      pure (p, e)
    where
      toAbsPat p = do
        -- Expand puns if optHiddenArgumentPuns is True.
        p <- expandPunsOpt p
        p <- parsePattern p
        p <- toAbstract p
        checkPatternLinearity p (typeError . RepeatedVariablesInPattern)
        bindVarsToBind
        toAbstract p

instance ToAbstract AbstractRHS where
  type AbsOfCon AbstractRHS = A.RHS

  toAbstract AbsurdRHS'            = return A.AbsurdRHS
  toAbstract (RHS' e c)            = return $ A.RHS e $ Just c
  toAbstract (RewriteRHS' eqs rhs wh) = do
    eqs <- toAbstract eqs
    rhs <- toAbstract rhs
    return $ RewriteRHS eqs [] rhs wh
  toAbstract (WithRHS' es cs) = do
    aux <- withFunctionName "with-"
    A.WithRHS aux es <$> do toAbstract =<< sequence cs

instance ToAbstract RightHandSide where
  type AbsOfCon RightHandSide = AbstractRHS
  toAbstract (RightHandSide eqs@(_:_) es cs rhs wh)               = do
    (rhs, ds) <- whereToAbstract (getRange wh) wh $
                   toAbstract (RightHandSide [] es cs rhs NoWhere)
    return $ RewriteRHS' eqs rhs ds
  toAbstract (RightHandSide [] []    (_  , _:_) _          _)  = __IMPOSSIBLE__
  toAbstract (RightHandSide [] (_:_) _         (C.RHS _)   _)  = typeError BothWithAndRHS -- issue #7760
  toAbstract (RightHandSide [] []    (_  , []) rhs         NoWhere) = toAbstract rhs
  toAbstract (RightHandSide [] (z:zs)(lv , c:cs) C.AbsurdRHS NoWhere) = do
    let (ns, es) = List1.unzipWith (\ (Named nm e) -> (NewName WithBound . C.mkBoundName_ <$> nm, e)) $ z :| zs
    es <- toAbstractCtx TopCtx es
    lvars0 <- getLocalVars
    ns <- toAbstract ns
    lvars1 <- getLocalVars
    let lv' = dropEnd (length lvars0) lvars1 ++ lv
    let cs' = for (c :| cs) $ \ c -> setLocalVars lv' $> c
    let nes = List1.zipWith Named ns es
    return $ WithRHS' nes cs'
  -- TODO: some of these might be possible
  toAbstract (RightHandSide [] (_ : _) _ C.AbsurdRHS  AnyWhere{}) = __IMPOSSIBLE__
  toAbstract (RightHandSide [] (_ : _) _ C.AbsurdRHS SomeWhere{}) = __IMPOSSIBLE__
  toAbstract (RightHandSide [] (_ : _) _ C.AbsurdRHS   NoWhere{}) = __IMPOSSIBLE__
  toAbstract (RightHandSide [] []     (_, []) C.AbsurdRHS  AnyWhere{}) = __IMPOSSIBLE__
  toAbstract (RightHandSide [] []     (_, []) C.AbsurdRHS SomeWhere{}) = __IMPOSSIBLE__
  toAbstract (RightHandSide [] []     (_, []) C.RHS{}      AnyWhere{}) = __IMPOSSIBLE__
  toAbstract (RightHandSide [] []     (_, []) C.RHS{}     SomeWhere{}) = __IMPOSSIBLE__

instance ToAbstract C.RHS where
    type AbsOfCon C.RHS = AbstractRHS

    toAbstract C.AbsurdRHS = return $ AbsurdRHS'
    toAbstract (C.RHS e)   = RHS' <$> toAbstract e <*> pure e

-- | Wrapper to check lhs (possibly of a 'C.DisplayPragma').
--
data LeftHandSide = LeftHandSide
  C.QName
    -- ^ Name of the definition we are checking.
  C.Pattern
    -- ^ Full left hand side.
  DisplayLHS
    -- ^ Are we checking a 'C.DisplayPragma'?

instance ToAbstract LeftHandSide where
    type AbsOfCon LeftHandSide = A.LHS

    toAbstract (LeftHandSide top lhs displayLhs) =
      traceCall (ScopeCheckLHS top lhs) $ do
        reportSLn "scope.lhs" 25 $ "original lhs: " ++ prettyShow lhs
        reportSLn "scope.lhs" 60 $ "patternQNames: " ++ prettyShow (patternQNames lhs)
        reportSLn "scope.lhs" 60 $ "original lhs (raw): " ++ show lhs

        -- Expand puns if optHiddenArgumentPuns is True. Note that pun
        -- expansion should happen before the left-hand side is
        -- parsed, because {(x)} is not treated as a pun, whereas {x}
        -- is.
        lhs  <- expandPunsOpt lhs
        reportSLn "scope.lhs" 25 $
          "lhs with expanded puns: " ++ prettyShow lhs
        reportSLn "scope.lhs" 60 $
          "lhs with expanded puns (raw): " ++ show lhs

        lhscore <- parseLHS displayLhs top lhs
        let ell = hasExpandedEllipsis lhscore
        reportSLn "scope.lhs" 25 $ "parsed lhs: " ++ prettyShow lhscore
        reportSLn "scope.lhs" 60 $ "parsed lhs (raw): " ++ show lhscore
        printLocals 30 "before lhs:"
        -- error if copattern parsed but --no-copatterns option
        unlessM (optCopatterns <$> pragmaOptions) $
          when (hasCopatterns lhscore) $
            typeError $ NeedOptionCopatterns
        -- scope check patterns except for dot patterns
        lhscore <- toAbstract $ CLHSCore displayLhs lhscore
        bindVarsToBind
        -- reportSLn "scope.lhs" 25 $ "parsed lhs patterns: " ++ prettyShow lhscore  -- TODO: Pretty A.LHSCore'
        reportSLn "scope.lhs" 60 $ "parsed lhs patterns: " ++ show lhscore
        printLocals 30 "checked pattern:"
        -- scope check dot patterns
        lhscore <- toAbstract lhscore
        -- reportSLn "scope.lhs" 25 $ "parsed lhs dot patterns: " ++ prettyShow lhscore  -- TODO: Pretty A.LHSCore'
        reportSLn "scope.lhs" 60 $ "parsed lhs dot patterns: " ++ show lhscore
        printLocals 30 "checked dots:"
        return $ A.LHS (LHSInfo (getRange lhs) ell) lhscore

-- | Expands hidden argument puns when option 'optHiddenArgumentPuns' is set.

expandPunsOpt :: C.Pattern -> ScopeM C.Pattern
expandPunsOpt p = do
  pragmaOptions <&> optHiddenArgumentPuns <&> \case
    True  -> expandPuns p
    False -> p

-- | Expands hidden argument puns.

expandPuns :: C.Pattern -> C.Pattern
expandPuns = mapCPattern \case
  C.HiddenP   r p -> C.HiddenP   r $ expand p
  C.InstanceP r p -> C.InstanceP r $ expand p
  p -> p
  where
  -- Only patterns of the form {x} or ⦃ x ⦄, where x is an unqualified
  -- name (not @_@), are interpreted as puns.
  expand :: Named_ C.Pattern -> Named_ C.Pattern
  expand
   (Named { namedThing = C.IdentP _ q@(C.QName x@C.Name{})
          , nameOf     = Nothing
          }) =
    Named { namedThing = C.IdentP False q
          , nameOf     = Just $
                         WithOrigin
                           { woOrigin = ExpandedPun
                           , woThing  = unranged (prettyShow x)
                           }
          }
  expand p = p

hasExpandedEllipsis :: C.LHSCore -> ExpandedEllipsis
hasExpandedEllipsis core = case core of
  C.LHSHead{}       -> NoEllipsis
  C.LHSProj{}       -> hasExpandedEllipsis $ namedArg $ C.lhsFocus core -- can this ever be ExpandedEllipsis?
  C.LHSWith{}       -> hasExpandedEllipsis $ C.lhsHead core
  C.LHSEllipsis r p -> case p of
    C.LHSWith p wps _ -> hasExpandedEllipsis p <> ExpandedEllipsis r (length wps)
    C.LHSHead{}       -> ExpandedEllipsis r 0
    C.LHSProj{}       -> ExpandedEllipsis r 0
    C.LHSEllipsis{}   -> __IMPOSSIBLE__

-- | Merges adjacent EqualP patterns into one:
-- type checking expects only one pattern for each domain in the telescope.
mergeEqualPs :: [NamedArg (Pattern' e)] -> ScopeM [NamedArg (Pattern' e)]
mergeEqualPs = go (empty, [])
  where
    go acc (p@(Arg ai (Named mn (A.EqualP r es))) : ps) = setCurrentRange p $ do
      -- Face constraint patterns must be defaultNamedArg; check this:
      unless (getModality ai == defaultModality) __IMPOSSIBLE__
      when (notVisible ai) $
        warning $ FaceConstraintCannotBeHidden ai
      whenJust mn $ \ x -> setCurrentRange x $
        warning $ FaceConstraintCannotBeNamed x
      go (acc `mappend` (r, List1.toList es)) ps
    go (r, (e:es))   ps = (defaultNamedArg (A.EqualP r $ e :| es) :) <$> mergeEqualPs ps
    go (_, [])       [] = return []
    go (_, []) (p : ps) = (p :) <$> mergeEqualPs ps


-- | Scope-check a 'C.LHSCore' (of possibly a 'C.DisplayForm').

data CLHSCore = CLHSCore
  DisplayLHS
    -- ^ Are we checking the left hand side of a 'C.DisplayForm'?
  C.LHSCore
    -- ^ The lhs to scope-check.

-- | Scope-check a 'C.LHSCore' not of a 'C.DisplayForm'.

instance ToAbstract C.LHSCore where
  type AbsOfCon C.LHSCore = A.LHSCore' C.Expr

  toAbstract = toAbstract . CLHSCore NoDisplayLHS

-- does not check pattern linearity
instance ToAbstract CLHSCore where
  type AbsOfCon CLHSCore = A.LHSCore' C.Expr

  toAbstract (CLHSCore displayLhs core0) = case core0 of

    C.LHSHead x ps -> do
        x <- withLocalVars do
          setLocalVars []
          toAbstract (OldName x)
        ps <- toAbstract $ (fmap . fmap . fmap) (CPattern displayLhs) ps
        A.LHSHead x <$> mergeEqualPs ps

    C.LHSProj d ps1 core ps2 -> do
        unless (null ps1) $ typeError $ IllformedProjectionPatternConcrete (foldl C.AppP (C.IdentP True d) ps1)
        ds <- resolveName d >>= \case
          FieldName ds -> return $ fmap anameName ds
          UnknownName  -> notInScopeError d
          _            -> typeError $ CopatternHeadNotProjection d
        core <- toAbstract $ (fmap . fmap) (CLHSCore displayLhs) core
        ps2  <- toAbstract $ (fmap . fmap . fmap) (CPattern displayLhs) ps2
        A.LHSProj (AmbQ ds) core <$> mergeEqualPs ps2

    C.LHSWith core wps ps -> do
      -- DISPLAY pragmas cannot have @with@, so no need to pass on @displayLhs@.
      core <- toAbstract core
      wps  <- fmap defaultArg <$> toAbstract wps
      ps   <- toAbstract ps
      return $ A.lhsCoreApp (A.lhsCoreWith core wps) ps

    -- In case of a part of the LHS which was expanded from an ellipsis,
    -- we flush the @scopeVarsToBind@ in order to allow variables bound
    -- in the ellipsis to be shadowed.
    C.LHSEllipsis _ core -> do
      core <- toAbstract core  -- Cannot come from a DISPLAY pragma.
      bindVarsToBind
      return core

instance ToAbstract c => ToAbstract (WithHiding c) where
  type AbsOfCon (WithHiding c) = WithHiding (AbsOfCon c)
  toAbstract (WithHiding h a) = WithHiding h <$> toAbstractHiding h a

instance ToAbstract c => ToAbstract (Arg c) where
    type AbsOfCon (Arg c) = Arg (AbsOfCon c)
    toAbstract (Arg info e) =
        Arg info <$> toAbstractHiding info e

instance ToAbstract c => ToAbstract (Named name c) where
    type AbsOfCon (Named name c) = Named name (AbsOfCon c)
    toAbstract = traverse toAbstract

instance ToAbstract c => ToAbstract (Ranged c) where
    type AbsOfCon (Ranged c) = Ranged (AbsOfCon c)
    toAbstract = traverse toAbstract

{- DOES NOT WORK ANYMORE with pattern synonyms
instance ToAbstract c a => ToAbstract (A.LHSCore' c) (A.LHSCore' a) where
    toAbstract = mapM toAbstract
-}

instance ToAbstract (A.LHSCore' C.Expr) where
    type AbsOfCon (A.LHSCore' C.Expr) = A.LHSCore' A.Expr
    toAbstract (A.LHSHead f ps)         = A.LHSHead f <$> mapM toAbstract ps
    toAbstract (A.LHSProj d lhscore ps) = A.LHSProj d <$> mapM toAbstract lhscore <*> mapM toAbstract ps
    toAbstract (A.LHSWith core wps ps)  = liftA3 A.LHSWith (toAbstract core) (toAbstract wps) (toAbstract ps)

-- Patterns are done in two phases. First everything but the dot patterns, and
-- then the dot patterns. This is because dot patterns can refer to variables
-- bound anywhere in the pattern.

instance ToAbstract (A.Pattern' C.Expr) where
  type AbsOfCon (A.Pattern' C.Expr) = A.Pattern' A.Expr
  toAbstract = traverse $ insideDotPattern . toAbstractCtx DotPatternCtx  -- Issue #3033

resolvePatternIdentifier ::
     Bool
       -- ^ Is the identifier allowed to refer to a constructor (or a pattern synonym)?
       --
       --   Value 'False' is only used when 'optHiddenArgumentPuns' is 'True'.
       --   In this case, error 'InvalidPun' is thrown on identifiers that are not variables.
  -> DisplayLHS
       -- ^ Are definitions to be treated as constructors?
       --   'True' when we are checking a 'C.DisplayForm'.
  -> Hiding
       -- ^ Is the pattern variable hidden?
  -> C.QName
       -- ^ Identifier.
  -> Maybe (Set1 A.Name)
       -- ^ Possibly precomputed resolutions of the identifier (from the operator parser).
  -> ScopeM (A.Pattern' C.Expr)
resolvePatternIdentifier canBeConstructor displayLhs h x ns = do
  reportSLn "scope.pat" 60 $ "resolvePatternIdentifier " ++ prettyShow x ++ " at source position " ++ prettyShow r
  toAbstract (PatName x ns h displayLhs) >>= \case

    VarPatName y -> do
      reportSLn "scope.pat" 60 $ "  resolved to VarPatName " ++ prettyShow y ++ " with range " ++ prettyShow (getRange y)
      return $ VarP $ A.mkBindName y

    ConPatName ds -> do
      unless canBeConstructor $ err IsConstructor
      return $ ConP (ConPatInfo ConOCon info ConPatEager) (AmbQ $ fmap anameName ds) []

    PatternSynPatName ds -> do
      unless canBeConstructor $ err IsPatternSynonym
      return $ PatternSynP info (AmbQ $ fmap anameName ds) []

    DefPatName d -> do
      unless displayLhs __IMPOSSIBLE__
      return $ DefP info (AmbQ $ singleton $ anameName d) []

  where
  r = getRange x
  info = PatRange r
  err s = setCurrentRange r $ typeError $ InvalidPun s x

-- | Apply an abstract syntax pattern head to pattern arguments.
--
--   Fails with 'InvalidPattern' if head is not a constructor pattern
--   (or similar) that can accept arguments.
--
applyAPattern
  :: C.Pattern            -- ^ The application pattern in concrete syntax.
  -> A.Pattern' C.Expr    -- ^ Head of application.
  -> NAPs1 C.Expr         -- ^ Arguments of application.
  -> ScopeM (A.Pattern' C.Expr)
applyAPattern p0 p ps1 = do
  let ps = List1.toList ps1
  setRange (getRange p0) <$> do
    case p of
      A.ConP i x as        -> return $ A.ConP        i x (as ++ ps)
      A.DefP i x as        -> return $ A.DefP        i x (as ++ ps)
      A.PatternSynP i x as -> return $ A.PatternSynP i x (as ++ ps)
      -- Dotted constructors are turned into "lazy" constructor patterns.
      A.DotP i (Ident x)   -> resolveName x >>= \case
        ConstructorName _ ds -> do
          let cpi = ConPatInfo ConOCon i ConPatLazy
              c   = AmbQ (fmap anameName ds)
          return $ A.ConP cpi c ps
        _ -> failure
      A.DotP{}    -> failure
      A.VarP{}    -> failure
      A.ProjP{}   -> failure
      A.WildP{}   -> failure
      A.AsP{}     -> failure
      A.AbsurdP{} -> failure
      A.LitP{}    -> failure
      A.RecP{}    -> failure
      A.EqualP{}  -> failure
      A.WithP{}   -> failure
  where
    failure = typeError $ InvalidPattern p0

-- | Throw-away wrapper type for pattern translation.
data WithHidingInfo a = WithHidingInfo Hiding a

propagateHidingInfo :: NamedArg a -> NamedArg (WithHidingInfo a)
propagateHidingInfo a = fmap (fmap $ WithHidingInfo $ getHiding a) a

-- | Hiding info is only used for pattern variables.
instance ToAbstract (WithHidingInfo C.Pattern) where
    type AbsOfCon (WithHidingInfo C.Pattern) = A.Pattern' C.Expr

    toAbstract (WithHidingInfo h (C.IdentP canBeConstructor x)) =
      resolvePatternIdentifier canBeConstructor NoDisplayLHS h x Nothing

    toAbstract (WithHidingInfo _ p) = toAbstract p

-- | Scope check a 'C.Pattern' (of possibly a 'C.DisplayForm').
--
data CPattern = CPattern
  DisplayLHS
    -- ^ Are we checking a 'C.DisplayForm'?
  C.Pattern
    -- ^ The pattern to scope-check.

-- | Scope check a 'C.Pattern' not belonging to a 'C.DisplayForm'.
--
instance ToAbstract C.Pattern where
  type AbsOfCon C.Pattern = A.Pattern' C.Expr

  toAbstract = toAbstract . CPattern NoDisplayLHS

instance ToAbstract CPattern where
  type AbsOfCon CPattern = A.Pattern' C.Expr

  toAbstract (CPattern displayLhs p0) = case p0 of

    C.IdentP canBeConstructor x ->
      resolvePatternIdentifier canBeConstructor displayLhs empty x Nothing

    QuoteP _r ->
      typeError $ CannotQuote CannotQuoteNothing

    AppP (QuoteP _) p
      | IdentP _ x <- namedArg p -> do
          if visible p then do
            e <- toAbstract (OldQName x Nothing)
            A.LitP (PatRange $ getRange x) . LitQName <$> quotedName e
          else typeError $ CannotQuote CannotQuoteHidden
      | otherwise -> typeError $ CannotQuote $ CannotQuotePattern p

    AppP p q -> do
        reportSLn "scope.pat" 50 $ "distributeDots before = " ++ show p
        p <- distributeDots p
        reportSLn "scope.pat" 50 $ "distributeDots after  = " ++ show p
        p' <- toAbstract (wrap p)
        -- Remember hiding info in argument to propagate to 'PatternBound'.
        q' <- ifThenElse displayLhs
          {-then-} (toAbstract $ (fmap . fmap) wrap q)
          {-else-} (toAbstract $ propagateHidingInfo q)
        applyAPattern p0 p' $ singleton q'

        where
            distributeDots :: C.Pattern -> ScopeM C.Pattern
            distributeDots p@(C.DotP kwr r e) = distributeDotsExpr kwr r e
            distributeDots p = return p

            distributeDotsExpr :: KwRange -> Range -> C.Expr -> ScopeM C.Pattern
            distributeDotsExpr kwr r e = parseRawApp e >>= \case
              C.App r e a     ->
                AppP <$> distributeDotsExpr empty r e
                     <*> (traverse . traverse) (distributeDotsExpr empty r) a
              OpApp r q ns as ->
                case (traverse . traverse . traverse) fromNoPlaceholder as of
                  Just as -> OpAppP r q ns <$>
                    (traverse . traverse . traverse) (distributeDotsExpr empty r) as
                  Nothing -> return $ C.DotP empty r e
              Paren r e -> ParenP r <$> distributeDotsExpr empty r e
              _ -> return $ C.DotP kwr r e

            fromNoPlaceholder :: MaybePlaceholder (OpApp a) -> Maybe a
            fromNoPlaceholder (NoPlaceholder _ (Ordinary e)) = Just e
            fromNoPlaceholder _ = Nothing

            parseRawApp :: C.Expr -> ScopeM C.Expr
            parseRawApp (RawApp r es) = parseApplication es
            parseRawApp e             = return e

    OpAppP r op ns ps -> do
        reportSLn "scope.pat" 60 $ "ConcreteToAbstract.toAbstract OpAppP{}: " ++ show p0
        p  <- resolvePatternIdentifier True displayLhs empty op (Just ns)
        -- Remember hiding info in arguments to propagate to 'PatternBound'.
        ps <- ifThenElse displayLhs
          {-then-} (toAbstract $ (fmap . fmap . fmap) wrap ps)
          {-else-} (toAbstract $ fmap propagateHidingInfo ps)
        applyAPattern p0 p ps

    EllipsisP _ mp -> maybe __IMPOSSIBLE__ toAbstract mp  -- Not in DISPLAY pragma

    -- Removed when parsing
    HiddenP _ _    -> __IMPOSSIBLE__
    InstanceP _ _  -> __IMPOSSIBLE__
    RawAppP _ _    -> __IMPOSSIBLE__

    C.WildP r      -> return $ A.WildP $ PatRange r
    -- Andreas, 2015-05-28 futile attempt to fix issue 819: repeated variable on lhs "_"
    -- toAbstract p@(C.WildP r)    = A.VarP <$> freshName r "_"
    C.ParenP _ p   -> toAbstract $ wrap p  -- Andreas, 2024-09-27 not impossible
    C.LitP r l     -> setCurrentRange r $ A.LitP (PatRange r) l <$ checkLiteral l

    C.AsP r x p -> do
        -- Andreas, 2018-06-30, issue #3147: as-variables can be non-linear a priori!
        -- x <- toAbstract (NewName PatternBound x)
        -- Andreas, 2020-05-01, issue #4631: as-variables should not shadow constructors.
        -- x <- bindPatternVariable x
      toAbstract (PatName (C.QName x) Nothing empty NoDisplayLHS) >>= \case
        VarPatName x        -> A.AsP (PatRange r) (A.mkBindName x) <$> toAbstract (wrap p)
        ConPatName{}        -> ignoreAsPat IsConstructor
        PatternSynPatName{} -> ignoreAsPat IsPatternSynonym
        DefPatName{}        -> __IMPOSSIBLE__  -- because of @False@ in @PatName@
      where
      -- An @-bound name which shadows a constructor is illegal and becomes dead code.
      ignoreAsPat b = do
        setCurrentRange x $ warning $ AsPatternShadowsConstructorOrPatternSynonym b
        toAbstract $ wrap p

    C.EqualP r es -> return $ A.EqualP (PatRange r) es

    -- We have to do dot patterns at the end since they can
    -- refer to the variables bound by the other patterns.
    C.DotP _kwr r e -> do
      let fallback = return $ A.DotP (PatRange r) e
      case e of
        C.Ident x -> resolveName x >>= \case
          -- Andreas, 2018-06-19, #3130
          -- We interpret .x as postfix projection if x is a field name in scope
          FieldName xs -> return $ A.ProjP (PatRange r) ProjPostfix $ AmbQ $
            fmap anameName xs
          _ -> fallback
        _ -> fallback

    C.AbsurdP r -> return $ A.AbsurdP $ PatRange r
    C.RecP kwr r fs -> A.RecP kwr (ConPatInfo ConORec (PatRange r) ConPatEager) <$> mapM (traverse $ toAbstract . wrap) fs
    C.WithP r p -> A.WithP (PatRange r) <$> toAbstract p  -- not in DISPLAY pragma

    where
      -- Pass on @displayLhs@ context
      wrap = CPattern displayLhs

-- | An argument @OpApp C.Expr@ to an operator can have binders,
--   in case the operator is some @syntax@-notation.
--   For these binders, we have to create lambda-abstractions.
toAbstractOpArg :: Precedence -> OpApp C.Expr -> ScopeM A.Expr
toAbstractOpArg ctx (Ordinary e)                 = toAbstractCtx ctx e
toAbstractOpArg ctx (SyntaxBindingLambda r bs e) = toAbstractLam r bs e ctx

-- | Turn an operator application into abstract syntax. Make sure to
-- record the right precedences for the various arguments.
toAbstractOpApp :: C.QName -> Set1 A.Name -> OpAppArgs -> ScopeM A.Expr
toAbstractOpApp op ns es = do
    -- Replace placeholders with bound variables.
    (binders, es) <- replacePlaceholders $ List1.toList es
    -- Get the notation for the operator.
    nota <- getNotation op ns
    let parts = notation nota
    -- We can throw away the @VarPart@s, since binders
    -- have been preprocessed into @OpApp C.Expr@.
    let nonBindingParts = filter (not . isBinder) parts
    -- We should be left with as many holes as we have been given args @es@.
    -- If not, crash.
    unless (length (filter isAHole nonBindingParts) == length es) __IMPOSSIBLE__
    -- Translate operator and its arguments (each in the right context).
    op <- toAbstract (OldQName op (Just ns))
    es <- left (notaFixity nota) nonBindingParts es
    -- Prepend the generated section binders (if any).
    let body = List.foldl' app op es
    return $ foldr (A.Lam (ExprRange (getRange body))) body binders
  where
    -- Build an application in the abstract syntax, with correct Range.
    app e (pref, arg) = A.App info e arg
      where info = (defaultAppInfo r) { appOrigin = getOrigin arg
                                      , appParens = pref }
            r = fuseRange e arg

    inferParenPref :: NamedArg (Either A.Expr (OpApp C.Expr)) -> ParenPreference
    inferParenPref e =
      case namedArg e of
        Right (Ordinary e) -> inferParenPreference e
        Left{}             -> PreferParenless  -- variable inserted by section expansion
        Right{}            -> PreferParenless  -- syntax lambda

    -- Translate an argument. Returns the paren preference for the argument, so
    -- we can build the correct info for the A.App node.
    toAbsOpArg :: Precedence ->
                  NamedArg (Either A.Expr (OpApp C.Expr)) ->
                  ScopeM (ParenPreference, NamedArg A.Expr)
    toAbsOpArg cxt e = (pref,) <$> (traverse . traverse) (either return (toAbstractOpArg cxt)) e
      where pref = inferParenPref e

    -- The hole left to the first @IdPart@ is filled with an expression in @LeftOperandCtx@.
    left :: Fixity
         -> [NotationPart]
         -> [NamedArg (Either A.Expr (OpApp C.Expr))]
         -> ScopeM [(ParenPreference, NamedArg A.Expr)]
    left f (IdPart _ : xs) es = inside f xs es
    left f (_ : xs) (e : es) = do
        e  <- toAbsOpArg (LeftOperandCtx f) e
        es <- inside f xs es
        return (e : es)
    left f (_  : _)  [] = __IMPOSSIBLE__
    left f []        _  = __IMPOSSIBLE__

    -- The holes in between the @IdPart@s are filled with an expression in @InsideOperandCtx@.
    inside :: Fixity
           -> [NotationPart]
           -> [NamedArg (Either A.Expr (OpApp C.Expr))]
           -> ScopeM [(ParenPreference, NamedArg A.Expr)]
    inside f [x]             es = right f x es
    inside f (IdPart _ : xs) es = inside f xs es
    inside f (_  : xs) (e : es) = do
        e  <- toAbsOpArg InsideOperandCtx e
        es <- inside f xs es
        return (e : es)
    inside _ []      [] = return []
    inside _ (_ : _) [] = __IMPOSSIBLE__
    inside _ [] (_ : _) = __IMPOSSIBLE__

    -- The hole right of the last @IdPart@ is filled with an expression in @RightOperandCtx@.
    right :: Fixity
          -> NotationPart
          -> [NamedArg (Either A.Expr (OpApp C.Expr))]
          -> ScopeM [(ParenPreference, NamedArg A.Expr)]
    right _ (IdPart _)  [] = return []
    right f _          [e] = do
        let pref = inferParenPref e
        e <- toAbsOpArg (RightOperandCtx f pref) e
        return [e]
    right _ _     _  = __IMPOSSIBLE__

    replacePlaceholders ::
      OpAppArgs0 e ->
      ScopeM ([A.LamBinding], [NamedArg (Either A.Expr (OpApp e))])
    replacePlaceholders []       = return ([], [])
    replacePlaceholders (a : as) = case namedArg a of
      NoPlaceholder _ x -> mapSnd (set (Right x) a :) <$>
                             replacePlaceholders as
      Placeholder _     -> do
        x <- freshName noRange "section"
        let i = setOrigin Inserted $ argInfo a
        (ls, ns) <- replacePlaceholders as
        return ( A.mkDomainFree (unnamedArg i $ A.insertedBinder_ x) : ls
               , set (Left (Var x)) a : ns
               )
      where
      set :: a -> NamedArg b -> NamedArg a
      set x arg = fmap (fmap (const x)) arg

-- | Raises an error if the list of attributes contains an unsupported
-- attribute.

checkAttributes :: Attributes -> ScopeM ()
checkAttributes []                     = return ()
checkAttributes (Attr r s attr : attrs) =
  case attr of
    RelevanceAttribute{}    -> cont
    CA.TacticAttribute{}    -> cont
    LockAttribute IsNotLock -> cont
    LockAttribute IsLock{}  -> do
      unlessM (optGuarded <$> pragmaOptions) $
        setCurrentRange r $ typeError $ AttributeKindNotEnabled "Lock" "--guarded" s
      cont
    QuantityAttribute Quantityω{} -> cont
    QuantityAttribute Quantity1{} -> __IMPOSSIBLE__
    QuantityAttribute Quantity0{} -> do
      unlessM (optErasure <$> pragmaOptions) $
        setCurrentRange r $ typeError $ AttributeKindNotEnabled "Erasure" "--erasure" s
      cont
    CohesionAttribute{} -> do
      unlessM (optCohesion <$> pragmaOptions) $
        setCurrentRange r $ typeError $ AttributeKindNotEnabled "Cohesion" "--cohesion" s
      cont
    PolarityAttribute{} -> do
      unlessM (optPolarity <$> pragmaOptions) $
        setCurrentRange r $ typeError $ AttributeKindNotEnabled "Polarity" "--polarity" s
      cont
  where
  cont = checkAttributes attrs

{--------------------------------------------------------------------------
    Things we parse but are not part of the Agda file syntax
 --------------------------------------------------------------------------}

-- | Content of interaction hole.

instance ToAbstract C.HoleContent where
  type AbsOfCon C.HoleContent = A.HoleContent
  toAbstract = \case
    HoleContentExpr e     -> HoleContentExpr <$> toAbstract e
    HoleContentRewrite es -> HoleContentRewrite <$> toAbstract es
