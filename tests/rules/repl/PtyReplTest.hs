module Main (main) where

import Control.Concurrent (threadDelay, threadWaitRead)
import Control.Exception (SomeException, try)
import Control.Monad (unless, void, when)
import Data.Char (isAlpha, isDigit)
import Data.List (isInfixOf)
import Foreign.C.Types (CInt (..))
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.C.String (peekCStringLen, withCStringLen)
import Foreign.Ptr (castPtr, plusPtr)
import System.Directory (canonicalizePath, createDirectoryIfMissing)
import System.Environment (getArgs, getEnvironment, lookupEnv)
import System.Exit (ExitCode (..), die)
import System.FilePath ((</>))
import System.Posix.IO (
    closeFd,
    dupTo,
    fdReadBuf,
    fdWriteBuf,
    stdError,
    stdInput,
    stdOutput,
 )
import System.Posix.Process (
    ProcessStatus (..),
    createSession,
    executeFile,
    forkProcess,
    getProcessStatus,
 )
import System.Posix.Terminal (openPseudoTerminal)
import System.Posix.Types (Fd (..), ProcessID)
import System.Timeout (timeout)

foreign import ccall unsafe "rules_haskell_set_controlling_tty"
    c_set_controlling_tty :: CInt -> IO CInt

-- | Strips ANSI CSI / OSC / charset terminal control sequences so assertions match clean text.
stripAnsi :: String -> String
stripAnsi [] = []
stripAnsi ('\ESC' : '[' : rest) = stripAnsi (dropCsi rest)
  where
    dropCsi [] = []
    dropCsi (c : cs)
        | c >= '@' && c <= '~' = cs
        | otherwise = dropCsi cs
stripAnsi ('\ESC' : ']' : rest) = stripAnsi (dropOsc rest)
  where
    dropOsc [] = []
    dropOsc ('\a' : cs) = cs
    dropOsc ('\ESC' : '\\' : cs) = cs
    dropOsc (_ : cs) = dropOsc cs
stripAnsi ('\ESC' : '(' : _ : rest) = stripAnsi rest
stripAnsi ('\ESC' : _ : rest) = stripAnsi rest
stripAnsi ('\r' : rest) = stripAnsi rest
stripAnsi (c : rest)
    | c == '\n' || c == '\t' || (c >= ' ' && c <= '~') || isAlpha c || isDigit c =
        c : stripAnsi rest
    | otherwise = stripAnsi rest

writePty :: Fd -> String -> IO ()
writePty fd s =
    withCStringLen s $ \(ptr, len) ->
        let go off =
                when (off < len) $ do
                    n <- fdWriteBuf fd (castPtr (ptr `plusPtr` off)) (fromIntegral (len - off))
                    go (off + fromIntegral n)
         in go 0

readUntil :: String -> Fd -> String -> Int -> IO String
readUntil label fd needle timeoutMicros = do
    res <- timeout timeoutMicros (loop "")
    case res of
        Just collected -> pure collected
        Nothing -> die ("PTY timeout waiting for " ++ show needle ++ " in step [" ++ label ++ "]")
  where
    loop acc = do
        threadWaitRead fd
        chunkE <- try $ allocaBytes 4096 $ \buf -> do
            n <- fdReadBuf fd buf 4096
            if n == 0
                then pure ""
                else peekCStringLen (castPtr buf, fromIntegral n)
        case chunkE :: Either SomeException String of
            Left _ ->
                if needle `isInfixOf` stripAnsi acc
                    then pure (stripAnsi acc)
                    else die ("PTY closed early in [" ++ label ++ "]; output so far:\n" ++ stripAnsi acc)
            Right chunk -> do
                let acc' = acc ++ chunk
                    cleaned = stripAnsi acc'
                if needle `isInfixOf` cleaned
                    then pure cleaned
                    else loop acc'

spawnPtyRepl :: FilePath -> [(String, String)] -> IO (Fd, ProcessID)
spawnPtyRepl bin extraEnv = do
    absBin <- canonicalizePath bin
    baseEnv <- getEnvironment
    tmpBase <- maybe "/tmp" id <$> lookupEnv "TEST_TMPDIR"
    let homeDir = tmpBase </> "pty_home"
    createDirectoryIfMissing True homeDir
    let filtered =
            [ (k, v)
            | (k, v) <- baseEnv
            , k `notElem` (["TERM", "TERMINFO", "TERMINFO_DIRS", "HOME"] ++ map fst extraEnv)
            ]
        finalEnv =
            [ ("TERM", "xterm-256color")
            , ("TERMINFO", "/nonexistent_rules_haskell_ti")
            , ("TERMINFO_DIRS", "/nonexistent_rules_haskell_ti")
            , ("HOME", homeDir)
            ]
                ++ extraEnv
                ++ filtered

    (masterFd, slaveFd) <- openPseudoTerminal
    pid <- forkProcess $ do
        closeFd masterFd
        void createSession
        let Fd sRaw = slaveFd
        void (c_set_controlling_tty sRaw)
        void (dupTo slaveFd stdInput)
        void (dupTo slaveFd stdOutput)
        void (dupTo slaveFd stdError)
        when (slaveFd > stdError) (closeFd slaveFd)
        executeFile absBin False [] (Just finalEnv)
    closeFd slaveFd
    pure (masterFd, pid)

waitCleanExit :: String -> Fd -> ProcessID -> IO ()
waitCleanExit label masterFd pid = do
    status <- getProcessStatus True False pid
    closeFd masterFd
    case status of
        Just (Exited ExitSuccess) -> pure ()
        other -> die ("FAIL [" ++ label ++ "]: expected ExitSuccess, got " ++ show other)

main :: IO ()
main = do
    args <- getArgs
    (mainReplBin, liveReplBin) <- case args of
        (b1 : b2 : _) -> pure (b1, b2)
        _ -> die "Usage: pty_repl_test <main_repl_bin> <live_reload_repl_bin>"

    putStrLn "=== 1. Interactive PTY session: multi-module scope, arrow-key history, Tab completion, Ctrl-C, :break ==="
    (fd1, pid1) <- spawnPtyRepl mainReplBin []
    _ <- readUntil "initial prompt" fd1 "ghci>" 30000000

    -- 1a. Multi-module *Module scope: exported, CApiFFI C call, hidden_modules, unexported binding, and .lhs!
    writePty fd1 "(betaCombined 10, cMacroConst, alphaInternalSecret, hiddenBonus, literateDouble 21)\r"
    out1 <- readUntil "multi-module eval" fd1 "ghci>" 15000000
    -- alphaExported 10 = 310; hiddenBonus = 17; repl_c_scale(10,3) = 49 -> 376
    unless ("(376,19,300,17,42)" `isInfixOf` out1) $
        die ("Expected '(376,19,300,17,42)' in PTY output, got:\n" ++ out1)

    -- 1b. Interactive haskeline history + line editing:
    --     Evaluate `100 + 23` (= 123), then send Up-Arrow (\ESC[A), Backspace (\DEL), '9', Enter -> `100 + 29` (= 129)!
    writePty fd1 "100 + 23\r"
    outHist1 <- readUntil "history seed" fd1 "ghci>" 15000000
    unless ("123" `isInfixOf` outHist1) $
        die ("Expected '123' in history seed output, got:\n" ++ outHist1)

    writePty fd1 "\ESC[A\DEL9\r"
    outHist2 <- readUntil "up-arrow edited eval" fd1 "ghci>" 15000000
    unless ("129" `isInfixOf` outHist2) $
        die ("Expected '129' after Up-Arrow + Backspace + '9', got:\n" ++ outHist2)

    -- 1c. Interactive Tab completion (\t): `replUniqueCompletionSym\t 7` -> `replUniqueCompletionSymbol 7` (= 77)
    writePty fd1 "replUniqueCompletionSym\t 7\r"
    outTab <- readUntil "tab completion" fd1 "ghci>" 15000000
    unless ("77" `isInfixOf` outTab) $
        die ("Expected '77' from Tab-completed replUniqueCompletionSymbol, got:\n" ++ outTab)

    -- 1d. Interactive Ctrl-C (SIGINT via \ETX on controlling TTY) interrupting an infinite calculation!
    writePty fd1 "sum [1 :: Integer ..]\r"
    threadDelay 250000 -- 250 ms so evaluation is actively running
    writePty fd1 "\ETX"
    outInt <- readUntil "Ctrl-C Interrupted" fd1 "Interrupted." 15000000
    unless ("Interrupted." `isInfixOf` outInt) $
        die ("Expected 'Interrupted.' on Ctrl-C, got:\n" ++ outInt)
    unless ("ghci>" `isInfixOf` outInt) $
        void (readUntil "post-Ctrl-C prompt" fd1 "ghci>" 15000000)

    -- Ensure ghci prompt recovers cleanly after Interrupted.
    writePty fd1 "(6 * 7 :: Int)\r"
    outAfterInt <- readUntil "post-Ctrl-C recovery" fd1 "ghci>" 15000000
    unless ("42" `isInfixOf` outAfterInt) $
        die ("Expected '42' after Ctrl-C recovery, got:\n" ++ outAfterInt)

    -- 1e. Interactive GHCi bytecode debugger (:break + :continue)
    writePty fd1 ":break replDebugTarget\r"
    outBrkSet <- readUntil "set breakpoint" fd1 "ghci>" 15000000
    unless ("Breakpoint" `isInfixOf` outBrkSet) $
        die ("Expected 'Breakpoint' confirmation, got:\n" ++ outBrkSet)

    writePty fd1 "replDebugTarget 21\r"
    outStopped <- readUntil "hit breakpoint" fd1 "ghci>" 15000000
    unless ("Stopped in" `isInfixOf` outStopped && "replDebugTarget" `isInfixOf` outStopped) $
        die ("Expected Stopped in replDebugTarget, got:\n" ++ outStopped)

    writePty fd1 ":continue\r"
    outCont <- readUntil "continue from breakpoint" fd1 "ghci>" 15000000
    unless ("42" `isInfixOf` outCont) $
        die ("Expected '42' after :continue, got:\n" ++ outCont)

    writePty fd1 ":quit\r"
    waitCleanExit "session 1" fd1 pid1
    putStrLn "OK: PTY history editing, Tab completion, Ctrl-C recovery, CApiFFI, .lhs, and :break/:continue verified!"

    putStrLn "=== 2. Interactive PTY live workspace :reload test ==="
    tmpBase <- maybe "/tmp" id <$> lookupEnv "TEST_TMPDIR"
    let fakeWs = tmpBase </> "live_ws"
        modDir = fakeWs </> "tests/rules/repl"
        modFile = modDir </> "LiveReloadMod.hs"
    createDirectoryIfMissing True modDir
    writeFile
        modFile
        ( unlines
            [ "module LiveReloadMod (liveReloadBanner) where"
            , "liveReloadBanner :: String"
            , "liveReloadBanner = \"v1-initial\""
            ]
        )

    (fd2, pid2) <- spawnPtyRepl liveReplBin [("BUILD_WORKSPACE_DIRECTORY", fakeWs)]
    _ <- readUntil "live initial prompt" fd2 "ghci>" 30000000

    writePty fd2 "liveReloadBanner\r"
    outV1 <- readUntil "live v1 eval" fd2 "v1-initial" 15000000
    unless ("v1-initial" `isInfixOf` outV1) $
        die ("Expected 'v1-initial', got:\n" ++ outV1)

    -- Modify LiveReloadMod.hs in-place inside BUILD_WORKSPACE_DIRECTORY and trigger :reload!
    threadDelay 100000
    writeFile
        modFile
        ( unlines
            [ "module LiveReloadMod (liveReloadBanner, liveAddedFn) where"
            , "liveReloadBanner :: String"
            , "liveReloadBanner = \"v2-reloaded\""
            , "liveAddedFn :: Int -> Int"
            , "liveAddedFn n = n + 900"
            ]
        )

    writePty fd2 ":reload\r"
    _ <- readUntil "live :reload" fd2 "ghci>" 15000000

    writePty fd2 "(liveReloadBanner, liveAddedFn 99)\r"
    outV2 <- readUntil "live v2 eval" fd2 "(\"v2-reloaded\",999)" 15000000
    unless ("(\"v2-reloaded\",999)" `isInfixOf` outV2) $
        die ("Expected '(\"v2-reloaded\",999)' after :reload, got:\n" ++ outV2)

    writePty fd2 ":quit\r"
    waitCleanExit "session 2 (:reload)" fd2 pid2
    putStrLn "OK: live workspace :reload picked up edited module and newly added function!"
    putStrLn "INTERACTIVE PTY REPL TEST PASSED!"
