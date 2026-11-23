module Main (main) where

import Control.Monad (unless)
import Ping (PingNode (..), pingDepth)
import Pong (PongNode (..))
import System.Exit (exitFailure)

main :: IO ()
main = do
  let chain = PingStep (PongStep (PingStep (PongStep PingEnd)))
  unless (pingDepth chain == 4) exitFailure
