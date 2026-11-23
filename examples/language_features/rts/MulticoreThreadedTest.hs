module Main (main) where

import Control.Concurrent (forkOS, getNumCapabilities, newEmptyMVar, putMVar, rtsSupportsBoundThreads, takeMVar)
import Control.Concurrent.STM (atomically, modifyTVar', newTVarIO, readTVarIO)
import Control.Monad (replicateM, unless)
import System.Exit (exitFailure)

main :: IO ()
main = do
  unless rtsSupportsBoundThreads $ do
    putStrLn "Expected rtsSupportsBoundThreads == True when threaded = True"
    exitFailure
  caps <- getNumCapabilities
  unless (caps == 2) $ do
    putStrLn ("Expected -with-rtsopts=-N2 capabilities, got " <> show caps)
    exitFailure

  counter <- newTVarIO (0 :: Int)
  dones <- replicateM 4 $ do
    done <- newEmptyMVar
    _ <- forkOS $ do
      atomically (modifyTVar' counter (+ 10))
      putMVar done ()
    pure done
  mapM_ takeMVar dones
  total <- readTVarIO counter
  unless (total == 40) exitFailure
