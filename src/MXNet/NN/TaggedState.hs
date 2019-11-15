{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DataKinds, TypeOperators #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE PolyKinds #-}
module MXNet.NN.TaggedState where

import qualified GHC.TypeLits as L
import Data.Type.Product
import Data.Type.Index
import Control.Monad.State.Strict (StateT(..))
import Control.Lens (makeLenses)
import Data.Proxy (Proxy(..))

newtype Tagged a (t :: L.Symbol) = Tagged {_untag :: a} deriving Show
makeLenses ''Tagged

liftSub :: forall k (f :: k -> *) s1 s2 m a. (Elem s2 s1, Monad m) => StateT (f s1) m a -> StateT (Prod f s2) m a
liftSub (StateT m1) = StateT $ \s -> do
    (a, si) <- m1 $ index elemIndex s
    let new_s = modify elemIndex si s
    new_s `seq` return (a, new_s)


modify :: Index as a -> f a -> Prod f as -> Prod f as
modify IZ new (_ :< remainder) = new :< remainder
modify (IS s) new (first :< remainder) = first :< modify s new remainder

toPair :: forall t a. L.KnownSymbol t => Tagged a t -> (String, a)
toPair (Tagged a)= (L.symbolVal (Proxy :: Proxy t), a)


-- a1 :: StateT (Tagged Int "A") IO ()
-- a1 = put (Tagged 4)
--
-- a2 :: StateT (Tagged String "B") IO ()
-- a2 = put (Tagged "hi")
--
-- a3 :: StateT (ProdI '[Tagged Int "A", Tagged String "B"]) IO ()
-- a3 = do
--     liftT a1
--     liftT a2

-- runStateT a3 (Identity (Tagged 0) :> Identity (Tagged ""))
