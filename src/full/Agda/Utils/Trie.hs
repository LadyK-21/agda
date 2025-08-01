{-# OPTIONS_GHC -Wunused-imports #-}

-- | Strict tries (based on "Data.Map.Strict" and "Agda.Utils.Maybe.Strict").
--
-- Note that if 'delete' or 'adjust' are used, one may end up with non-canonical
-- subtries, i.e., those that do not contain any value (@Data.List.null . toList@)
-- but may be @Eq@-different to other empty tries (@/= empty@).

module Agda.Utils.Trie
  ( Trie(..)
  , empty, singleton, everyPrefix, insert, insertWith, union, unionWith
  , fromList
  , prefixBy
  -- Andreas 2024-11-16:
  -- Deletion does not clean up the trie, thus violates equational laws
  -- with the given Eq that does not quotient out the different representations
  -- of empty subtries.
  -- E.g. @delete k . insert k v . delete k /= delete k@.
  -- @adjust@ has a similar problem.
  , adjust, delete
  , toList, toAscList, toListOrderedBy
  , lookup, member, lookupPath, lookupTrie
  , mapSubTries, filter
  , valueAt
  ) where

import Prelude hiding (null, lookup, filter)

import Control.DeepSeq

import Data.Function (on)
import qualified Data.Maybe as Lazy
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map

import qualified Data.List as List

import qualified Agda.Utils.Maybe.Strict as Strict
import Agda.Utils.Null
import Agda.Utils.Lens

-- | Finite map from @[k]@ to @v@.
--
--   With the strict 'Maybe' type, 'Trie' is also strict in 'v'.
data Trie k v = Trie !(Strict.Maybe v) !(Map k (Trie k v))
  deriving
    ( Show
    , Eq
        -- Andreas, 2024-11-16: The derived Eq isn't extensional.
        -- It disguishes different representation of the empty Trie.
        -- (E.g. the empty map and the map that only contains Nothing values.)
    , Functor
    , Foldable
    )

instance (NFData k, NFData v) => NFData (Trie k v) where
  rnf (Trie a b) = rnf a `seq` rnf b

-- | Empty trie.
instance Null (Trie k v) where
  empty = Trie Strict.Nothing Map.empty
  null (Trie v t) = null v && all null t
    -- Andreas, 2024-11-16: since we allow non-canoncial tries,
    -- we have to check that every subtrie is empty,
    -- not just that there are no subtries.

-- | Helper function used to implement 'singleton' and 'everyPrefix'.
singletonOrEveryPrefix :: Bool -> [k] -> v -> Trie k v
singletonOrEveryPrefix _           []       !v =
  Trie (Strict.Just v) Map.empty
singletonOrEveryPrefix everyPrefix (x : xs) !v =
  Trie (if everyPrefix then Strict.Just v else Strict.Nothing)
       (Map.singleton x (singletonOrEveryPrefix everyPrefix xs v))

-- | Singleton trie.
singleton :: [k] -> v -> Trie k v
singleton = singletonOrEveryPrefix False

-- | @everyPrefix k v@ is a trie where every prefix of @k@ (including
-- @k@ itself) is mapped to @v@.
everyPrefix :: [k] -> v -> Trie k v
everyPrefix = singletonOrEveryPrefix True

-- | Prefix every key by the given prefix.
prefixBy :: [k] -> Trie k v -> Trie k v
prefixBy []     t = t
prefixBy (k:ks) t = Trie Strict.Nothing $ Map.singleton k $ prefixBy ks t

-- | Left biased union.
--
--   @union = unionWith (\ new old -> new)@.
union :: (Ord k) => Trie k v -> Trie k v -> Trie k v
union = unionWith const

-- | Pointwise union with merge function for values.
unionWith :: (Ord k) => (v -> v -> v) -> Trie k v -> Trie k v -> Trie k v
unionWith f (Trie v ss) (Trie w ts) =
  Trie (Strict.unionMaybeWith f v w) (Map.unionWith (unionWith f) ss ts)

-- | Insert.  Overwrites existing value if present.
--
--   @insert = insertWith (\ new old -> new)@
insert :: (Ord k) => [k] -> v -> Trie k v -> Trie k v
insert k v t = (singleton k v) `union` t

-- | Insert with function merging new value with old value.
insertWith :: (Ord k) => (v -> v -> v) -> [k] -> v -> Trie k v -> Trie k v
insertWith f k v t = unionWith f (singleton k v) t

fromList :: Ord k => [([k],v)] -> Trie k v
fromList = foldl (\ t (ks, v) -> insert ks v t) empty

-- Andreas, 2024-11-16: delete does not clean up empty subtrees,
-- so it is not correct wrt. @Eq@.

-- | Delete value at key, but leave subtree intact.
--
-- Disclaimer: may return a non-canoncial trie
-- because it does not clean up subtries that become empty.
--
delete :: Ord k => [k] -> Trie k v -> Trie k v
delete path = adjust path (const Strict.Nothing)

-- Andreas, 2024-11-16: adjust does not clean up empty subtrees,
-- so it is not correct wrt. @Eq@.

-- | Adjust value at key, leave subtree intact.
--
-- Disclaimer: may return a non-canoncial trie
-- because it does not clean up subtries that become empty.
--
adjust ::
  Ord k =>
  [k] -> (Strict.Maybe v -> Strict.Maybe v) -> Trie k v -> Trie k v
adjust path f t@(Trie v ts) =
  case path of
    -- case: found the value we want to adjust: adjust it!
    []                                 -> Trie (f v) ts
    -- case: found the subtrie matching the first key: adjust recursively
    k : ks | Just s <- Map.lookup k ts -> Trie v $ Map.insert k (adjust ks f s) ts
    -- case: subtrie not found: leave trie untouched
    _ -> t

-- | Convert to ascending list.
toList :: Ord k => Trie k v -> [([k],v)]
toList = toAscList

-- | Convert to ascending list.
toAscList :: Ord k => Trie k v -> [([k],v)]
toAscList (Trie mv ts) = Strict.maybeToList (([],) <$> mv) ++
  [ (k:ks, v)
  | (k,  t) <- Map.toAscList ts
  , (ks, v) <- toAscList t
  ]

-- | Convert to list where nodes at the same level are ordered according to the
--   given ordering.
toListOrderedBy :: Ord k => (v -> v -> Ordering) -> Trie k v -> [([k], v)]
toListOrderedBy cmp (Trie mv ts) =
  Strict.maybeToList (([],) <$> mv) ++
  [ (k : ks, v) | (k, t)  <- List.sortBy (cmp' `on` val . snd) $ Map.toAscList ts,
                  (ks, v) <- toListOrderedBy cmp t ]
  where
    cmp' Strict.Nothing  Strict.Just{}   = LT
    cmp' Strict.Just{}   Strict.Nothing  = GT
    cmp' Strict.Nothing  Strict.Nothing  = EQ
    cmp' (Strict.Just x) (Strict.Just y) = cmp x y
    val (Trie mv _) = mv

-- | Create new values based on the entire subtrie. Almost, but not quite
--   comonad extend.
mapSubTries :: Ord k => (Trie k u -> Maybe v) -> Trie k u -> Trie k v
mapSubTries f t@(Trie mv ts) = Trie (Strict.toStrict (f t)) (fmap (mapSubTries f) ts)

-- | Returns the value associated with the given key, if any.
lookup :: Ord k => [k] -> Trie k v -> Maybe v
lookup []       (Trie v _)  = Strict.toLazy v
lookup (k : ks) (Trie _ ts) = case Map.lookup k ts of
  Nothing -> Nothing
  Just t  -> lookup ks t

-- | Is the given key present in the trie?
member :: Ord k => [k] -> Trie k v -> Bool
member ks t = Lazy.isJust (lookup ks t)

-- | Collect all values along a given path.
lookupPath :: Ord k => [k] -> Trie k v -> [v]
lookupPath xs (Trie v cs) = case xs of
    []     -> Strict.maybeToList v
    x : xs -> Strict.maybeToList v ++
              maybe [] (lookupPath xs) (Map.lookup x cs)

-- | Get the subtrie rooted at the given key.
lookupTrie :: Ord k => [k] -> Trie k v -> Trie k v
lookupTrie []       t           = t
lookupTrie (k : ks) (Trie _ cs) = maybe empty (lookupTrie ks) (Map.lookup k cs)

-- | Filter a trie.
filter :: Ord k => (v -> Bool) -> Trie k v -> Trie k v
filter p (Trie mv ts) = Trie mv' (Map.filter (not . null) $ filter p <$> ts)
  where
    mv' =
      case mv of
        Strict.Just v | p v -> mv
        _                   -> Strict.Nothing

-- | Key lens.
valueAt :: Ord k => [k] -> Lens' (Trie k v) (Maybe v)
valueAt path f t = f (lookup path t) <&> \ case
  Nothing -> delete path t
  Just v  -> insert path v t
