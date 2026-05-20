-- | TOML schema and loader for @katari.toml@.
--
-- Layout (v0.1 schema):
--
-- @
-- [package]
-- name = \"hello\"
-- # version = \"0.1.0\"        # optional
-- # src     = \"src\"          # optional, default \"src\"
--
-- [runtime]
-- url = \"http:\/\/localhost:8000\"
--
-- # Optional snapshot block. Both fields are optional; absence of [snapshot]
-- # means \"no snapshot-based resolution\" (every dep must be path / git).
-- # [snapshot]
-- # version = \"2026-05-01\"
-- # url     = \"https:\/\/github.com\/katari-lang\/katari-registry\"
--
-- [dependencies]
-- # list_utils = \"*\"                                       # snapshot pin
-- # my_fork    = { path = \"..\/my_fork\" }                  # local override
-- # upstream   = { git  = \"https:\/\/...\", ref = \"abc\" }  # git override
-- @
--
-- Auth is intentionally NOT a TOML field — @katari.toml@ is commonly
-- committed to VCS, and the auth value is a secret. CLI commands read
-- @KATARI_API_KEY@ from the environment instead.
--
-- The parser is hand-rolled (no @tomland@ dep). Inline tables are
-- supported on the right-hand side of a key=value assignment. Nested
-- sections deeper than one level are not.
module Katari.Project.Config
  ( ProjectConfig (..),
    PackageSection (..),
    SidecarSection (..),
    RuntimeSection (..),
    DependencySource (..),
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
  { -- | Convenience mirror of @packageSection.packageName@.
    projectName :: Text,
    packageSection :: PackageSection,
    sidecarSection :: Maybe SidecarSection,
    runtimeSection :: RuntimeSection,
    -- | Top-level @snapshot = \"...\"@ value, or 'Nothing' if absent.
    snapshotVersion :: Maybe Text,
    -- | Top-level @snapshot_url = \"...\"@ value, or 'Nothing' if absent.
    snapshotUrl :: Maybe Text,
    -- | @[dependencies]@ entries. Each value is one of:
    --
    --   * 'DepSnapshot': @name = \"*\"@ — resolve via the snapshot file.
    --   * 'DepPath': @name = { path = \"...\" }@ — local filesystem source.
    --   * 'DepGit': @name = { git = \"...\", ref = \"...\" }@ — pinned git
    --     commit, fetched as a tarball at resolve time.
    dependencies :: Map Text DependencySource
  }
  deriving (Show, Eq)

data PackageSection = PackageSection
  { packageName :: Text,
    packageVersion :: Maybe Text,
    -- | Relative source dir under the project root. Defaults to @"src"@.
    packageSrc :: FilePath
  }
  deriving (Show, Eq)

newtype SidecarSection = SidecarSection
  { sidecarSourceRoots :: [FilePath]
  }
  deriving (Show, Eq)

newtype RuntimeSection = RuntimeSection
  { runtimeUrl :: Text
  }
  deriving (Show, Eq)

-- | One @[dependencies]@ entry's resolution source.
data DependencySource
  = -- | The dependency is resolved via the snapshot file (@name = \"*\"@).
    DepSnapshot
  | -- | Local filesystem override. Path is interpreted relative to the
    -- @katari.toml@ that declared it.
    DepPath FilePath
  | -- | Pinned git source. Cached under @\~\/.katari\/cache\/git\/\<sha>\/@.
    DepGit
      { gitUrl :: Text,
        gitRev :: Text
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
  let packageTable = lookupTable "package" table
  name <- case lookupTableScalar "name" packageTable of
    Just (TomlString s) | not (Text.null s) -> Right s
    _ ->
      Left
        ( ConfigValidationError
            path
            "required field '[package].name'"
        )
  let version = case lookupTableScalar "version" packageTable of
        Just (TomlString s) | not (Text.null s) -> Just s
        _ -> Nothing
  let src = case lookupTableScalar "src" packageTable of
        Just (TomlString s) | not (Text.null s) -> Text.unpack s
        _ -> "src"
  let sidecarTable = lookupTable "sidecar" table
  sidecar <-
    if Map.null sidecarTable
      then Right Nothing
      else case lookupTableScalar "sourceRoots" sidecarTable of
        Just (TomlArray xs) -> do
          roots <- traverse (expectString path) xs
          Right (Just SidecarSection {sidecarSourceRoots = map Text.unpack roots})
        Just _ ->
          Left
            ( ConfigValidationError
                path
                "'sidecar.sourceRoots' must be an array of strings"
            )
        Nothing -> Right (Just SidecarSection {sidecarSourceRoots = []})
  let runtimeTable = lookupTable "runtime" table
  let url = case lookupTableScalar "url" runtimeTable of
        Just (TomlString s) | not (Text.null s) -> s
        _ -> "http://localhost:8000"
  let snapshotTable = lookupTable "snapshot" table
      snapVer = case lookupTableScalar "version" snapshotTable of
        Just (TomlString s) | not (Text.null s) -> Just s
        _ -> Nothing
      snapUrl = case lookupTableScalar "url" snapshotTable of
        Just (TomlString s) | not (Text.null s) -> Just s
        _ -> Nothing
  deps <- parseDependencies path (lookupTable "dependencies" table)
  Right
    ProjectConfig
      { projectName = name,
        packageSection =
          PackageSection
            { packageName = name,
              packageVersion = version,
              packageSrc = src
            },
        sidecarSection = sidecar,
        runtimeSection = RuntimeSection {runtimeUrl = url},
        snapshotVersion = snapVer,
        snapshotUrl = snapUrl,
        dependencies = deps
      }

expectString :: FilePath -> TomlValue -> Either ConfigError Text
expectString path = \case
  TomlString s -> Right s
  _ -> Left (ConfigValidationError path "expected string in array")

-- | Parse every entry in the @[dependencies]@ table.
parseDependencies ::
  FilePath -> Map Text TomlValue -> Either ConfigError (Map Text DependencySource)
parseDependencies path tbl = Map.fromList <$> traverse one (Map.toList tbl)
  where
    one :: (Text, TomlValue) -> Either ConfigError (Text, DependencySource)
    one (name, value) = do
      src <- parseDepValue path name value
      Right (name, src)

parseDepValue ::
  FilePath -> Text -> TomlValue -> Either ConfigError DependencySource
parseDepValue path name = \case
  TomlString "*" -> Right DepSnapshot
  TomlString other ->
    Left
      ( ConfigValidationError
          path
          ( "[dependencies]."
              <> name
              <> " has unsupported string value \""
              <> other
              <> "\"; expected \"*\" (snapshot pin) or an inline table"
          )
      )
  TomlInlineTable m ->
    case (Map.lookup "path" m, Map.lookup "git" m) of
      (Just (TomlString p), Nothing) | not (Text.null p) ->
        Right (DepPath (Text.unpack p))
      (Nothing, Just (TomlString u)) | not (Text.null u) ->
        case Map.lookup "ref" m of
          Just (TomlString r) | not (Text.null r) ->
            Right DepGit {gitUrl = u, gitRev = r}
          _ ->
            Left
              ( ConfigValidationError
                  path
                  ( "[dependencies]."
                      <> name
                      <> " is git source but missing required 'ref = \"<sha>\"'"
                  )
              )
      (Just _, Just _) ->
        Left
          ( ConfigValidationError
              path
              ( "[dependencies]."
                  <> name
                  <> " must use 'path' XOR 'git', not both"
              )
          )
      _ ->
        Left
          ( ConfigValidationError
              path
              ( "[dependencies]."
                  <> name
                  <> " inline table must specify 'path = \"...\"' or 'git = \"...\" ref = \"...\"'"
              )
          )
  _ ->
    Left
      ( ConfigValidationError
          path
          ( "[dependencies]."
              <> name
              <> " value must be \"*\" or an inline table"
          )
      )

-- ===========================================================================
-- TOML reader (minimal, flat, single-level tables + inline tables)
-- ===========================================================================

data TomlValue
  = TomlString Text
  | TomlArray [TomlValue]
  | TomlBool Bool
  | TomlInt Integer
  | -- | Inline table on the rhs of an assignment: @k = { a = 1, b = 2 }@.
    TomlInlineTable (Map Text TomlValue)
  deriving (Show, Eq)

-- | Either a top-level scalar or a nested table. We only handle one level
-- of nesting because @katari.toml@ never goes deeper.
data TomlBucket
  = BucketScalar TomlValue
  | BucketTable (Map Text TomlValue)
  deriving (Show, Eq)

newtype TomlTable = TomlTable (Map Text TomlBucket)
  deriving (Show, Eq)

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
  | Just rest <- Text.stripPrefix "{" txt,
    Just inner <- Text.stripSuffix "}" rest =
      parseInlineTable n inner
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

parseInlineTable :: Int -> Text -> Either (Int, Text) TomlValue
parseInlineTable n inner =
  let trimmed = Text.strip inner
   in if Text.null trimmed
        then Right (TomlInlineTable Map.empty)
        else do
          parts <- splitTopLevelCommas n trimmed
          entries <- traverse (parseEntry . Text.strip) parts
          Right (TomlInlineTable (Map.fromList entries))
  where
    parseEntry :: Text -> Either (Int, Text) (Text, TomlValue)
    parseEntry s =
      let (kRaw, eqVal) = Text.breakOn "=" s
       in if Text.null eqVal
            then Left (n, "inline-table entry missing '=': " <> s)
            else
              let key = Text.strip kRaw
                  valTxt = Text.strip (Text.drop 1 eqVal)
               in if Text.null key
                    then Left (n, "inline-table empty key")
                    else do
                      v <- parseValue n valTxt
                      Right (key, v)

-- | Split on commas not inside a quoted string or a nested bracket /
-- brace. Adequate for our subset (one level of array / inline-table
-- nesting suffices).
splitTopLevelCommas :: Int -> Text -> Either (Int, Text) [Text]
splitTopLevelCommas n s = go (Text.unpack s) [] [] Nothing 0 0
  where
    go ::
      String ->
      String ->
      [String] ->
      Maybe Char ->
      Int -> -- bracket depth
      Int -> -- brace depth
      Either (Int, Text) [Text]
    go [] cur acc Nothing 0 0 = Right (reverse (map (Text.pack . reverse) (cur : acc)))
    go [] _ _ (Just _) _ _ = Left (n, "unterminated string in nested value")
    go [] _ _ _ b1 b2
      | b1 > 0 = Left (n, "unterminated '[' in nested value")
      | b2 > 0 = Left (n, "unterminated '{' in nested value")
      | otherwise = Left (n, "unbalanced nesting")
    go (c : rest) cur acc Nothing b1 b2
      | c == ',' && b1 == 0 && b2 == 0 = go rest [] (cur : acc) Nothing 0 0
      | c == '"' || c == '\'' = go rest (c : cur) acc (Just c) b1 b2
      | c == '[' = go rest (c : cur) acc Nothing (b1 + 1) b2
      | c == ']' = go rest (c : cur) acc Nothing (b1 - 1) b2
      | c == '{' = go rest (c : cur) acc Nothing b1 (b2 + 1)
      | c == '}' = go rest (c : cur) acc Nothing b1 (b2 - 1)
      | otherwise = go rest (c : cur) acc Nothing b1 b2
    go (c : rest) cur acc (Just q) b1 b2
      | c == q = go rest (c : cur) acc Nothing b1 b2
      | otherwise = go rest (c : cur) acc (Just q) b1 b2

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
