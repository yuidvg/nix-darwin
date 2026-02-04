{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module      : Main
-- Description : generic tar-map utility (Parallel)
-- Copyright   : (c) Yui Nishimura, 2024
-- License     : MIT
--
-- The "Silver Bullet" Abstraction (Concurrent):
--   tar-map :: (File -> IO [File]) -> TarStream -> TarStream
--
-- Features:
--   - Arbitrary Shell Command Mapping
--   - Parallel Execution (--jobs)
--   - Independent Sandboxing
--   - Stream Processing (Constant Memory for Stream, O(N) threads)

module Main where

import Protolude hiding (bracket, try, catch, wait, cancel, async)
import qualified Data.Text as T
import qualified Data.ByteString.Lazy as BL
import System.IO (hSetBinaryMode, hSetBuffering, BufferMode(..), Handle, hFlush)
import System.Process (proc, createProcess, waitForProcess, std_in, std_out, std_err, StdStream(..), CreateProcess(..), ProcessHandle, withCreateProcess)
import System.Directory (createDirectoryIfMissing, removeDirectoryRecursive, listDirectory, getTemporaryDirectory, doesFileExist, copyFile)
import System.FilePath ((</>), takeDirectory, takeFileName)
import qualified Codec.Archive.Tar as Tar
import qualified Codec.Archive.Tar.Entry as Tar
import Options.Applicative
import Control.Exception.Safe (bracket, tryAny, throwString)
import Data.Time (getCurrentTime, diffUTCTime, UTCTime(..))
import Data.Time (getCurrentTime, diffUTCTime, UTCTime(..))
import Data.Time.Calendar (Day(..))
import Control.Concurrent.Async (mapConcurrently, async, wait, forConcurrently)
import Control.Concurrent.STM (atomically, newTChanIO, writeTChan, readTChan, TChan, TVar, newTVarIO, readTVar, modifyTVar, check)
import Control.Concurrent (setNumCapabilities, getNumCapabilities, myThreadId)
import GHC.Conc (numCapabilities)
import qualified Control.Concurrent.QSem as QSem
import System.Timeout (timeout)
import Control.Concurrent.MVar (newMVar, withMVar, MVar)


-- | Configuration
data Config = Config
  { cmdTemplate :: [[Char]]
  , keepOriginal :: Bool
  , jobs :: Int
  , timeoutSec :: Int
  }

-- | CLI Parser
configParser :: Parser Config
configParser = Config
  <$> many (strArgument (metavar "COMMAND_AND_ARGS..."))
  <*> switch (long "keep-structure" <> help "Maintain original directory structure for output files")
  <*> option auto
      ( long "jobs"
     <> short 'j'
     <> metavar "N"
     <> help "Number of parallel jobs"
     <> value 4 )
  <*> option auto
      ( long "timeout"
     <> metavar "SECONDS"
     <> help "Timeout per file in seconds"
     <> value 180 )

-- | Main
main :: IO ()
main = do
  hSetBinaryMode stdin True
  hSetBinaryMode stdout True
  hSetBuffering stdout NoBuffering

  config <- execParser opts

  -- Set capabilities (threads)
  -- In Haskell, default is -N (all cores) if compiled threaded, but we can't control RTS flags easily in script.
  -- But 'async' uses lightweight threads so it's fine.

  content <- BL.hGetContents stdin
  let entries = Tar.read content

  processEntriesParallel config entries

  where
    opts = info (configParser <**> helper)
      ( fullDesc
     <> progDesc "Apply a command to each file in a tar stream, emitting resulting files"
     <> header "tar-map - The Monadic Bind for Filesystem Streams (Parallel)" )

-- | Parallel Processing Logic
-- Strategy:
--  1. Main thread iterates input Tar entries.
--  2. "Standard Files" are dispatched to a worker pool (or semaphore controlled async).
--  3. "Other Entries" (Dirs, Links) are passed through (?) or ignored?
--       Typically `tar-map` should map file content. Directories are implicit in tar usually.
--       Let's ignore directories for processing but maybe pass them through if we were a true filter?
--       Current logic: Only process NormalFile. Drop others?
--       Ideally: Pass through non-files directly to stdout. Process files.
--       But this causes out-of-order output if we are not careful.
--       Simple version: Only emit PROCESSED files. (Filter style).
--       Input dirs are ignored. Output dirs are synthesized by `Tar.pack` or file paths.
--
processEntriesParallel :: Config -> Tar.Entries Tar.FormatError -> IO ()
processEntriesParallel config entries = do
  -- Output Lock (Stdout is not thread safe for interleaved byte writes)
  outLock <- newMVar ()

  -- Semaphore for parallelism
  sem <- QSem.newQSem (jobs config)

  -- We use a simple Async group.
  -- We don't want to load ALL entries into memory.
  -- `Tar.read` is lazy.
  -- We'll use a recursive loop that forks threads.

  let loop Tar.Done = return ()
      loop (Tar.Fail e) = withMVar outLock $ \_ -> logInfo $ "[tar-map] Tar Error: " <> T.pack (show e :: [Char])
      loop (Tar.Next entry next) = do
         case Tar.entryContent entry of
           Tar.NormalFile _ _ -> do
              -- Wait for slot
              QSem.waitQSem sem

              -- Fork worker
              _ <- async $ do
                 result <- tryAny $ processSingleEntry config entry

                 -- Release slot immediately after processing logic finishes
                 -- (Outputting might take valid time but we release CPU slot)
                 QSem.signalQSem sem

                 case result of
                   Right newEntries ->
                      withMVar outLock $ \_ ->
                         mapM_ (\e -> BL.hPut stdout (Tar.write [e])) newEntries
                   Left e ->
                      withMVar outLock $ \_ ->
                         logInfo $ "Error processing " <> T.pack (Tar.entryPath entry) <> ": " <> show e

              loop next

           _ -> do
             -- Pass through or Ignore?
             -- If we pass through, we might have collisions or out of order.
             -- Current spec: Process files.
             -- Let's just ignore non-files for "map" (files -> files).
             loop next

  loop entries

  -- Wait for all jobs to finish?
  -- The simple `async` above creates "fire and forget" threads.
  -- Main thread will exit `loop` when tar is done.
  -- But workers might still be running!
  -- We need to wait.

  -- Proper Barrier:
  -- Incremented counter? Or just use a dependency like `async`'s `forConcurrently` if we could stream.
  -- Since we handle stream manually, we need a WaitGroup.
  -- QSem is not enough for waiting completion.

  -- Simple WaitGroup: output "running count" MVar?
  -- Let's implement active counter.

  active <- newTVarIO (0 :: Int)

  let loop2 Tar.Done = return ()
      loop2 (Tar.Fail e) = withMVar outLock $ \_ -> logInfo $ "[tar-map] Tar Error: " <> T.pack (show e :: [Char])
      loop2 (Tar.Next entry next) = do
         case Tar.entryContent entry of
           Tar.NormalFile _ _ -> do
              QSem.waitQSem sem
              atomically $ modifyTVar active (+1)

              _ <- async $ do
                 _ <- tryAny $ do
                     res <- processSingleEntry config entry
                     withMVar outLock $ \_ -> mapM_ (\e -> BL.hPut stdout (Tar.write [e])) res

                 QSem.signalQSem sem
                 atomically $ modifyTVar active (subtract 1)

              loop2 next
           _ -> loop2 next

  loop2 entries

  -- Drain
  atomically $ do
    n <- readTVar active
    check (n == 0)

processSingleEntry :: Config -> Tar.Entry -> IO [Tar.Entry]
processSingleEntry config entry = do
  let path = Tar.entryPath entry
      content = case Tar.entryContent entry of
                  Tar.NormalFile c _ -> c
                  _ -> BL.empty

  logInfo $ "Processing: " <> T.pack path

  withSystemTempDirectory "tm" $ \tmpDir -> do
      let workPath = tmpDir </> path
      createDirectoryIfMissing True (takeDirectory workPath)
      BL.writeFile workPath content

      let dir = takeDirectory workPath
          file = takeFileName workPath
          cmdArgs = map (replacePlaceholder file) (cmdTemplate config)
          (cmd:args) = if null (cmdTemplate config) then ["echo", file] else cmdArgs

      -- Run with Timeout
      let runCmd = withCreateProcess ((proc cmd args) { cwd = Just dir, std_in = Inherit, std_out = Inherit, std_err = Inherit }) $ \_ _ _ ph -> waitForProcess ph

      exitCode <- timeout (timeoutSec config * 1000000) runCmd

      case exitCode of
        Nothing -> throwString "Timeout"
        Just _ -> do
           -- Collect results
           subFiles <- listDirectoryRecursive dir
           forM subFiles $ \subPath -> do
              let fullSubPath = dir </> subPath
              isFile <- doesFileExist fullSubPath
              if isFile
                then do
                   let entryName = (takeDirectory path) </> subPath
                   c <- BL.readFile fullSubPath
                   case Tar.toTarPath False entryName of
                     Right tp -> return (Just $ Tar.fileEntry tp c)
                     Left _ -> return Nothing
                else return Nothing
           >>= return . catMaybes

  where
    replacePlaceholder f template =
        let f' = T.pack f
            t' = T.pack template
        in T.unpack (T.replace "{}" f' t')

-- | Recursive list
listDirectoryRecursive :: FilePath -> IO [FilePath]
listDirectoryRecursive dir = do
  names <- listDirectory dir
  paths <- forM names $ \name -> do
    let path = dir </> name
    isDirectory <- doesFileExist path >>= \case
        True -> return False
        False -> return True
    if isDirectory
      then do
          subs <- listDirectoryRecursive path
          return $ map (name </>) subs
      else return [name]
  return $ concat paths

withSystemTempDirectory :: FilePath -> (FilePath -> IO a) -> IO a
withSystemTempDirectory template action = do
  sysTmp <- getTemporaryDirectory
  let dir = sysTmp </> template
  now <- getCurrentTime
  tid <- myThreadId
  let t = diffUTCTime now (UTCTime (ModifiedJulianDay 0) 0)
      tStr = show t :: Text
      tidStr = show tid :: Text
      -- Use tid to ensure uniqueness across threads
      runDir = dir <> "-" <> (take 10 $ T.unpack tStr) <> "-" <> (filter (/= ' ') $ T.unpack tidStr)
  bracket
    (createDirectoryIfMissing True runDir >> return runDir)
    (\d -> tryAny (removeDirectoryRecursive d) >> return ())
    action

logInfo :: Text -> IO ()
logInfo msg = hPutStrLn stderr $ "[tar-map] " <> msg



