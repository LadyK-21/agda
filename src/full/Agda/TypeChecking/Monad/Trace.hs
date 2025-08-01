{-# OPTIONS_GHC -Wunused-imports #-}

module Agda.TypeChecking.Monad.Trace where

import Prelude hiding (null)

import Control.Monad.Except         ( ExceptT  (ExceptT  ), runExceptT   , throwError )
import Control.Monad.Reader         ( ReaderT  (ReaderT  ), runReaderT   )
import Control.Monad.State          ( StateT   (StateT   ), runStateT    )
import Control.Monad.Trans.Identity ( IdentityT(IdentityT), runIdentityT )
import Control.Monad.Trans.Maybe    ( MaybeT   (MaybeT   ), runMaybeT    )
import Control.Monad.Writer         ( WriterT  (WriterT  ), runWriterT   )

import qualified Data.Set as Set

import Agda.Syntax.Common.Pretty
import Agda.Syntax.Parser (PM, runPMIO)
import Agda.Syntax.Position
import qualified Agda.Syntax.Position as P

import Agda.Interaction.Response
import Agda.Interaction.Highlighting.Precise
import Agda.Interaction.Highlighting.Range (rToR, minus)

import Agda.TypeChecking.Monad.Base
  hiding (ModuleInfo, MetaInfo, Primitive, Constructor, Record, Function, Datatype)
import Agda.TypeChecking.Monad.Debug
import Agda.TypeChecking.Monad.State
import Agda.TypeChecking.Warnings (warning)

import Agda.Utils.Function
import Agda.Utils.Monad
import Agda.Utils.Null

---------------------------------------------------------------------------
-- * Trace
---------------------------------------------------------------------------

interestingCall :: Call -> Bool
interestingCall = \case
    InferVar{}              -> False
    InferDef{}              -> False
    CheckArguments _ [] _ _ -> False
    SetRange{}              -> False
    NoHighlighting{}        -> False
    -- Andreas, 2019-08-07, expanded catch-all pattern.
    -- The previous presence of a catch-all raises the following question:
    -- are all of the following really interesting?
    CheckClause{}             -> True
    CheckLHS{}                -> True
    CheckPattern{}            -> True
    CheckPatternLinearityType{}  -> True
    CheckPatternLinearityValue{} -> True
    CheckLetBinding{}         -> True
    InferExpr{}               -> True
    CheckExprCall{}           -> True
    CheckDotPattern{}         -> True
    IsTypeCall{}              -> True
    IsType_{}                 -> True
    CheckArguments{}          -> True
    CheckMetaSolution{}       -> True
    CheckTargetType{}         -> True
    CheckDataDef{}            -> True
    CheckRecDef{}             -> True
    CheckConstructor{}        -> True
    CheckIApplyConfluence{}   -> True
    CheckConArgFitsIn{}       -> True
    CheckFunDefCall{}         -> True
    CheckPragma{}             -> True
    CheckPrimitive{}          -> True
    CheckIsEmpty{}            -> True
    CheckConfluence{}         -> True
    CheckModuleParameters{}   -> True
    CheckWithFunctionType{}   -> True
    CheckSectionApplication{} -> True
    CheckNamedWhere{}         -> True
    ScopeCheckExpr{}          -> True
    ScopeCheckDeclaration{}   -> True
    ScopeCheckLHS{}           -> True
    CheckProjection{}         -> True
    ModuleContents{}          -> True

class (MonadTCEnv m, ReadTCState m) => MonadTrace m where

  -- | Record a function call in the trace.
  traceCall :: Call -> m a -> m a
  traceCall call m = do
    cl <- buildClosure call
    traceClosureCall cl m

  traceCallM :: m Call -> m a -> m a
  traceCallM call m = flip traceCall m =<< call

  -- | Like 'traceCall', but resets 'envCall' and the current ranges to the
  --   previous values in the continuation.
  --
  traceCallCPS :: Call -> ((a -> m b) -> m b) -> ((a -> m b) -> m b)
  traceCallCPS call k ret = do

    -- Save current call and ranges.
    TCEnv{ envCall = mcall, envRange = r, envHighlightingRange = hr } <- askTC

    -- Run given computation under given call.
    traceCall call $ k $ \ a -> do

      -- Restore previous call and ranges for the continuation.
      localTC (\ e -> e{ envCall = mcall, envRange = r, envHighlightingRange = hr }) $
        ret a

  traceClosureCall :: Closure Call -> m a -> m a

  -- | Lispify and print the given highlighting information.
  printHighlightingInfo :: RemoveTokenBasedHighlighting -> HighlightingInfo -> m ()

  default printHighlightingInfo
    :: (MonadTrans t, MonadTrace n, t n ~ m)
    => RemoveTokenBasedHighlighting -> HighlightingInfo -> m ()
  printHighlightingInfo r i = lift $ printHighlightingInfo r i

traceCallCPS' :: MonadTrace m => Call -> (m b -> m b) -> m b -> m b
traceCallCPS' c k ret = traceCallCPS c (\ret -> k (ret ())) (\() -> ret)

instance MonadTrace m => MonadTrace (IdentityT m) where
  traceClosureCall c f = IdentityT $ traceClosureCall c $ runIdentityT f

instance MonadTrace m => MonadTrace (MaybeT m) where
  traceClosureCall c f = MaybeT $ traceClosureCall c $ runMaybeT f

instance MonadTrace m => MonadTrace (ReaderT r m) where
  traceClosureCall c f = ReaderT $ \r -> traceClosureCall c $ runReaderT f r

instance MonadTrace m => MonadTrace (StateT s m) where
  traceClosureCall c f = StateT (traceClosureCall c . runStateT f)

instance (MonadTrace m, Monoid w) => MonadTrace (WriterT w m) where
  traceClosureCall c f = WriterT $ traceClosureCall c $ runWriterT f

instance MonadTrace m => MonadTrace (ExceptT e m) where
  traceClosureCall c f = ExceptT $ traceClosureCall c $ runExceptT f

instance MonadTrace TCM where
  traceClosureCall cl m = do
    -- Andreas, 2016-09-13 issue #2177
    -- Since the fix of #2092 we may report an error outside the current file.
    -- (For instance, if we import a module which then happens to have the
    -- wrong name.)

    -- Compute update to 'Range' and 'Call' components of 'TCEnv'.
    let withCall = localTC $ foldr (.) id $ concat $
          [ [ \e -> e { envCall = Just cl } | interestingCall call ]
          , [ \e -> e { envHighlightingRange = callRange }
            | callHasRange && highlightCall
              || isNoHighlighting
            ]
          , [ \e -> e { envRange = callRange } | callHasRange ]
          ]

    -- For interactive highlighting, also wrap computation @m@ in 'highlightAsTypeChecked':
    ifNotM (pure highlightCall `and2M` do (Interactive ==) . envHighlightingLevel <$> askTC)
      {-then-} (withCall m)
      {-else-} $ do
        oldRange <- envHighlightingRange <$> askTC
        highlightAsTypeChecked oldRange callRange $
          withCall m
    where
    call = clValue cl
    callRange = getRange call
    callHasRange = not $ null callRange

    -- Should the given call trigger interactive highlighting?
    highlightCall = case call of
      CheckClause{}             -> True
      CheckLHS{}                -> True
      CheckPattern{}            -> True
      CheckPatternLinearityType{}  -> False
      CheckPatternLinearityValue{} -> False
      CheckLetBinding{}         -> True
      InferExpr{}               -> True
      CheckExprCall{}           -> True
      CheckDotPattern{}         -> True
      IsTypeCall{}              -> True
      IsType_{}                 -> True
      InferVar{}                -> True
      InferDef{}                -> True
      CheckArguments{}          -> True
      CheckMetaSolution{}       -> False
      CheckTargetType{}         -> False
      CheckDataDef{}            -> True
      CheckRecDef{}             -> True
      CheckConstructor{}        -> True
      CheckConArgFitsIn{}       -> False
      CheckFunDefCall _ _ h     -> h
      CheckPragma{}             -> True
      CheckPrimitive{}          -> True
      CheckIsEmpty{}            -> True
      CheckConfluence{}         -> False
      CheckIApplyConfluence{}   -> False
      CheckModuleParameters{}   -> False
      CheckWithFunctionType{}   -> True
      CheckSectionApplication{} -> True
      CheckNamedWhere{}         -> False
      ScopeCheckExpr{}          -> False
      ScopeCheckDeclaration{}   -> False
      ScopeCheckLHS{}           -> False
      NoHighlighting{}          -> True
      CheckProjection{}         -> False
      SetRange{}                -> False
      ModuleContents{}          -> False

    isNoHighlighting = case call of
      NoHighlighting{} -> True
      _ -> False

  printHighlightingInfo remove info = do
    modToSrc <- useTC stModuleToSource
    method   <- viewTC eHighlightingMethod
    reportSDoc "highlighting" 50 $ pure $ vcat
      [ "Printing highlighting info:"
      , nest 2 $ (text . show) info
      , "File modules:"
      , nest 2 $ pretty modToSrc
      ]
    unless (null info) $ do
      appInteractionOutputCallback $
          Resp_HighlightingInfo info remove method modToSrc


getCurrentRange :: MonadTCEnv m => m Range
getCurrentRange = asksTC envRange

-- | Sets the current range (for error messages etc.) to the range
--   of the given object, if it has a range (i.e., its range is not 'noRange').
setCurrentRange :: (MonadTrace m, HasRange x) => x -> m a -> m a
setCurrentRange x = applyUnless (null r) $ traceCall $ SetRange r
  where r = getRange x

-- | @highlightAsTypeChecked rPre r m@ runs @m@ and returns its
--   result. Additionally, some code may be highlighted:
--
-- * If @r@ is non-empty and not a sub-range of @rPre@ (after
--   'P.continuousPerLine' has been applied to both): @r@ is
--   highlighted as being type-checked while @m@ is running (this
--   highlighting is removed if @m@ completes /successfully/).
--
-- * Otherwise: Highlighting is removed for @rPre - r@ before @m@
--   runs, and if @m@ completes successfully, then @rPre - r@ is
--   highlighted as being type-checked.

highlightAsTypeChecked
  :: (MonadTrace m)
  => Range   -- ^ @rPre@
  -> Range   -- ^ @r@
  -> m a
  -> m a
highlightAsTypeChecked rPre r m
  | r /= noRange && delta == rPre' = wrap r'    highlight clear
  | otherwise                      = wrap delta clear     highlight
  where
  rPre'     = rToR (P.continuousPerLine rPre)
  r'        = rToR (P.continuousPerLine r)
  delta     = rPre' `minus` r'
  clear     = mempty
  highlight = parserBased { otherAspects = Set.singleton TypeChecks }

  wrap rs x y = do
    p rs x
    v <- m
    p rs y
    return v
    where
    p rs x = printHighlightingInfo KeepHighlighting (singleton rs x)

---------------------------------------------------------------------------
-- * Warnings in the parser
---------------------------------------------------------------------------

-- | Running the Parse monad, raising parser warnings.

runPM :: PM a -> TCM a
runPM m = do
  (res, ws) <- runPMIO m
  forM_ ws \ w -> setCurrentRange w $ warning $ ParseWarning w
  case res of
    Left  e -> throwError $ ParserError e
    Right a -> return a

-- | Running the Parse monad, dropping parser warnings.

runPMDropWarnings :: PM a -> TCM a
runPMDropWarnings m = do
  (res, _ws) <- runPMIO m
  case res of
    Left  e -> throwError $ ParserError e
    Right a -> return a
