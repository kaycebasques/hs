module Pong (PongNode (..), pongDepth) where

import {-# SOURCE #-} Ping (PingNode, pingDepth)

newtype PongNode = PongStep PingNode

pongDepth :: PongNode -> Int
pongDepth (PongStep next) = 1 + pingDepth next
