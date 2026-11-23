module Main (main) where

import Control.Exception (try)
import Control.Monad (when)
import Data.Bits (shiftR, (.&.))
import qualified Data.ByteString as BS
import Data.Char (chr)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Word (Word8)
import Foreign.C.String (CString, peekCString, withCString)
import Foreign.C.Types (CInt (..), CLong (..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (FunPtr, Ptr, freeHaskellFunPtr, intPtrToPtr, nullPtr, ptrToIntPtr)
import Foreign.Storable (peek)
import System.Console.Terminfo (
    Point,
    SetupTermError,
    Terminal,
    autoRightMargin,
    cursorAddress,
    getCapability,
    keyDown,
    keyLeft,
    keyRight,
    keyUp,
    keypadOn,
    setupTerm,
    setupTermFromEnv,
    termColors,
    termColumns,
 )
import System.Directory (createDirectoryIfMissing)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.Exit (exitFailure)
import System.FilePath ((</>))

foreign import ccall unsafe "setupterm"
    c_setupterm :: CString -> CInt -> Ptr CInt -> IO CInt

foreign import ccall unsafe "set_curterm"
    c_set_curterm :: Ptr () -> IO (Ptr ())

foreign import ccall unsafe "del_curterm"
    c_del_curterm :: Ptr () -> IO CInt

foreign import ccall unsafe "tigetflag"
    c_tigetflag :: CString -> IO CInt

foreign import ccall unsafe "tigetnum"
    c_tigetnum :: CString -> IO CInt

foreign import ccall unsafe "tigetstr"
    c_tigetstr :: CString -> IO CString

foreign import ccall unsafe "tparm"
    c_tparm2 :: CString -> CLong -> CLong -> IO CString

foreign import ccall "wrapper"
    mkPutc :: (CInt -> IO CInt) -> IO (FunPtr (CInt -> IO CInt))

foreign import ccall safe "tputs"
    c_tputs :: CString -> CInt -> FunPtr (CInt -> IO CInt) -> IO CInt

assertEq :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEq label expected actual =
    when (expected /= actual) $ do
        putStrLn ("FAIL [" ++ label ++ "]: expected " ++ show expected ++ ", got " ++ show actual)
        exitFailure

le16 :: Int -> [Word8]
le16 n =
    [ fromIntegral (n .&. 0xFF)
    , fromIntegral ((n `shiftR` 8) .&. 0xFF)
    ]

le32 :: Int -> [Word8]
le32 n =
    [ fromIntegral (n .&. 0xFF)
    , fromIntegral ((n `shiftR` 8) .&. 0xFF)
    , fromIntegral ((n `shiftR` 16) .&. 0xFF)
    , fromIntegral ((n `shiftR` 24) .&. 0xFF)
    ]

-- | Builds a classic 0432 (16-bit numbers) binary term(5) entry for "ruleshs16".
buildClassicTerminfo :: BS.ByteString
buildClassicTerminfo =
    let names = map (fromIntegral . fromEnum) ("ruleshs16|classic 16-bit test\0" :: String)
        bools = [0, 1]
        nums = concatMap le16 [132, 4, 43]
        sBel = "\a\0"
        sClear = "\ESC[2J\0"
        sCup = "\ESC[%i%p1%d;%p2%dR\0"
        strTable = map (fromIntegral . fromEnum) (sBel ++ sClear ++ sCup)
        offBel = 0
        offClear = length sBel
        offCup = length sBel + length sClear
        offs =
            concatMap
                le16
                [ 0xFFFF
                , offBel
                , 0xFFFF
                , 0xFFFF
                , 0xFFFF
                , offClear
                , 0xFFFF
                , 0xFFFF
                , 0xFFFF
                , 0xFFFF
                , offCup
                ]
        hdr =
            concatMap
                le16
                [ 0o432
                , length names
                , length bools
                , 3
                , 11
                , length strTable
                ]
     in BS.pack (hdr ++ names ++ bools ++ nums ++ offs ++ strTable)

-- | Builds an ncurses6 01036 (32-bit numbers + extended caps) binary term(5) entry for "ruleshs32".
buildExtendedTerminfo :: BS.ByteString
buildExtendedTerminfo =
    let names = map (fromIntegral . fromEnum) ("ruleshs32|32-bit extended\0" :: String)
        bools = [0, 1]
        numVals = [100, 8, 50] ++ replicate 10 (-1) ++ [16777216, 65536]
        nums = concatMap le32 numVals
        sBel = "\a\0"
        strTable = map (fromIntegral . fromEnum) sBel
        offs = concatMap le16 [0xFFFF, 0]
        hdr =
            concatMap
                le16
                [ 0o1036
                , length names
                , length bools
                , length numVals
                , 2
                , length strTable
                ]
        baseBytes = hdr ++ names ++ bools ++ nums ++ offs ++ strTable
        alignPad = [0 | odd (length baseBytes)]
        extBools = [1, 0]
        extNums = le32 99999
        extValSs = "\ESC[%p1%d q\0"
        extNameTc = "Tc\0"
        extNameCO = "CO\0"
        extNameSs = "Ss\0"
        extStrTable = map (fromIntegral . fromEnum) (extValSs ++ extNameTc ++ extNameCO ++ extNameSs)
        extOffs =
            concatMap
                le16
                [ 0
                , 0
                , length extNameTc
                , length extNameTc + length extNameCO
                ]
        extHdr =
            concatMap
                le16
                [ 1
                , 1
                , 1
                , 4
                , length extStrTable
                ]
     in BS.pack (baseBytes ++ alignPad ++ extHdr ++ extBools ++ extNums ++ extOffs ++ extStrTable)

appendPutc :: IORef [Char] -> CInt -> IO CInt
appendPutc ref c = do
    modifyIORef' ref (chr (fromIntegral c .&. 0xFF) :)
    pure c

main :: IO ()
main = do
    -- 1. Headless / sandbox behavior:
    --    - C setupterm(NULL, -1, &errret) with TERM unset returns -1 (*errret == -1).
    --    - Haskell setupTerm "" raises SetupTermError.
    --    - Haskell setupTermFromEnv with TERM unset falls back to "dumb" (no cursor movement).
    unsetEnv "TERM"
    unsetEnv "COLUMNS"
    unsetEnv "LINES"
    setEnv "TERMINFO" "/nonexistent_rules_hs_ti"
    setEnv "TERMINFO_DIRS" "/nonexistent_rules_hs_ti"
    setEnv "HOME" "/nonexistent_rules_hs_home"

    alloca $ \errPtr -> do
        rcNull <- c_setupterm nullPtr (-1) errPtr
        errNull <- peek errPtr
        assertEq "c_setupterm NULL when TERM unset rc" (-1) rcNull
        assertEq "c_setupterm NULL when TERM unset errret" (-1) errNull

    rEmpty <- try (setupTerm "") :: IO (Either SetupTermError Terminal)
    case rEmpty of
        Left _ -> pure ()
        Right _ -> do
            putStrLn "FAIL: setupTerm \"\" must fail with SetupTermError"
            exitFailure

    tEnvDumb <- setupTermFromEnv
    assertEq "headless setupTermFromEnv -> dumb cols" (Just 80) (getCapability tEnvDumb termColumns)

    -- 2. Unknown terminal type -> SetupTermError.
    rUnknown <- try (setupTerm "completely-unknown-terminal-xyz") :: IO (Either SetupTermError Terminal)
    case rUnknown of
        Left _ -> pure ()
        Right _ -> do
            putStrLn "FAIL: setupTerm on unknown terminal must raise SetupTermError"
            exitFailure

    -- 3. Built-in 'dumb' fallback when no /usr/share/terminfo exists.
    tDumb <- setupTerm "dumb"
    assertEq "dumb am" (Just True) (getCapability tDumb autoRightMargin)
    assertEq "dumb cols" (Just 80) (getCapability tDumb termColumns)
    case (getCapability tDumb cursorAddress :: Maybe (Point -> String)) of
        Nothing -> pure ()
        Just _ -> do
            putStrLn "FAIL: dumb terminal must not report cursorAddress"
            exitFailure

    -- 4. Built-in 'xterm-256color' fallback when no /usr/share/terminfo exists.
    tXterm <- setupTerm "xterm-256color"
    assertEq "xterm-256color termColors" (Just 256) (getCapability tXterm termColors)
    assertEq "xterm-256color keyUp" (Just "\ESCOA") (getCapability tXterm keyUp)
    assertEq "xterm-256color keyDown" (Just "\ESCOB") (getCapability tXterm keyDown)
    assertEq "xterm-256color keyRight" (Just "\ESCOC") (getCapability tXterm keyRight)
    assertEq "xterm-256color keyLeft" (Just "\ESCOD") (getCapability tXterm keyLeft)
    assertEq "xterm-256color keypadOn" (Just "\ESC[?1h\ESC=") (getCapability tXterm keypadOn)

    -- Verify tparm (%i 1-based cup and nested %? ... %t ... %e ... %; 256-color setaf) & tputs padding removal.
    alloca $ \errPtr -> do
        rc <- withCString "xterm-256color" $ \cTerm -> c_setupterm cTerm (-1) errPtr
        errVal <- peek errPtr
        assertEq "c_setupterm rc" 0 rc
        assertEq "c_setupterm errret" 1 errVal

        cupCap <- withCString "cup" c_tigetstr
        cupFormatted <- c_tparm2 cupCap 4 9 >>= peekCString
        assertEq "tparm cup (4,9)" "\ESC[5;10H" cupFormatted

        setafCap <- withCString "setaf" c_tigetstr
        c2 <- c_tparm2 setafCap 2 0 >>= peekCString
        c10 <- c_tparm2 setafCap 10 0 >>= peekCString
        c208 <- c_tparm2 setafCap 208 0 >>= peekCString
        assertEq "tparm setaf 2 (ANSI green)" "\ESC[32m" c2
        assertEq "tparm setaf 10 (bright green)" "\ESC[92m" c10
        assertEq "tparm setaf 208 (256-color)" "\ESC[38;5;208m" c208

        unrecFlag <- withCString "not_a_bool" c_tigetflag
        assertEq "tigetflag unrecognized" (-1) unrecFlag
        unrecNum <- withCString "not_a_num" c_tigetnum
        assertEq "tigetnum unrecognized" (-2) unrecNum
        unrecStr <- withCString "not_a_str" c_tigetstr
        assertEq "tigetstr unrecognized (-1)" (intPtrToPtr (-1)) (intPtrToPtr (ptrToIntPtr unrecStr))

        flashCap <- withCString "flash" c_tigetstr
        sinkRef <- newIORef []
        cb <- mkPutc (appendPutc sinkRef)
        tpRc <- c_tputs flashCap 1 cb
        freeHaskellFunPtr cb
        assertEq "tputs rc" 0 tpRc
        flashed <- reverse <$> readIORef sinkRef
        assertEq "tputs flash stripped delay" "\ESC[?5h\ESC[?5l" flashed

        curPtr <- c_set_curterm nullPtr
        delRc <- c_del_curterm curPtr
        assertEq "del_curterm rc" 0 delRc

    -- 5. Real compiled binary term(5) files on disk: classic 0432 (16-bit) & extended 01036 (32-bit).
    tmpBase <- maybe "/tmp" id <$> lookupEnv "TEST_TMPDIR"
    let tiDir = tmpBase </> "rules_hs_ti_db"
    createDirectoryIfMissing True (tiDir </> "r")
    BS.writeFile (tiDir </> "r" </> "ruleshs16") buildClassicTerminfo
    BS.writeFile (tiDir </> "r" </> "ruleshs32") buildExtendedTerminfo
    setEnv "TERMINFO" tiDir

    t16 <- setupTerm "ruleshs16"
    assertEq "ruleshs16 am" (Just True) (getCapability t16 autoRightMargin)
    assertEq "ruleshs16 cols" (Just 132) (getCapability t16 termColumns)

    alloca $ \errPtr -> do
        rc32 <- withCString "ruleshs32" $ \cTerm -> c_setupterm cTerm (-1) errPtr
        assertEq "ruleshs32 setupterm rc" 0 rc32
        cols32 <- withCString "cols" c_tigetnum
        colors32 <- withCString "colors" c_tigetnum
        extTc <- withCString "Tc" c_tigetflag
        extCo <- withCString "CO" c_tigetnum
        extSsPtr <- withCString "Ss" c_tigetstr
        extSsFormatted <- c_tparm2 extSsPtr 6 0 >>= peekCString
        assertEq "ruleshs32 cols" 100 cols32
        assertEq "ruleshs32 32-bit colors" 16777216 colors32
        assertEq "ruleshs32 ext bool Tc" 1 extTc
        assertEq "ruleshs32 ext num CO" 99999 extCo
        assertEq "ruleshs32 ext str Ss" "\ESC[6 q" extSsFormatted
        curPtr <- c_set_curterm nullPtr
        _ <- c_del_curterm curPtr
        pure ()

    putStrLn "TERMINFO ENGINE TEST PASSED!"
