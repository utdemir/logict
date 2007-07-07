{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE UndecidableInstances #-}

-------------------------------------------------------------------------
-- |
-- Module : Control.Monad.Logic
-- Copyright :
-- License   :
--
-- Maintainer :
-- Stability  : experimental
-- Portability : non-portable (generalized newtype deriving,
--                              multi-parameter type classes)
--
-- A backtracking, logic programming monad.
--
--    Inspired by the paper
--    /Backtracking, Interleaving, and Terminating
--        Monad Transformers/, by
--    Oleg Kiselyov, Chung-chieh Shan, Daniel P. Friedman, Amr Sabry
--    (<http://www.cs.rutgers.edu/~ccshan/logicprog/LogicT-icfp2005.pdf>).
--
--    Heavily adapted from the implementation here:
--    (<http://okmij.org/ftp/packages/LogicT.tar.gz>).
-------------------------------------------------------------------------

module Control.Monad.Logic (
    module Control.Monad.Logic.Class,
    -- * The Logic monad
    Logic(),
    runLogic,
    observe,
    observeMany,
    observeAll,
    -- * The LogicT monad transformer
    LogicT(),
    runLogicT,
    observeT,
    observeManyT,
    observeAllT,
    module Control.Monad,
    module Control.Monad.Trans
  ) where

import Control.Applicative

import Control.Monad
import Control.Monad.Identity
import Control.Monad.Trans

import Control.Monad.Reader.Class
import Control.Monad.State.Class

import qualified Data.Foldable as F
import qualified Data.Traversable as T

import Control.Monad.Logic.Class

-- An Applicative instance for Identity, as MTL lacks one, currently
instance Applicative Identity where
    pure = Identity
    (Identity f) <*> (Identity a) = Identity (f a)

type SK r a = a -> r -> r
type FK a = a

-------------------------------------------------------------------------
-- | A monad transformer for performing backtracking computations
--   layered over another monad 'm'
newtype LogicT m a =
    LogicT { unLogicT :: forall ans. SK (m ans) a -> FK (m ans) -> m ans }

-------------------------------------------------------------------------
-- | Extracts the first result from a LogicT computation,
-- failing otherwise.
observeT :: Monad m => LogicT m a -> m a
observeT lt = unLogicT lt (const . return) (fail "No answer.")

-------------------------------------------------------------------------
-- | Extracts all the results from a LogicT computation.
observeAllT :: Monad m => LogicT m a -> m [a]
observeAllT m = unLogicT m (liftM . (:)) (return [])

-------------------------------------------------------------------------
-- | Extracts up to a given number of results from a LogicT computation.
observeManyT :: Monad m => Int -> LogicT m a -> m [a]
observeManyT n m
    | n <= 0 = return []
    | n == 1 = unLogicT m (\a _ -> return [a]) (return [])
    | otherwise = unLogicT (msplit m) sk (return [])
 where
 sk Nothing _ = return []
 sk (Just (a, m')) _ = (a:) `liftM` observeManyT (n-1) m'

-------------------------------------------------------------------------
-- | Runs a LogicT computation with the specified initial success and
-- failure continuations.
runLogicT :: LogicT m a -> (a -> m r -> m r) -> m r -> m r
runLogicT = unLogicT

-------------------------------------------------------------------------
-- | The basic Logic monad, for performing backtracking computations
--   returning values of type 'a'
newtype Logic a = Logic { unLogic :: LogicT Identity a }
        deriving (Functor, Applicative, Alternative, Monad, MonadPlus, MonadLogic)

-------------------------------------------------------------------------
-- | Extracts the first result from a Logic computation.
observe :: Logic a -> a
observe = runIdentity . observeT . unLogic

-------------------------------------------------------------------------
-- | Extracts all results from a Logic computation.
observeAll :: Logic a -> [a]
observeAll = runIdentity . observeAllT . unLogic

-------------------------------------------------------------------------
-- | Extracts up to a given number of results from a Logic computation.
observeMany :: Int -> Logic a -> [a]
observeMany i = runIdentity . observeManyT i . unLogic

-------------------------------------------------------------------------
-- | Runs a Logic computation with the specified initial success and
-- failure continuations.
runLogic :: Logic a -> (a -> r -> r) -> r -> r
runLogic l s f = runIdentity $ unLogicT (unLogic l) si fi
 where
 si = fmap . s
 fi = Identity f

instance (Functor f) => Functor (LogicT f) where
    fmap f lt = LogicT $ \sk fk -> unLogicT lt (sk . f) fk

instance (Applicative f) => Applicative (LogicT f) where
    pure a = LogicT $ \sk fk -> sk a fk
    f <*> a = LogicT $ \sk fk -> unLogicT f (\g fk' -> unLogicT a (sk . g) fk') fk

instance (Applicative f) => Alternative (LogicT f) where
    empty = LogicT $ \_ fk -> fk
    f1 <|> f2 = LogicT $ \sk fk -> unLogicT f1 sk (unLogicT f2 sk fk)

instance (Monad m) => Monad (LogicT m) where
    return a = LogicT $ \sk fk -> sk a fk
    m >>= f = LogicT $ \sk fk -> unLogicT m (\a fk' -> unLogicT (f a) sk fk') fk
    fail _ = LogicT $ \_ fk -> fk

instance (Monad m) => MonadPlus (LogicT m) where
    mzero = LogicT $ \_ fk -> fk
    m1 `mplus` m2 = LogicT $ \sk fk -> unLogicT m1 sk (unLogicT m2 sk fk)

instance MonadTrans LogicT where
    lift m = LogicT $ \sk fk -> m >>= \a -> sk a fk

instance (MonadIO m) => MonadIO (LogicT m) where
    liftIO = lift . liftIO

instance (Monad m) => MonadLogic (LogicT m) where
    msplit m = lift $ unLogicT m ssk (return Nothing)
     where
     ssk a fk = return $ Just (a, (lift fk >>= reflect))

instance F.Foldable Logic where
    foldr f z l = runLogic l f z

instance T.Traversable Logic where
    traverse g l = runLogic l (\a ft -> cons <$> g a <*> ft) (pure mzero)
     where cons a l = return a `mplus` l

-- Needs undecidable instances
instance (MonadReader r m) => MonadReader r (LogicT m) where
    ask = lift ask
    local f m = LogicT $ \sk fk -> unLogicT m ((local f .) . sk) (local f fk)

-- Needs undecidable instances
instance (MonadState s m) => MonadState s (LogicT m) where
    get = lift get
    put = lift . put

