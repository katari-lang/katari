-- | Snapshot files — the @katari-registry@'s pinned (repo, ref, sha256)
-- tuples for each package in a curated set.
--
-- This module covers two concerns:
--
--   1. Parsing a snapshot TOML file (= one of @package-sets\/\<date>.toml@).
--   2. Resolving a URL (from @[dependencies].registry@ + @[dependencies].snapshot@)
--      into the raw bytes of the snapshot file, supporting both @file:\/\/@ and
--      @https:\/\/@ schemes plus a "URL points at the registry root,
--      version is the filename" convention.
--
-- Once the file is in memory, downstream callers (= 'Katari.Project.Resolve')
-- look up each dep name, fetch the tarball at the recorded
-- @(repo, ref)@ via 'Katari.Project.Fetch', and verify the resulting
-- @sha256@ against the snapshot's pin.
module Katari.Project.Snapshot
  ( Snapshot (..),
    SnapshotPackage (..),
    SnapshotError (..),
    parseSnapshot,
    loadSnapshotFromUrlWith,
  )
where

import Control.Exception (IOException, try)
import Data.Bifunctor (first)
import Data.ByteString.Lazy qualified as LBS
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TextIO
import Katari.Project.Toml (extractNestedTables)
import Network.HTTP.Client
  ( HttpException,
    Manager,
    Request,
    Response,
    httpLbs,
    parseRequest,
    responseBody,
    responseStatus,
  )
import Network.HTTP.Types.Status (statusCode)
import System.Directory (doesFileExist)
import Toml (TomlCodec, (.=))
import Toml qualified
import Validation qualified

data Snapshot = Snapshot
  { snapshotCompilerVersion :: Maybe Text,
    snapshotPackages :: Map Text SnapshotPackage
  }
  deriving (Show, Eq)

data SnapshotPackage = SnapshotPackage
  { repo :: Text,
    ref :: Text,
    sha :: Text
  }
  deriving (Show, Eq)

data SnapshotError
  = SnapshotIOError Text Text
  | SnapshotHttpError Text Text
  | SnapshotParseError FilePath Text
  | SnapshotValidationError FilePath Text
  | SnapshotUnsupportedUrl Text
  deriving (Show, Eq)

-- ---------------------------------------------------------------------------
-- Raw codec + post-parse validation
-- See Katari.Project.Toml for details on the tomland workaround.
-- ---------------------------------------------------------------------------

data RawSnapshot = RawSnapshot
  { rawCompiler :: Maybe Text,
    rawPackages :: Map Text RawSnapshotPackage
  }

data RawSnapshotPackage = RawSnapshotPackage
  { rawRepo :: Maybe Text,
    rawRef :: Maybe Text,
    rawSha :: Maybe Text
  }

-- | Codec for the top-level scalars only. @[packages.X]@ nested
-- tables are extracted via 'extractPackages'.
rawSnapshotCodec :: TomlCodec RawSnapshot
rawSnapshotCodec =
  RawSnapshot
    <$> Toml.dioptional (Toml.text "katari_compiler") .= (.rawCompiler)
    -- Packages are stitched in after AST-level extraction.
    <*> pure Map.empty .= (.rawPackages)

rawSnapshotPackageCodec :: TomlCodec RawSnapshotPackage
rawSnapshotPackageCodec =
  RawSnapshotPackage
    <$> Toml.dioptional (Toml.text "repo") .= (.rawRepo)
    <*> Toml.dioptional (Toml.text "ref") .= (.rawRef)
    <*> Toml.dioptional (Toml.text "sha256") .= (.rawSha)

parseSnapshot :: FilePath -> Text -> Either SnapshotError Snapshot
parseSnapshot path raw = do
  toml <-
    first
      (SnapshotParseError path . Text.pack . show)
      (Toml.parse raw)
  rs <-
    first
      (SnapshotParseError path . Toml.prettyTomlDecodeErrors)
      (Validation.validationToEither (Toml.runTomlCodec rawSnapshotCodec toml))
  pkgs <- extractPackages path toml
  validateSnapshot path (rs {rawPackages = pkgs})

extractPackages :: FilePath -> Toml.TOML -> Either SnapshotError (Map Text RawSnapshotPackage)
extractPackages path = extractNestedTables "packages" (decodePackage path)

decodePackage :: FilePath -> Text -> Toml.TOML -> Either SnapshotError RawSnapshotPackage
decodePackage path name sub =
  case Validation.validationToEither (Toml.runTomlCodec rawSnapshotPackageCodec sub) of
    Left errs ->
      Left
        ( SnapshotValidationError
            path
            ("[packages." <> name <> "]: " <> Toml.prettyTomlDecodeErrors errs)
        )
    Right pkg -> Right pkg

validateSnapshot :: FilePath -> RawSnapshot -> Either SnapshotError Snapshot
validateSnapshot path RawSnapshot {..} = do
  pkgs <- Map.traverseWithKey (validateOnePackage path) rawPackages
  Right
    Snapshot
      { snapshotCompilerVersion = rawCompiler,
        snapshotPackages = pkgs
      }

validateOnePackage ::
  FilePath -> Text -> RawSnapshotPackage -> Either SnapshotError SnapshotPackage
validateOnePackage path name RawSnapshotPackage {..} = do
  r <- require "repo" rawRepo
  rf <- require "ref" rawRef
  sh <- require "sha256" rawSha
  Right SnapshotPackage {repo = r, ref = rf, sha = sh}
  where
    require field m = case m of
      Just t | not (Text.null t) -> Right t
      _ ->
        Left
          ( SnapshotValidationError
              path
              ("[packages." <> name <> "]." <> field <> " missing or empty")
          )

-- ---------------------------------------------------------------------------
-- Fetching
-- ---------------------------------------------------------------------------

-- | Read a snapshot from a URL. Schemes:
--
--   * @file:\/\/\/abs\/path\/to\/file.toml@ — direct read from disk.
--   * @file:\/\/\/abs\/path\/to\/registry@ — registry root; @version@
--     selects @\<registry>\/package-sets\/\<version>.toml@.
--   * @https:\/\/...@ — HTTP GET (TLS via 'Network.HTTP.Client.TLS').
loadSnapshotFromUrlWith ::
  Manager ->
  Text ->
  Maybe Text ->
  IO (Either SnapshotError Snapshot)
loadSnapshotFromUrlWith manager url mVersion =
  case Text.stripPrefix "file://" url of
    Just rest -> loadFromFile (Text.unpack rest) mVersion
    Nothing
      | "https://" `Text.isPrefixOf` url -> loadFromHttp manager url mVersion
      | "http://" `Text.isPrefixOf` url ->
          pure (Left (SnapshotUnsupportedUrl ("http:// snapshot URLs are not supported (use https:// or file://): " <> url)))
      | otherwise -> pure (Left (SnapshotUnsupportedUrl url))

loadFromFile :: FilePath -> Maybe Text -> IO (Either SnapshotError Snapshot)
loadFromFile path mVersion = do
  let target =
        if ".toml" `Text.isSuffixOf` Text.pack path
          then path
          else case mVersion of
            Just v ->
              path
                <> "/package-sets/"
                <> Text.unpack v
                <> ".toml"
            Nothing -> path
  exists <- doesFileExist target
  if not exists
    then pure (Left (SnapshotIOError (Text.pack target) "file does not exist"))
    else do
      readRes <- try (TextIO.readFile target) :: IO (Either IOException Text)
      case readRes of
        Left err ->
          pure
            ( Left
                ( SnapshotIOError
                    (Text.pack target)
                    (Text.pack (show err))
                )
            )
        Right raw -> pure (parseSnapshot target raw)

loadFromHttp :: Manager -> Text -> Maybe Text -> IO (Either SnapshotError Snapshot)
loadFromHttp manager url mVersion = do
  let target =
        if ".toml" `Text.isSuffixOf` url
          then url
          else case mVersion of
            Just v -> url <> "/package-sets/" <> v <> ".toml"
            Nothing -> url
  reqRes <- try (parseRequest (Text.unpack target)) :: IO (Either IOException Request)
  case reqRes of
    Left err -> pure (Left (SnapshotHttpError target (Text.pack (show err))))
    Right req -> do
      respRes <-
        try (httpLbs req manager) ::
          IO (Either HttpException (Response LBS.ByteString))
      case respRes of
        Left err -> pure (Left (SnapshotHttpError target (Text.pack (show err))))
        Right resp -> do
          let status = statusCode (responseStatus resp)
              body = LBS.toStrict (responseBody resp)
          if status >= 400
            then
              pure
                ( Left
                    ( SnapshotHttpError
                        target
                        ("HTTP " <> Text.pack (show status))
                    )
                )
            else pure (parseSnapshot (Text.unpack target) (TE.decodeUtf8 body))
