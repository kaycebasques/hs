module Ping (PingNode (..), pingDepth) where

import Pong (PongNode, pongDepth)

data PingNode = PingEnd | PingStep PongNode

pingDepth :: PingNode -> Int
pingDepth PingEnd = 0
pingDepth (PingStep p) = 1 + pongDepth p
