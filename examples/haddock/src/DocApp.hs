{-# LANGUAGE OverloadedStrings #-}

-- | Consumer library cross-linking to t'DocCore.Counter' via @haddock_deps@.
module DocApp
  ( renderCounter
  ) where

import Data.Text (Text)
import Data.Text qualified as T
import DocCore (Counter (..), stepCounter)

-- | Step a t'Counter' once and render it as UTF-8 t'Text'.
renderCounter :: Counter -> Text
renderCounter c =
  let Counter next = stepCounter c
   in "count=" <> T.pack (show next)
