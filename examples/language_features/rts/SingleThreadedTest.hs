module Main (main) where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, rtsSupportsBoundThreads, takeMVar)
import Control.Monad (unless)
import System.Exit (exitFailure)

main :: IO ()
main = do
  unless (not rtsSupportsBoundThreads) $ do
    putStrLn "Expected rtsSupportsBoundThreads == False when threaded = False"
    exitFailure
  box <- newEmptyMVar
  _ <- forkIO (putMVar box (42 :: Int))
  val <- takeMVar box
  unless (val == 42) exitFailure
