{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE RecordWildCards #-}
module MXNet.NN (
    Parameter(..),
    Config(..),
    Exc(..),
    Initializer,
    Optimizer,
    TrainM,
    train,
    inferShape,
    initialize,
    fit,
    forwardOnly
) where

import MXNet.Core.Base hiding (bind, context)
import MXNet.Core.Base.Internal
import qualified MXNet.Core.Base.NDArray as A
import qualified MXNet.Core.Base.Symbol as S
import qualified MXNet.Core.Base.Executor as E
import qualified MXNet.Core.Types.Internal as MXI
import qualified Data.HashMap.Strict as M
import Data.Typeable
import qualified Control.Monad.State as ST
import Data.Maybe (isJust, fromJust)
import Control.Monad (when)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Trans.Resource (MonadThrow(..))
import Control.Exception.Base (Exception)
import Control.Lens (traverseOf, _1)

-- | A parameter is two 'NDArray' to back a 'Symbol'
data Parameter a = Parameter { _param_in :: NDArray a, _param_grad :: NDArray a }
    deriving Show

-- | TrainM is a 'StateT' monad, where the state is all the 'Parameters' and a 'Context'
type TrainM a m = ST.StateT (M.HashMap String (Parameter a), Context) m

-- | Initializer is about how to create a NDArray from a given shape. 
-- 
-- Usually, it can be a wrapper of MXNet operators, such as @random_uniform@, @random_normal@, 
-- @random_gamma@, etc..
type Initializer a = [Int] -> IO (NDArray a)
type Optimizer a = NDArray a -> NDArray a -> IO (NDArray a)
    
-- | Execute the 'TrainM' monad
train :: (DType a, Monad m) => M.HashMap String (Parameter a) -> Context -> TrainM a m r -> m r
train param context = flip ST.evalStateT (param, context)

-- | infer the shapes of all the symbols in a symbolic neural network
inferShape :: DType a => Symbol a -> M.HashMap String (NDArray a) -> IO (M.HashMap String [Int])
inferShape sym known = do
    let (names, vals) = unzip $ M.toList known
    shapes <- mapM ndshape vals
    let arg_ind = scanl (+) 0 $ map fst shapes
        arg_shp = concat $ map snd shapes
    (inp_shp, _, _) <- mxSymbolInferShape (S.getHandle sym) names arg_ind arg_shp
    inps <- listInputs sym
    return $ M.fromList $ zip inps inp_shp

-- | For every symbol in the neural network, it can be placeholder or a variable.
-- therefore, a Config is to specify the shape of the placeholder and the 
-- method to initialize the variables.
-- 
-- Note that it is not right to specify a symbol as both placeholder and 
-- initializer, although it is tolerated and such a symbol is considered
-- as a variable.
-- 
-- Note that any symbol not specified will be initialized with the 
-- _cfg_default_initializer.
data Config a = Config {
    _cfg_placeholders :: M.HashMap String [Int],
    _cfg_initializers :: M.HashMap String (Initializer a),
    _cfg_default_initializer :: Initializer a
}

-- | initialize all parameters
initialize :: DType a => Symbol a -> Config a -> IO (M.HashMap String (Parameter a))
initialize sym config = do
    let spec1 = M.difference (_cfg_placeholders config) (_cfg_initializers config)
        spec2 = _cfg_initializers config
        dinit = _cfg_default_initializer config
    placeholder  <- mapM zeros spec1
    inp_with_shp <- inferShape sym placeholder
    M.traverseWithKey (init_with_random_normal placeholder spec2 dinit) inp_with_shp
  where
    init_with_random_normal placeholder spec2 dinit inp shp = do
        case M.lookup inp placeholder of
            Just in_arg -> return $ Parameter in_arg (A.NDArray MXI.nullNDArrayHandle)
            Nothing -> do
                arg_in <- case M.lookup inp spec2 of
                    Just cinit -> cinit shp
                    Nothing    -> dinit shp
                arg_gr <- zeros shp
                return $ Parameter arg_in arg_gr

-- | bind the symbolic network with actual parameters
bind :: DType a => Symbol a -> M.HashMap String (Parameter a) -> Context -> Bool -> IO (Executor a)
bind net args Context{..} train_ = do
    names <- listInputs net
    exec_handle <- checked $ mxExecutorBind (S.getHandle net) deviceType deviceId
        (fromIntegral (M.size args))
        -- the parameters to bind should be arranged in the same order as the names
        (map (A.getHandle . _param_in) $ map (args M.!) names)
        (if train_
            then map (A.getHandle . _param_grad) $ map (args M.!) names
            else replicate (M.size args) MXI.nullNDArrayHandle)
        (replicate (M.size args) 1)
        0 []

    makeExecutor exec_handle

-- | single step train. Must provide all the placeholders.
fit :: (DType a, MonadIO m, MonadThrow m) => Optimizer a -> Symbol a -> M.HashMap String (NDArray a) -> TrainM a m ()
fit opt net datAndLbl = do
    shps <- liftIO $ inferShape net datAndLbl
    modifyT . traverseOf _1 $ M.traverseWithKey $ \k p -> do
        let ishp = shps M.! k
        case M.lookup k datAndLbl of
            Just a  -> return $ p {_param_in = a}
            Nothing -> do
                (_, pshp1) <- liftIO $ ndshape (_param_in p)
                (_, pshp2) <- liftIO $ ndshape (_param_grad p)
                when (ishp /= pshp1 || ishp /= pshp2) (throwM $ MismatchedShape k)
                return p
    (params, context) <- ST.get
    liftIO $ do
        exec <- bind net params context True
        checked $ mxExecutorForward (E.getHandle exec) 1
        backward exec
    modifyT . traverseOf _1  $ M.traverseWithKey $ \ k v -> do
        if (not $ M.member k datAndLbl)
            then do new_in <- liftIO $ opt (_param_in v) (_param_grad v) 
                    return $ v {_param_in = new_in}
            else return v

-- | forward only. Must provide all the placeholders, setting the data to @Just xx@, and set label to @Nothing@.
-- 
-- Note that the batch size here can be different from that in the training phase.
forwardOnly :: (DType a, MonadIO m, MonadThrow m) => Symbol a -> M.HashMap String (Maybe (NDArray a)) -> TrainM a m [NDArray a]
forwardOnly net dat = do
    shps <- liftIO $ inferShape net (M.map fromJust $ M.filter isJust dat)
    modifyT . traverseOf _1 $ M.traverseWithKey $ \k p -> do
        let ishp = shps M.! k
        case M.lookup k dat of
            Just (Just a) ->
                return $ p {_param_in = a}
            Just Nothing  -> do
                dummy <- liftIO $ zeros ishp
                return $ p {_param_in = dummy}
            Nothing -> do
                (_, pshp) <- liftIO $ ndshape (_param_in p)
                when (ishp /= pshp) (throwM $ MismatchedShape k)
                return p
    (params, context) <- ST.get
    liftIO $ do
        exec <- bind net params context False
        checked $ mxExecutorForward (E.getHandle exec) 0
        getOutputs exec

-- | Possible exception in 'TrainM'
data Exc = MismatchedShape String
    deriving (Show, Typeable)
instance Exception Exc

-- | modify the state within the inner monad
-- 
-- thanks to lens, we can modify the first field of the state with following 
-- combinator:
-- 
-- modifyT . traverseOf _1
--  :: (Field1 s s a b, Monad m) => (a -> m b) -> StateT s m ()
modifyT :: Monad m => (s -> m s) -> ST.StateT s m ()
modifyT func = do
    s0 <- ST.get
    s1 <- ST.lift $ func s0
    ST.put s1

