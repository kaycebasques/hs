module Main where

import Control.Concurrent
    ( forkIO
    , forkOS
    , getNumCapabilities
    , newEmptyMVar
    , putMVar
    , rtsSupportsBoundThreads
    , takeMVar
    )
import Control.Concurrent.STM (atomically, modifyTVar', newTVarIO, readTVar, retry)
import Control.Monad (forM_, unless)
import System.Exit (exitFailure)

assertEq :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEq name expected actual =
    unless (expected == actual) $ do
        putStrLn ("FAIL [" ++ name ++ "]: expected " ++ show expected ++ ", got " ++ show actual)
        exitFailure

main :: IO ()
main = do
    -- 1. Must be linked with GHC's threaded RTS (-threaded).
    assertEq "rtsSupportsBoundThreads" True rtsSupportsBoundThreads

    -- 2. Verify at least 1 capability is active.
    caps <- getNumCapabilities
    unless (caps >= 1) $ do
        putStrLn ("FAIL [getNumCapabilities]: expected >= 1, got " ++ show caps)
        exitFailure

    -- 3. forkOS only works when linked with the threaded RTS (fails otherwise).
    osBox <- newEmptyMVar
    _ <- forkOS (putMVar osBox ("bound-os-thread-ok" :: String))
    osRes <- takeMVar osBox
    assertEq "forkOS roundtrip" "bound-os-thread-ok" osRes

    -- 4. Multi-thread STM counter coordination across 8 forkIO workers.
    counter <- newTVarIO (0 :: Int)
    done <- newTVarIO (0 :: Int)
    let workers = 8 :: Int
        incrementsPerWorker = 100 :: Int
    forM_ [1 .. workers] $ \_ ->
        forkIO $ do
            forM_ [1 .. incrementsPerWorker] $ \_ ->
                atomically (modifyTVar' counter (+ 1))
            atomically (modifyTVar' done (+ 1))

    finalTotal <- atomically $ do
        finished <- readTVar done
        if finished < workers
            then retry
            else readTVar counter
    assertEq "STM parallel counter" (workers * incrementsPerWorker) finalTotal

    putStrLn "THREADED RTS TEST PASSED!"
