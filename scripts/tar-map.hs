{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module      : Main
-- Description : generic tar-map utility (Tar Stream -> Shell Command -> Tar Stream)
-- Copyright   : (c) Yui Nishimura, 2024
-- License     : MIT
--
-- The "Silver Bullet" Abstraction:
-- This tool lifts any Unix command into a "bind" operation on the Tar Monad.
--
--   tar-map :: (File -> IO [File]) -> TarStream -> TarStream
--
-- Algorithm for each entry in the input tar stream:
-- 1. Extract the file to a temporary sandbox.
-- 2. Execute the user-specified command with the file path.
-- 3. Capture all files in the sandbox (post-execution).
-- 4. Emit these files as new tar entries to stdout.
-- 5. Clean up the sandbox.

module Main where

import Protolude hiding (bracket, try, catch)
import qualified Data.Text as T
import qualified Data.ByteString.Lazy as BL
import System.IO (hSetBinaryMode, hSetBuffering, BufferMode(..), Handle)
import System.Process (callProcess, proc, createProcess, waitForProcess, std_in, std_out, std_err, StdStream(..), CreateProcess(..), ProcessHandle, withCreateProcess)
import System.Directory (createDirectoryIfMissing, removeDirectoryRecursive, listDirectory, getTemporaryDirectory, doesFileExist, copyFile, setModificationTime)
import System.FilePath ((</>), takeDirectory, takeFileName, makeRelative, normalise)
import Data.Typeable (Typeable)
import Data.Time.Calendar (Day(..))
import qualified Codec.Archive.Tar as Tar
import qualified Codec.Archive.Tar.Entry as Tar
import Options.Applicative
import Control.Exception.Safe (bracket, tryAny, throwString)
import Data.Time (getCurrentTime, diffUTCTime, UTCTime(..))
import System.Environment (getEnvironment)

-- | Configuration
data Config = Config
  { cmdTemplate :: [[Char]] -- Command and args, optionally containing "{}"
  , keepOriginal :: Bool    -- Whether to keep the output inside the original directory structure
  }

-- | CLI Parser
configParser :: Parser Config
configParser = Config
  <$> many (strArgument (metavar "COMMAND_AND_ARGS..."))
  <*> switch (long "keep-structure" <> help "Maintain original directory structure for output files")

-- | Main
main :: IO ()
main = do
  hSetBinaryMode stdin True
  hSetBinaryMode stdout True
  hSetBuffering stdout NoBuffering

  config <- execParser opts

  -- Read entire tar stream lazily
  content <- BL.hGetContents stdin
  let entries = Tar.read content

  -- Process entries
  -- Note: Tar.read returns a lazy sequence `Entries`.
  -- We must fold over it or recurse.
  processEntries config entries

  where
    opts = info (configParser <**> helper)
      ( fullDesc
     <> progDesc "Apply a command to each file in a tar stream, emitting resulting files"
     <> header "tar-map - The Monadic Bind for Filesystem Streams" )

processEntries :: Config -> Tar.Entries Tar.FormatError -> IO ()
processEntries _ Tar.Done = return ()
processEntries _ (Tar.Fail e) = hPutStrLn stderr $ "[tar-map] Tar Error: " <> (show e :: [Char])
processEntries config (Tar.Next entry next) = do
  case Tar.entryContent entry of
    Tar.NormalFile content _size -> do
       let path = Tar.entryPath entry
       logInfo $ "Processing: " <> T.pack path

       -- Sandbox execution
       withSystemTempDirectory "tm" $ \tmpDir -> do
         -- Replicate directory structure if needed, or just flatten?
         -- To avoid collisions if multiple files have same name in different dirs (sequential processing handles this, but user command expectation matters)
         -- We'll preserve structure relative to tmpDir
         let workPath = tmpDir </> path
         createDirectoryIfMissing True (takeDirectory workPath)

         -- Write input file
         BL.writeFile workPath content
         -- Restore mtime?
         let mtime = Tar.entryTime entry
         -- setModificationTime workPath ... (requires integration, skipping for now simplifies)

         -- Prepare command
         -- Replace "{}" with absolute path or relative?
         -- Relative is safer for commands that output to CWD.
         -- Let's run command with CWD = (takeDirectory workPath)
         -- and pass filename relative to it.
         -- This feels most "Unixy". Command works on file in current dir.

         let dir = takeDirectory workPath
             file = takeFileName workPath
             cmdArgs = map (replacePlaceholder file) (cmdTemplate config)
             (cmd:args) = if null (cmdTemplate config) then ["echo", file] else cmdArgs

         -- Execute
         logInfo $ "  Running: " <> T.unwords (map T.pack (cmd:args)) <> " in " <> T.pack dir

         -- Run process
         -- We ignore stdout of the command (unless we want to capture it? No, side-effect files are better for mapped structure)
         -- If command fails?
         result <- tryAny $ withCreateProcess ((proc cmd args) { cwd = Just dir, std_in = Inherit, std_out = Inherit, std_err = Inherit }) $ \_ _ _ ph -> do
             waitForProcess ph

         case result of
           Right exitCode -> do
              -- Scan for output files
              -- We scan `dir` basically.
              -- But wait, if the tar has deep structure `a/b/c.txt`, we are in `tmp/a/b`.
              -- Any file created in `tmp/a/b` should be emitted as `a/b/newfile`.
              -- What if command writes to `../../`? We shouldn't scan that.

              -- Recursive scan of `dir` is tricky if we assume only flat output.
              -- Let's stick to: Scan `dir` recursively.

              subFiles <- listDirectoryRecursive dir

              forM_ subFiles $ \subPath -> do
                 let fullSubPath = dir </> subPath
                 isFile <- doesFileExist fullSubPath
                 when isFile $ do
                   -- Construct entry name
                   -- If original was `a/b/c.txt`. dir is `a/b`. subPath is `out.txt`.
                   -- Entry path: `a/b/out.txt`.

                   -- Wait, structure preservation:
                   -- If `keep-structure` is true (default logic effectively), we map `tmp/a/b/out.txt` back to `a/b/out.txt`.
                   let entryName = (takeDirectory path) </> subPath

                   entryContent <- BL.readFile fullSubPath
                   -- Create generic entry
                   -- TODO: Capture attributes?
                   newEntry <- case Tar.toTarPath False entryName of
                       Right tp -> return (Tar.fileEntry tp entryContent)
                       Left e -> throwString ("Invalid tar path: " <> e)

                   BL.hPut stdout (Tar.write [newEntry])
                   logInfo $ "  Emitted: " <> T.pack entryName

           Left e -> logInfo $ "  Command failed: " <> show e

  -- Recurse
  processEntries config next
  where
    replacePlaceholder f template =
        let f' = T.pack f
            t' = T.pack template
        in T.unpack (T.replace "{}" f' t')


-- | Recursive list directory (relative paths)
listDirectoryRecursive :: FilePath -> IO [FilePath]
listDirectoryRecursive dir = do
  names <- listDirectory dir
  paths <- forM names $ \name -> do
    let path = dir </> name
    isDirectory <- doesFileExist path >>= \case
        True -> return False
        False -> return True -- Simplified (could be symlink etc)
    if isDirectory
      then do
          subs <- listDirectoryRecursive path
          return $ map (name </>) subs
      else return [name]
  return $ concat paths

-- | Temp Dir Helper (Copied from split-video.hs, DRY violation but self-contained)
withSystemTempDirectory :: FilePath -> (FilePath -> IO a) -> IO a
withSystemTempDirectory template action = do
  sysTmp <- getTemporaryDirectory
  let dir = sysTmp </> template
  now <- getCurrentTime
  let t = diffUTCTime now (UTCTime (ModifiedJulianDay 0) 0)
      tStr = show t :: Text
      runDir = dir <> "-" <> (take 10 $ T.unpack tStr)
      -- Simple random-ish suffix logic
  bracket
    (createDirectoryIfMissing True runDir >> return runDir)
    (\d -> tryAny (removeDirectoryRecursive d) >> return ())
    action

logInfo :: Text -> IO ()
logInfo msg = hPutStrLn stderr $ "[tar-map] " <> msg

-- | withCreateProcess wrapper
-- Imported directly from System.Process


-- Fix imports for copy paste
-- We need `createProcess` from System.Process for specialized wrapping if needed, but `withCreateProcess` is cleaner.
