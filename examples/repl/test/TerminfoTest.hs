module Main (main) where

import Control.Monad (unless)
import Data.Maybe (isJust)
import System.Console.Terminfo
  ( getCapability
  , keyUp
  , setupTerm
  , termColors
  , termColumns
  )
import System.Exit (exitFailure)

assert :: String -> Bool -> IO ()
assert label ok =
  unless ok $ do
    putStrLn ("FAIL: " ++ label)
    exitFailure

main :: IO ()
main = do
  xterm <- setupTerm "xterm-256color"
  assert "xterm-256color colors == 256" (getCapability xterm termColors == Just 256)
  assert "xterm-256color keyUp capability" (isJust (getCapability xterm keyUp))

  vt100 <- setupTerm "vt100"
  assert "vt100 columns == 80" (getCapability vt100 termColumns == Just 80)

  dumb <- setupTerm "dumb"
  assert "dumb colors == Nothing" (getCapability dumb termColors == Nothing)
