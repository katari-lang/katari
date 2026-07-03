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

import Control.Exception (IOException, bracketOnError, catch)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Katari.Cli.Api (FileRow (..), UploadedFile (..), downloadFileTo, listFiles, uploadFile)
import Katari.Cli.Common (RuntimeContext (..), dieIn, renderPrefixError, resolveIdPrefix, withRuntimeContext)
import Katari.Cli.Options (GlobalOptions, globalOptionsParser)
import Katari.Cli.Output (printText, progress)
import Options.Applicative
import System.Directory (removeFile, renameFile)
import System.FilePath (takeDirectory, takeFileName)
import System.IO (hClose, hIsTerminalDevice, openTempFile, stdout)

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
          -- Stream into a sibling temp file and atomically rename it into place only once the whole
          -- download succeeds, so a failed download (a bad id, a mid-stream error) leaves any
          -- existing destination file untouched instead of truncating it to nothing.
          downloadToPath context target path
          progress context.output ("Wrote " <> Text.pack path)
        Nothing -> do
          stdoutIsTerminal <- hIsTerminalDevice stdout
          if stdoutIsTerminal
            then dieIn "file" "refusing to write raw bytes to a terminal; pass -o PATH or pipe stdout"
            else downloadFileTo context.client context.projectId target stdout

-- | Download a file's bytes to @path@ without ever leaving it in a half-written state: the bytes
-- stream into a unique temp file in the same directory, which is atomically renamed onto @path@ only
-- after the transfer completes. Any failure removes the temp file and leaves @path@ as it was.
downloadToPath :: RuntimeContext -> Text -> FilePath -> IO ()
downloadToPath context target path =
  bracketOnError
    (openTempFile (takeDirectory path) (takeFileName path <> ".partial"))
    ( \(tempPath, tempHandle) -> do
        -- The download failed; drop the partial file (best effort) so only the intact destination
        -- ever survives.
        ignoringIOErrors (hClose tempHandle)
        ignoringIOErrors (removeFile tempPath)
    )
    ( \(tempPath, tempHandle) -> do
        downloadFileTo context.client context.projectId target tempHandle
        hClose tempHandle
        renameFile tempPath path
    )
  where
    ignoringIOErrors step = step `catch` \(_ :: IOException) -> pure ()
