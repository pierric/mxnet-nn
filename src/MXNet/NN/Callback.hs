module MXNet.NN.Callback where

import RIO
import RIO.Time
import RIO.FilePath
import Formatting
import Control.Lens (use)

import MXNet.NN.Types (mod_statistics, stat_last_lr)
import MXNet.NN.Session
import MXNet.NN.TaggedState (untag)
import MXNet.NN.Utils (saveState)

-- | Learning rate
data DumpLearningRate = DumpLearningRate

instance CallbackClass DumpLearningRate where
    endOfBatch _ _ _ = do
        lr <- use (untag . mod_statistics . stat_last_lr)
        lift . logInfo . display $ sformat ("<lr: " % fixed 6 % ">") lr

-- | Throughput
data DumpThroughputEpoch = DumpThroughputEpoch {
    _tp_begin_time :: IORef UTCTime,
    _tp_end_time :: IORef UTCTime,
    _tp_total_sample :: IORef Int
}

instance CallbackClass DumpThroughputEpoch where
    begOfBatch _ n (DumpThroughputEpoch _ _ totalRef) = do
        liftIO $ modifyIORef totalRef (+n)
    begOfEpoch _ _ (DumpThroughputEpoch tt1Ref _ _) =
        liftIO $ getCurrentTime >>= writeIORef tt1Ref
    endOfEpoch _ _ (DumpThroughputEpoch _ tt2Ref _) = do
        liftIO $ getCurrentTime >>= writeIORef tt2Ref
    endOfVal   _ _ (DumpThroughputEpoch tt1Ref tt2Ref totalRef) = do
        tbeg <- readIORef tt1Ref
        tend <- readIORef tt2Ref
        let diff = realToFrac $ diffUTCTime tend tbeg :: Float
        total <- readIORef totalRef
        writeIORef totalRef 0
        lift . logInfo . display $ sformat ("Throughput: " % int % " samples/sec") (floor $ fromIntegral total / diff :: Int)

dumpThroughputEpoch :: IO Callback
dumpThroughputEpoch = do
    t0 <- getCurrentTime
    r0 <- newIORef t0
    r1 <- newIORef t0
    r2 <- newIORef 0
    return $ Callback $ DumpThroughputEpoch r0 r1 r2

-- | Checkpoint
data Checkpoint = Checkpoint FilePath

instance CallbackClass Checkpoint where
    endOfVal i _ (Checkpoint path) = do
        let filename = path </> formatToString ("epoch_" % int) i
        saveState (i == 0) filename
