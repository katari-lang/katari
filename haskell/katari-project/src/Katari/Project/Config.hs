-- | TOML schema and loader for @katari.toml@.
--
-- The schema mirrors the TypeScript-side reader in
-- @typescript/packages/katari-cli/src/services/config.ts@ so the LSP /
-- compiler / future package manager agree on every field.
--
-- The parser is hand-rolled (no @tomland@ dep): @katari.toml@ has a flat
-- shape with primitive scalar / array values only. Sections, key=value
-- assignments, comments, and @${VAR}@ env interpolation are the entire
-- surface area.
module Katari.Project.Config
  ( ProjectConfig (..),
    PackageSection (..),
    CompileSection (..),
    SidecarSection (..),
    ApiSection (..),
    SnapshotSection (..),
    OverrideSource (..),
    PathDependency (..),
    ConfigError (..),
    parseKatariToml,
    loadKatariToml,
    interpolateEnv,
    -- For tests + sibling validators (e.g. Katari.Project.Lockfile).
    parseTomlText,
    TomlValue (..),
    TomlTable (..),
    TomlBucket (..),
    lookupTable,
    lookupTableScalar,
  )
where

import Control.Exception (IOException, try)
import Data.Char (isAlpha, isAlphaNum)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import System.Environment (lookupEnv)

-- ===========================================================================
-- Data types
-- ===========================================================================

data ProjectConfig = ProjectConfig
  { -- | Convenience mirror of @packageSection.packageName@. Kept for
    -- back-compat with callers that read the package's display name.
    projectName :: Text,
    packageSection :: PackageSection,
    compileSection :: CompileSection,
    sidecarSection :: Maybe SidecarSection,
    apiSection :: ApiSection,
    -- | The snapshot pin + the flat dependency name list. Stackage /
    -- spago model: the @snapshot@ pins a curated set of compatible
    -- packages; @dependencies@ enumerates which of those (plus any
    -- 'overrides') this project actually uses.
    snapshotSection :: SnapshotSection,
    -- | Local replacements for packages in the snapshot (or extras
    -- not in the snapshot at all). Every name appearing here must
    -- also appear in @snapshotSection.dependencies@; the absence of
    -- a snapshot entry then means "this package comes purely from
    -- this override".
    overrides :: Map Text OverrideSource
  }
  deriving (Show, Eq)

data PackageSection = PackageSection
  { packageName :: Text,
    packageVersion :: Maybe Text
  }
  deriving (Show, Eq)

data CompileSection = CompileSection
  { compileSrc :: FilePath,
    compileRoot :: Maybe Text
  }
  deriving (Show, Eq)

newtype SidecarSection = SidecarSection
  { sidecarSourceRoots :: [FilePath]
  }
  deriving (Show, Eq)

data ApiSection = ApiSection
  { apiUrl :: Text,
    apiAuth :: Maybe Text
  }
  deriving (Show, Eq)

data SnapshotSection = SnapshotSection
  { -- | Snapshot identifier, e.g. @"2026-05-01"@. Resolved against
    -- the katari-registry's @package-sets\/@ directory (or whatever
    -- mirror is configured downstream).
    snapshotVersion :: Maybe Text,
    -- | Optional explicit URL for the snapshot TOML file (or its
    -- containing registry). Accepted forms:
    --
    --   * @file:\/\/\/abs\/path\/to\/registry@ — local dev override.
    --     Snapshot file lives at @\<url>\/package-sets\/\<version>.toml@.
    --   * @file:\/\/\/abs\/path\/to\/2026-05-01.toml@ — direct file URL.
    --   * @https:\/\/...@ — canonical registry / mirror URL.
    --
    -- 'Nothing' means "no snapshot resolution requested" (= every dep
    -- must be in @[overrides]@).
    snapshotUrl :: Maybe Text,
    -- | Flat list of package names this project depends on. Each
    -- name resolves to either the snapshot's entry for it or a local
    -- @[overrides.\<name>]@ block.
    snapshotDependencies :: [Text]
  }
  deriving (Show, Eq)

-- | The local replacement / external source for a single dependency
-- name. Only path sources are wired in v1; git is parsed and held
-- for the upcoming git-fetch implementation.
data OverrideSource
  = -- | @path = "..."@ — relative or absolute filesystem path. Mutable;
    -- not cached.
    OverridePath FilePath
  | -- | @git = "..." rev = "..."@ — full-SHA git ref. Cached under
    -- @~\/.katari\/cache\/git\/\<sha>\/@ at resolve time.
    OverrideGit
      { gitUrl :: Text,
        gitRev :: Text
      }
  deriving (Show, Eq)

-- | A path-based dependency entry. The path is interpreted relative to
-- the @katari.toml@ that declares it (resolution happens elsewhere).
newtype PathDependency = PathDependency
  { depPath :: FilePath
  }
  deriving (Show, Eq)

data ConfigError
  = ConfigIOError FilePath Text
  | ConfigParseError FilePath Int Text -- line number, message
  | ConfigValidationError FilePath Text
  deriving (Show, Eq)

-- ===========================================================================
-- Public loaders
-- ===========================================================================

-- | Read @katari.toml@ from disk, interpolate @${VAR}@ env refs, parse,
-- validate. IO is the file read + env lookup.
loadKatariToml :: FilePath -> IO (Either ConfigError ProjectConfig)
loadKatariToml path = do
  readResult <- try (TextIO.readFile path) :: IO (Either IOException Text)
  case readResult of
    Left e -> pure (Left (ConfigIOError path (Text.pack (show e))))
    Right raw -> do
      interpolated <- interpolateEnv raw
      pure (parseKatariToml path interpolated)

-- | Parse the textual contents of @katari.toml@ (already env-interpolated).
parseKatariToml :: FilePath -> Text -> Either ConfigError ProjectConfig
parseKatariToml path raw = do
  table <- mapLeft (uncurry (ConfigParseError path)) (parseTomlText raw)
  validateConfig path table

-- ===========================================================================
-- Env interpolation
--
-- @${VAR}@ → @lookupEnv VAR@ (empty string if unset).
-- @\\${VAR}@ → @${VAR}@ (literal, no lookup).
-- ===========================================================================

interpolateEnv :: Text -> IO Text
interpolateEnv input = Text.pack . reverse <$> go (Text.unpack input) []
  where
    go :: String -> String -> IO String
    go [] acc = pure acc
    -- Escaped: \${VAR} → ${VAR}
    go ('\\' : '$' : '{' : rest) acc =
      case spanName rest of
        Just (name, '}' : after) ->
          go after (reverse ("${" <> name <> "}") <> acc)
        _ -> go rest ('{' : '$' : acc)
    go ('$' : '{' : rest) acc =
      case spanName rest of
        Just (name, '}' : after) -> do
          val <- lookupEnv name
          go after (reverse (maybe "" id val) <> acc)
        _ -> go rest ('{' : '$' : acc)
    go (c : rest) acc = go rest (c : acc)

    spanName :: String -> Maybe (String, String)
    spanName s = case span isVarChar s of
      ([], _) -> Nothing
      (name@(h : _), t)
        | isAlphaOrUnder h -> Just (name, t)
        | otherwise -> Nothing

    isVarChar c = isAlphaNum c || c == '_'
    isAlphaOrUnder c = isAlpha c || c == '_'

-- ===========================================================================
-- Validation
-- ===========================================================================

validateConfig :: FilePath -> TomlTable -> Either ConfigError ProjectConfig
validateConfig path table = do
  -- Package name: prefer [package].name, fall back to legacy top-level
  -- `project = "..."`. At least one must be present.
  let packageTable = lookupTable "package" table
  name <- case lookupTableScalar "name" packageTable of
    Just (TomlString s) | not (Text.null s) -> Right s
    _ -> case lookupScalar "project" table of
      Just (TomlString s) | not (Text.null s) -> Right s
      _ ->
        Left
          ( ConfigValidationError
              path
              "required field '[package].name' (or legacy top-level 'project')"
          )
  let version = case lookupTableScalar "version" packageTable of
        Just (TomlString s) | not (Text.null s) -> Just s
        _ -> Nothing
  let compileTable = lookupTable "compile" table
  let src = case lookupTableScalar "src" compileTable of
        Just (TomlString s) | not (Text.null s) -> Text.unpack s
        _ -> "src/"
  let root = case lookupTableScalar "root" compileTable of
        Just (TomlString s) | not (Text.null s) -> Just s
        _ -> Nothing
  let sidecarTable = lookupTable "sidecar" table
  sidecar <-
    if Map.null sidecarTable
      then Right Nothing
      else case lookupTableScalar "sourceRoots" sidecarTable of
        Just (TomlArray xs) -> do
          roots <- traverse expectString xs
          Right (Just SidecarSection {sidecarSourceRoots = map Text.unpack roots})
        Just _ ->
          Left
            ( ConfigValidationError
                path
                "'sidecar.sourceRoots' must be an array of strings"
            )
        Nothing -> Right (Just SidecarSection {sidecarSourceRoots = []})
  let apiTable = lookupTable "api" table
  let url = case lookupTableScalar "url" apiTable of
        Just (TomlString s) | not (Text.null s) -> s
        _ -> "http://localhost:8080"
  let auth = case lookupTableScalar "auth" apiTable of
        Just (TomlString s) | not (Text.null s) -> Just s
        _ -> Nothing
  snapshot <- parseSnapshotSection path table
  overrideMap <- parseOverrides path table snapshot.snapshotDependencies
  Right
    ProjectConfig
      { projectName = name,
        packageSection =
          PackageSection
            { packageName = name,
              packageVersion = version
            },
        compileSection = CompileSection {compileSrc = src, compileRoot = root},
        sidecarSection = sidecar,
        apiSection = ApiSection {apiUrl = url, apiAuth = auth},
        snapshotSection = snapshot,
        overrides = overrideMap
      }
  where
    expectString :: TomlValue -> Either ConfigError Text
    expectString = \case
      TomlString s -> Right s
      _ -> Left (ConfigValidationError path "expected string in array")

-- | Read the @[snapshot]@ block: @version@ (string, optional) and
-- @dependencies@ (array of strings, optional — defaults to @[]@).
parseSnapshotSection ::
  FilePath -> TomlTable -> Either ConfigError SnapshotSection
parseSnapshotSection path table = do
  let snapTable = lookupTable "snapshot" table
      ver = case lookupTableScalar "version" snapTable of
        Just (TomlString s) | not (Text.null s) -> Just s
        _ -> Nothing
      url = case lookupTableScalar "url" snapTable of
        Just (TomlString s) | not (Text.null s) -> Just s
        _ -> Nothing
  deps <- case lookupTableScalar "dependencies" snapTable of
    Nothing -> Right []
    Just (TomlArray xs) -> traverse (expectDepName path) xs
    Just _ ->
      Left
        ( ConfigValidationError
            path
            "[snapshot].dependencies must be an array of strings"
        )
  Right
    SnapshotSection
      { snapshotVersion = ver,
        snapshotUrl = url,
        snapshotDependencies = deps
      }

expectDepName :: FilePath -> TomlValue -> Either ConfigError Text
expectDepName path = \case
  TomlString s | not (Text.null s) -> Right s
  _ -> Left (ConfigValidationError path "expected non-empty string in [snapshot].dependencies")

-- | Walk every @[overrides.<name>]@ section. Each must point at exactly
-- one source: @path@ or @git@+@rev@. Names found here that are not in
-- @snapshotDependencies@ produce a validation error (= a dead override
-- is almost always a typo).
parseOverrides ::
  FilePath ->
  TomlTable ->
  [Text] ->
  Either ConfigError (Map Text OverrideSource)
parseOverrides path (TomlTable buckets) declared = do
  pairs <- traverse fromEntry overrideEntries
  let names = map fst pairs
      orphan = filter (`notElem` declared) names
  case orphan of
    (n : _) ->
      Left
        ( ConfigValidationError
            path
            ( "[overrides."
                <> n
                <> "] is declared but does not appear in [snapshot].dependencies"
            )
        )
    [] -> Right (Map.fromList pairs)
  where
    prefix = "overrides."
    overrideEntries =
      [ (Text.drop (Text.length prefix) sec, bucket)
        | (sec, bucket) <- Map.toList buckets,
          prefix `Text.isPrefixOf` sec,
          sec /= "overrides"
      ]

    fromEntry (depName, bucket) = do
      tbl <- case bucket of
        BucketTable t -> Right t
        BucketScalar _ ->
          Left
            ( ConfigValidationError
                path
                ( "expected table at [overrides."
                    <> depName
                    <> "], got scalar"
                )
            )
      src <- parseOverrideTable path depName tbl
      Right (depName, src)

parseOverrideTable ::
  FilePath ->
  Text ->
  Map Text TomlValue ->
  Either ConfigError OverrideSource
parseOverrideTable path depName tbl =
  case (Map.lookup "path" tbl, Map.lookup "git" tbl) of
    (Just (TomlString p), Nothing) | not (Text.null p) ->
      Right (OverridePath (Text.unpack p))
    (Nothing, Just (TomlString u)) | not (Text.null u) ->
      case Map.lookup "rev" tbl of
        Just (TomlString r) | not (Text.null r) ->
          Right OverrideGit {gitUrl = u, gitRev = r}
        _ ->
          Left
            ( ConfigValidationError
                path
                ( "[overrides."
                    <> depName
                    <> "] is git source but missing required 'rev = \"<sha>\"'"
                )
            )
    (Just _, Just _) ->
      Left
        ( ConfigValidationError
            path
            ( "[overrides."
                <> depName
                <> "] must use 'path' XOR 'git', not both"
            )
        )
    _ ->
      Left
        ( ConfigValidationError
            path
            ( "[overrides."
                <> depName
                <> "] must specify either 'path = \"...\"' or 'git = \"...\" rev = \"...\"'"
            )
        )

-- ===========================================================================
-- TOML reader (minimal, flat, single-level tables)
-- ===========================================================================

data TomlValue
  = TomlString Text
  | TomlArray [TomlValue]
  | TomlBool Bool
  | TomlInt Integer
  deriving (Show, Eq)

-- | Either a top-level scalar or a nested table. We only handle one level
-- of nesting because @katari.toml@ never goes deeper.
data TomlBucket
  = BucketScalar TomlValue
  | BucketTable (Map Text TomlValue)
  deriving (Show, Eq)

newtype TomlTable = TomlTable (Map Text TomlBucket)
  deriving (Show, Eq)

lookupScalar :: Text -> TomlTable -> Maybe TomlValue
lookupScalar k (TomlTable m) = case Map.lookup k m of
  Just (BucketScalar v) -> Just v
  _ -> Nothing

lookupTable :: Text -> TomlTable -> Map Text TomlValue
lookupTable k (TomlTable m) = case Map.lookup k m of
  Just (BucketTable t) -> t
  _ -> Map.empty

lookupTableScalar :: Text -> Map Text TomlValue -> Maybe TomlValue
lookupTableScalar = Map.lookup

parseTomlText :: Text -> Either (Int, Text) TomlTable
parseTomlText src =
  let ls = zip [1 ..] (Text.lines src)
   in go ls Nothing (TomlTable Map.empty)
  where
    go :: [(Int, Text)] -> Maybe Text -> TomlTable -> Either (Int, Text) TomlTable
    go [] _ acc = Right acc
    go ((n, raw) : rest) currentSection acc =
      let line = Text.strip (stripComment raw)
       in if Text.null line
            then go rest currentSection acc
            else case parseLine n line of
              Left e -> Left e
              Right (LineSection name) -> go rest (Just name) acc
              Right (LineAssignment key val) ->
                case currentSection of
                  Nothing -> go rest Nothing (insertScalar key val acc)
                  Just sec -> go rest currentSection (insertNested sec key val acc)

    insertScalar :: Text -> TomlValue -> TomlTable -> TomlTable
    insertScalar k v (TomlTable m) =
      TomlTable (Map.insert k (BucketScalar v) m)

    insertNested :: Text -> Text -> TomlValue -> TomlTable -> TomlTable
    insertNested sec k v (TomlTable m) =
      let inner = case Map.lookup sec m of
            Just (BucketTable t) -> t
            _ -> Map.empty
       in TomlTable (Map.insert sec (BucketTable (Map.insert k v inner)) m)

data ParsedLine
  = LineSection Text
  | LineAssignment Text TomlValue

parseLine :: Int -> Text -> Either (Int, Text) ParsedLine
parseLine n line
  | Just rest <- Text.stripPrefix "[" line,
    Just inner <- Text.stripSuffix "]" rest =
      let name = Text.strip inner
       in if Text.null name
            then Left (n, "empty section name")
            else Right (LineSection name)
  | otherwise =
      let (kRaw, eqVal) = Text.breakOn "=" line
       in if Text.null eqVal
            then Left (n, "expected '=' in '" <> line <> "'")
            else
              let key = Text.strip kRaw
                  valTxt = Text.strip (Text.drop 1 eqVal)
               in if Text.null key
                    then Left (n, "empty key")
                    else case parseValue n valTxt of
                      Left e -> Left e
                      Right v -> Right (LineAssignment key v)

parseValue :: Int -> Text -> Either (Int, Text) TomlValue
parseValue n txt
  | Text.null txt = Left (n, "empty value")
  | Just inner <- stripQuotes '"' txt = Right (TomlString inner)
  | Just inner <- stripQuotes '\'' txt = Right (TomlString inner)
  | txt == "true" = Right (TomlBool True)
  | txt == "false" = Right (TomlBool False)
  | Just rest <- Text.stripPrefix "[" txt,
    Just inner <- Text.stripSuffix "]" rest =
      parseArray n inner
  | Right i <- parseIntegerStrict txt = Right (TomlInt i)
  | otherwise = Left (n, "unrecognised value: " <> txt)

parseArray :: Int -> Text -> Either (Int, Text) TomlValue
parseArray n inner =
  let trimmed = Text.strip inner
   in if Text.null trimmed
        then Right (TomlArray [])
        else do
          parts <- splitTopLevelCommas n trimmed
          vals <- traverse (parseValue n . Text.strip) parts
          Right (TomlArray vals)

-- | Split on commas not inside a quoted string. Adequate for our subset
-- (no nested brackets, no escaped quotes).
splitTopLevelCommas :: Int -> Text -> Either (Int, Text) [Text]
splitTopLevelCommas n s = go (Text.unpack s) [] [] Nothing
  where
    go :: String -> String -> [String] -> Maybe Char -> Either (Int, Text) [Text]
    go [] cur acc Nothing = Right (reverse (map (Text.pack . reverse) (cur : acc)))
    go [] _ _ (Just _) = Left (n, "unterminated string in array")
    go (c : rest) cur acc Nothing
      | c == ',' = go rest [] (cur : acc) Nothing
      | c == '"' || c == '\'' = go rest (c : cur) acc (Just c)
      | otherwise = go rest (c : cur) acc Nothing
    go (c : rest) cur acc (Just q)
      | c == q = go rest (c : cur) acc Nothing
      | otherwise = go rest (c : cur) acc (Just q)

stripQuotes :: Char -> Text -> Maybe Text
stripQuotes q txt = do
  s1 <- Text.stripPrefix (Text.singleton q) txt
  Text.stripSuffix (Text.singleton q) s1

-- | Strip everything from the first unquoted @#@ to end-of-line.
stripComment :: Text -> Text
stripComment t = Text.pack (go (Text.unpack t) [] Nothing)
  where
    go :: String -> String -> Maybe Char -> String
    go [] acc _ = reverse acc
    go (c : rest) acc Nothing
      | c == '#' = reverse acc
      | c == '"' || c == '\'' = go rest (c : acc) (Just c)
      | otherwise = go rest (c : acc) Nothing
    go (c : rest) acc (Just q)
      | c == q = go rest (c : acc) Nothing
      | otherwise = go rest (c : acc) (Just q)

parseIntegerStrict :: Text -> Either Text Integer
parseIntegerStrict t = case reads (Text.unpack t) :: [(Integer, String)] of
  [(i, "")] -> Right i
  _ -> Left ("not an integer: " <> t)

-- ===========================================================================
-- Helpers
-- ===========================================================================

mapLeft :: (a -> c) -> Either a b -> Either c b
mapLeft f = either (Left . f) Right
