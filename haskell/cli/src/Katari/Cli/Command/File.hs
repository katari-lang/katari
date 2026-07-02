-- | @katari file upload|download@ — the project's blob storage (listing lives under
-- @katari ls files@). Bytes stream in both directions, so a large blob never sits in the CLI's
-- memory. A download without @-o@ goes to stdout only when stdout is not a terminal — raw bytes at a
-- terminal are refused rather than sprayed.
module Katari.Cli.Command.File
  ( Options (..),
    optionsParser,
    run,
  )
where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Katari.Cli.Api (FileRow (..), UploadedFile (..), downloadFileTo, listFiles, uploadFile)
import Katari.Cli.Common (RuntimeContext (..), dieIn, renderPrefixError, resolveIdPrefix, withRuntimeContext)
import Katari.Cli.Options (GlobalOptions, globalOptionsParser)
import Katari.Cli.Output (printText, progress)
import Options.Applicative
import System.IO (IOMode (..), hIsTerminalDevice, stdout, withFile)

data Action
  = ActionUpload UploadOptions
  | ActionDownload DownloadOptions
  deriving stock (Show)

data UploadOptions = UploadOptions
  { path :: FilePath,
    contentType :: Maybe Text
  }
  deriving stock (Show)

data DownloadOptions = DownloadOptions
  { fileId :: Text,
    outputPath :: Maybe FilePath
  }
  deriving stock (Show)

data Options = Options
  { global :: GlobalOptions,
    projectName :: Maybe Text,
    action :: Action
  }
  deriving stock (Show)

optionsParser :: Parser Options
optionsParser =
  Options
    <$> globalOptionsParser
    <*> optional
      ( strOption
          ( long "project"
              <> metavar "NAME"
              <> help "Project the file belongs to (default: the surrounding katari.toml's [package].name)"
          )
      )
    <*> hsubparser
      ( command "upload" (info (ActionUpload <$> uploadParser) (progDesc "Upload a file; prints the new file id"))
          <> command "download" (info (ActionDownload <$> downloadParser) (progDesc "Download a file's bytes"))
      )
  where
    uploadParser =
      UploadOptions
        <$> strArgument (metavar "PATH" <> help "Local file to upload")
        <*> optional (strOption (long "content-type" <> metavar "TYPE" <> help "MIME type recorded with the file (default: application/octet-stream)"))
    downloadParser =
      DownloadOptions
        <$> strArgument (metavar "FILE" <> help "File id, or a unique prefix of one")
        <*> optional (strOption (long "out" <> short 'o' <> metavar "PATH" <> help "Write to this path (default: stdout, when it is not a terminal)"))

run :: Options -> IO ()
run options = do
  context <- withRuntimeContext "file" options.global options.projectName
  case options.action of
    ActionUpload uploadOptions -> do
      uploaded <-
        uploadFile
          context.client
          context.projectId
          uploadOptions.path
          (fromMaybe "application/octet-stream" uploadOptions.contentType)
      progress context.output ("Uploaded " <> Text.pack uploadOptions.path <> " (" <> Text.pack (show uploaded.size) <> " bytes)")
      printText uploaded.id
    ActionDownload downloadOptions -> do
      (_, files) <- listFiles context.client context.projectId
      target <-
        either
          (dieIn "file" . renderPrefixError downloadOptions.fileId)
          pure
          (resolveIdPrefix downloadOptions.fileId (map (\row -> row.id) files))
      case downloadOptions.outputPath of
        Just path -> do
          withFile path WriteMode (downloadFileTo context.client context.projectId target)
          progress context.output ("Wrote " <> Text.pack path)
        Nothing -> do
          stdoutIsTerminal <- hIsTerminalDevice stdout
          if stdoutIsTerminal
            then dieIn "file" "refusing to write raw bytes to a terminal; pass -o PATH or pipe stdout"
            else downloadFileTo context.client context.projectId target stdout
