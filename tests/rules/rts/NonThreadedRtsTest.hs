module Main where

import Control.Concurrent
    ( forkIO
    , newEmptyMVar
    , putMVar
    , rtsSupportsBoundThreads
    , takeMVar
    )
import Control.Monad (unless)
import System.Exit (exitFailure)

assertEq :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEq name expected actual =
    unless (expected == actual) $ do
        putStrLn ("FAIL [" ++ name ++ "]: expected " ++ show expected ++ ", got " ++ show actual)
        exitFailure

main :: IO ()
main = do
    -- 1. Must be linked with GHC's non-threaded RTS (no -threaded).
    assertEq "rtsSupportsBoundThreads" False rtsSupportsBoundThreads

    -- 2. Green threads (forkIO + MVar) still run cooperatively.
    box <- newEmptyMVar
    _ <- forkIO (putMVar box (21 * 2 :: Int))
    val <- takeMVar box
    assertEq "forkIO green thread" 42 val

    putStrLn "NON-THREADED RTS TEST PASSED!"
