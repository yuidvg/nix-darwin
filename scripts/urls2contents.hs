#!/usr/bin/env runhaskell

{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE FlexibleContexts #-}

import Protolude hiding (try, option)
import Options.Applicative
import Network.HTTP.Req
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Control.Exception.Safe (try, SomeException)
import Data.Text.Encoding (encodeUtf8, decodeUtf8With)
import Data.Text.Encoding.Error (lenientDecode)
import qualified System.IO.Error
import System.Process (readProcess)
import Text.URI (mkURI)

-- | Command line arguments
data Options = Options
  { optVerbose :: Bool }

optionsParser :: Parser Options
optionsParser = Options
  <$> switch
      ( long "verbose"
     <> short 'v'
     <> help "Enable verbose output" )

-- | Application logic
main :: IO ()
main = do
  opts <- execParser optsInfo
  runReaderT runPipeline opts
  where
    optsInfo = info (optionsParser <**> helper)
      ( fullDesc
     <> progDesc "Fetch and extract content from URLs provided via stdin"
     <> Options.Applicative.header "urls2contents - a functional URL content extractor" )

type App = ReaderT Options IO

runPipeline :: App ()
runPipeline = do
  -- Read from stdin lazily
  contents <- liftIO TIO.getContents
  let urls = filter (not . T.null) $ T.lines contents
  mapM_ processUrl urls

processUrl :: Text -> App ()
processUrl url = do
  verbose <- asks optVerbose
  liftIO $ TIO.putStrLn $ "\n---- " <> url <> " ----"

  result <- liftIO $ try $ fetchAndExtract url
  case result of
    Left e -> liftIO $ TIO.putStrLn $ "Error: " <> show (e :: SomeException)
    Right content -> liftIO $ TIO.putStrLn content

fetchAndExtract :: Text -> IO Text
fetchAndExtract url = do
  runReq defaultHttpConfig $ do
      let uriM = mkURI url
      case uriM of
        Nothing -> liftIO $ throwIO $ userError "Invalid URL format"
        Just uri -> do
           case useURI uri of
             Nothing -> liftIO $ throwIO $ userError "Unsupported URL scheme"
             Just (Left (urlHttp, opts)) -> req GET urlHttp NoReqBody bsResponse opts >>= handleResponse url
             Just (Right (urlHttps, opts)) -> req GET urlHttps NoReqBody bsResponse opts >>= handleResponse url

handleResponse :: Text -> BsResponse -> Req Text
handleResponse url r = do
  let body = responseBody r
  let bodyText = decodeUtf8With lenientDecode body

  let isHtml = "html" `T.isInfixOf` url || "<html" `T.isInfixOf` (T.toLower $ T.take 100 bodyText)

  if isHtml
    then liftIO $ extractWithTrafilatura bodyText
    else return bodyText

extractWithTrafilatura :: Text -> IO Text
extractWithTrafilatura htmlContent = do
  -- trafilatura reads from stdin default, or expects arguments.
  -- We'll pass content via stdin.
  output <- try $ readProcess "trafilatura" [] (T.unpack htmlContent)
  case output of
    Left e -> return $ "(Trafilatura execution failed: " <> show (e :: SomeException) <> ")"
    Right res -> return $ T.pack res

userError :: [Char] -> IOException
userError = System.IO.Error.userError
