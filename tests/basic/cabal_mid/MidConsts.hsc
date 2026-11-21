{-# LANGUAGE ForeignFunctionInterface #-}
module MidConsts (clibMagic, testFlag, ghcIntVersion, ucredSize) where

-- Regression test for #24: _GNU_SOURCE after template-hsc.h must expose struct ucred
-- (requires -nostdinc++ in cc_wrapper) and __GLASGOW_HASKELL__/linux_HOST_OS defines.
#define _GNU_SOURCE 1
#include <sys/socket.h>
#include <clib.h>

clibMagic :: Int
clibMagic = #const CLIB_MAGIC

testFlag :: Int
testFlag = #const CABAL_TEST_FLAG

ghcIntVersion :: Int
#if defined(__GLASGOW_HASKELL__) && defined(linux_HOST_OS)
ghcIntVersion = #const __GLASGOW_HASKELL__
#else
#error "Missing __GLASGOW_HASKELL__ or linux_HOST_OS define in hsc2hs!"
#endif

ucredSize :: Int
ucredSize = #size struct ucred
