{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}
module Main where

import MXNet.Core.Base
import qualified MXNet.Core.Base.NDArray as A
import qualified MXNet.Core.Base.Internal.TH.NDArray as A
import qualified Data.HashMap.Strict as M
import Control.Monad (forM_, void)
import qualified Streaming.Prelude as SR
import qualified Data.Vector.Storable as SV
import Control.Monad.IO.Class
import Control.Monad.Trans.Resource
import MXNet.NN
import MXNet.NN.Utils
import Dataset

neural :: IO SymbolF
neural = do
    x  <- variable "x"  :: IO SymbolF 
    y  <- variable "y"  :: IO SymbolF
    w1 <- variable "w1" :: IO SymbolF
    b1 <- variable "b1" :: IO SymbolF
    v1 <- fullyConnected x w1 b1 128
    a1 <- activation v1 "relu"
    w2 <- variable "w2" :: IO SymbolF
    b2 <- variable "b2" :: IO SymbolF
    v2 <- fullyConnected a1 w2 b2 10
    a2 <- softmaxOutput v2 y 
    return a2

range :: Int -> [Int]
range = enumFromTo 1

default_initializer :: DType a => Initializer a
default_initializer _ shape = A.NDArray <$> A.random_normal (add @"loc" 0 $ add @"scale" 1 $ add @"shape" (formatShape shape) nil)
    
optimizer :: DType a => Optimizer a
optimizer _ v g = A.NDArray <$> (A.sgd_update (A.getHandle v) (A.getHandle g) 0.01 nil)

main :: IO ()
main = do
    -- call mxListAllOpNames can ensure the MXNet itself is properly initialized
    -- i.e. MXNet operators are registered in the NNVM
    _  <- mxListAllOpNames
    net <- neural
    params <- initialize net $ Config { 
                _cfg_placeholders = M.singleton "x" [32,28,28],
                _cfg_initializers = M.empty,
                _cfg_default_initializer = default_initializer,
                _cfg_context = contextCPU
              }
    result <- runResourceT $ train params $ do 
        liftIO $ putStrLn $ "[Train] "
        trdat <- getContext >>= return . trainingData
        ttdat <- getContext >>= return . testingData
        forM_ (range 5) $ \ind -> do
            liftIO $ putStrLn $ "iteration " ++ show ind
            SR.mapM_ (\(x, y) -> fit optimizer net $ M.fromList [("x", x), ("y", y)]) trdat
        liftIO $ putStrLn $ "[Test] "

        SR.toList_ $ void $ flip SR.mapM ttdat $ \(x, y) -> do 
            [y'] <- forwardOnly net (M.fromList [("x", Just x), ("y", Nothing)])
            ind1 <- liftIO $ argmax y  >>= items
            ind2 <- liftIO $ argmax y' >>= items
            return (ind1, ind2)
    let (ls,ps) = unzip result
        ls_unbatched = mconcat ls
        ps_unbatched = mconcat ps
        total   = SV.length ls_unbatched
        correct = SV.length $ SV.filter id $ SV.zipWith (==) ls_unbatched ps_unbatched
    putStrLn $ "Accuracy: " ++ show correct ++ "/" ++ show total
  
  where
    argmax :: ArrayF -> IO ArrayF
    argmax ys = A.NDArray <$> A.argmax (A.getHandle ys) (add @"axis" 1 nil)