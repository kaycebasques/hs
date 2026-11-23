{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE TemplateHaskellQuotes #-}

module ThCrossLibBase
    ( mkCrossLibTripledExp
    , tripleViaC
    ) where

import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt (..), CSize (..))
import Language.Haskell.TH (Exp, Q, integerL, litE, runIO)

foreign import capi "th_c_helper.h th_c_triple"
    c_triple :: CInt -> CInt

foreign import ccall unsafe "string.h strlen"
    c_strlen :: CString -> IO CSize

tripleViaC :: Int -> Int
tripleViaC x = fromIntegral (c_triple (fromIntegral x))

-- | Compile-time TH splice helper invoking both package C sources (CApiFFI)
-- and runIO + libc FFI across library boundaries.
mkCrossLibTripledExp :: Int -> Q Exp
mkCrossLibTripledExp n = do
    tagLen <- runIO $ withCString "rules_haskell" (fmap fromIntegral . c_strlen)
    let computed = tripleViaC n + (tagLen - 13)
    litE (integerL (fromIntegral computed))
