{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE LambdaCase #-}

-- |
-- Module      : Main
-- Description : Video Splitter (Stream -> Tar Stream)
-- Copyright   : (c) Yui Nishimura, 2024
-- License     : MIT
--
-- Unix Filter philosophy:
--   Stdin (Video Stream) -> [FFmpeg Segmenter] -> [Tmp Files] -> [Tar Stream Generator] -> Stdout (Tar Archive)
--
-- This program acts as a bridge between a raw video stream and a Tar archive stream,
-- chunking the video on the fly using FFmpeg. It ensures minimal storage usage by
-- deleting chunks immediately after they are streamed to stdout.

module Main where

import Protolude hiding (bracket)
import qualified Data.Text as T
import qualified Data.ByteString.Lazy as BL
import System.IO (hPutStrLn, stderr, stdin, stdout, BufferMode(..), hSetBinaryMode, hSetBuffering)
import System.Process (createProcess, proc, std_in, std_out, std_err, StdStream(..), waitForProcess, ProcessHandle, getProcessExitCode)
import System.Directory (createDirectoryIfMissing, removeDirectoryRecursive, removeFile, listDirectory, getTemporaryDirectory)
import System.FilePath ((</>), takeFileName)
import qualified Codec.Archive.Tar as Tar
import qualified Codec.Archive.Tar.Entry as Tar
import Options.Applicative
import Control.Exception.Safe (bracket, tryAny)
import System.IO.Unsafe (unsafeInterleaveIO)
import Control.Concurrent (threadDelay)
import Data.Time (getCurrentTime, diffUTCTime, UTCTime(..))
import Data.Time.Calendar (Day(..))

-- | Configuration Definition
data Config = Config
  { segmentTime :: Text
  , filePrefix :: Text
  }

-- | CLI Parser
configParser :: Parser Config
configParser = Config
  <$> strOption
      ( long "time"
     <> short 't'
     <> metavar "TIME"
     <> help "Segment duration (e.g. 14:50)"
     <> value "14:50" )
  <*> strOption
      ( long "prefix"
     <> short 'p'
     <> metavar "PREFIX"
     <> help "Output filename prefix"
     <> value "out" )

-- | Main Entry Point
main :: IO ()
main = do
  -- Setup binary mode for pipes
  hSetBinaryMode stdin True
  hSetBinaryMode stdout True
  hSetBuffering stdout NoBuffering -- Stream immediately

  config <- execParser opts
  withSystemTempDirectory "video-split" $ \tmpDir -> do
    runPipeline config tmpDir

  where
    opts = info (configParser <**> helper)
      ( fullDesc
     <> progDesc "Split video stream from stdin into tar archive on stdout"
     <> header "split-video - Functional Stream Splitter" )

-- | Create a temporary directory and clean it up
withSystemTempDirectory :: FilePath -> (FilePath -> IO a) -> IO a
withSystemTempDirectory template action = do
  sysTmp <- getTemporaryDirectory
  let dir = sysTmp </> template
  -- We append a random number or similar in a real world, but for simplicity/purity we rely on mktemp behavior if available or just create strict path
  -- In Haskell, usually `openTempFile` is used, but we need a directory.
  -- Simplified: Create a specific logic or use random path.
  -- Since we want robustness, we'll assume a unique run or handle collision.
  -- Actually, `openTempDirectory` exists in `temporary` package but we don't have it.
  -- We'll try to create a unique-ish one.
  t <- show <$> diffUTCTime <$> getCurrentTime <*> pure (UTCTime (ModifiedJulianDay 0) 0) -- pseudo-random
  let runDir = dir <> "-" <> (take 10 $ show t)
  bracket
    (createDirectoryIfMissing True runDir >> return runDir)
    (\d -> tryAny (removeDirectoryRecursive d) >> return ())
    action

-- | The core pipeline
runPipeline :: Config -> FilePath -> IO ()
runPipeline Config{..} tmpDir = do
  logInfo "Starting pipeline..."

  -- CSV List file for FFmpeg to report segments
  let listFile = tmpDir </> "segments.csv"
      segmentPattern = tmpDir </> (T.unpack filePrefix <> "_%03d.mp4")

  -- Start FFmpeg process
  -- ffmpeg -i - -c copy -f segment -segment_time TIME -segment_list LIST -segment_list_type csv -reset_timestamps 1 PATTERN
  let args = [ "-i", "-" -- Read from stdin
             , "-c", "copy"
             , "-f", "segment"
             , "-segment_time", T.unpack segmentTime
             , "-segment_list", listFile
             , "-segment_list_type", "csv"
             , "-reset_timestamps", "1"
             , "-loglevel", "error" -- Minimize noise
             , segmentPattern
             ]

  logInfo $ "Running ffmpeg " <> show args

  (Just hin, _, _, ph) <- createProcess (proc "ffmpeg" args)
    { std_in = UseHandle stdin  -- Inherit/Pipe stdin
    , std_out = CreatePipe      -- Ignore stdout
    , std_err = Inherit         -- Show errors
    }

  -- Close our handle to the pipe so ffmpeg gets EOF when we do (if we were piping)
  -- But here we passed `UseHandle stdin`, so it shares our stdin.
  -- If `stdin` is a pipe from `cat`, ffmpeg reads it.

  -- Start the generator loop
  -- We need to monitor `listFile`.
  -- Since `ffmpeg` writes to it, we can read it.
  -- However, pure file reading is tricky with appending.
  -- Strategy:
  --   Maintain a set of processed files.
  --   Periodically check the csv file.
  --   If new file, emit it.
  --   If ffmpeg finished, process remaining and exit.

  let loop knownFiles = do
        isAlive <- isProcessAlive ph

        -- Read CSV (handle missing file if not yet created)
        content <- tryAny (readFile listFile) >>= \case
           Right c -> return c
           Left _ -> return ""

        let lines = T.lines content
            -- Format: filename,start_time,end_time
            -- We just want the filename
            files = mapMaybe parseCsv lines
            newFiles = filter (`notElem` knownFiles) files

        -- Emit new files
        emitFiles tmpDir newFiles

        -- Delete processed files to save space?
        -- `emitFiles` will read and yield Entries. We can delete after yielding.
        -- But `Tar.write` is pure. We need to construct the list carefully.
        -- Actually, we can't use `Tar.write` easily if we want to interleave side-effects (delete).
        -- We should use `Tar.write`'s output (ByteString) and print it, but `Tar` builds entries reading files heavily.
        -- `Tar.pack` reads files.

        -- Better Logic:
        -- Manual Tar Construction or Step-by-Step packing.
        -- `Tar.pack` takes a base dir and paths. It returns `[Entry]`.
        -- We can map `Tar.pack` over the newFiles.

        forM_ newFiles $ \f -> do
           -- Pack this single file
           -- Note: input path to pack is relative
           let fullPath = tmpDir </> f
           entries <- Tar.pack tmpDir [f]
           -- Write entries to stdout
           BL.hPut stdout (Tar.write entries)
           -- Remove file to save space
           removeFile fullPath
           logInfo $ "Streamed and removed: " <> T.pack f

        let updatedKnown = knownFiles ++ newFiles

        if isAlive
           then do
             threadDelay 100000 -- 0.1s wait
             loop updatedKnown
           else do
             -- Process any final files that might have appeared in split second
             -- Actually `isProcessAlive` might be false but file just written.
             -- Check one last time
             finalContent <- tryAny (readFile listFile) >>= \case
                Right c -> return c
                Left _ -> return ""
             let finalFiles = mapMaybe parseCsv (T.lines finalContent)
                 finalNew = filter (`notElem` updatedKnown) finalFiles

             forM_ finalNew $ \f -> do
                let fullPath = tmpDir </> f
                entries <- Tar.pack tmpDir [f]
                BL.hPut stdout (Tar.write entries)
                removeFile fullPath
                logInfo $ "Streamed and removed (final): " <> T.pack f

             return ()

  loop []

  exitCode <- waitForProcess ph
  logInfo $ "FFmpeg finished with " <> show exitCode

parseCsv :: Text -> Maybe FilePath
parseCsv line = case T.splitOn "," line of
  (f:_) -> Just (T.unpack f)
  _ -> Nothing

emitFiles :: FilePath -> [FilePath] -> IO ()
emitFiles _ [] = return ()
emitFiles _ _ = return () -- Handled in loop

isProcessAlive :: ProcessHandle -> IO Bool
isProcessAlive ph = getProcessExitCode ph >>= \case
  Nothing -> return True
  Just _  -> return False

logInfo :: Text -> IO ()
logInfo msg = hPutStrLn stderr $ "[split-video] " <> T.unpack msg
