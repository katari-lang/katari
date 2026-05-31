-- | @katari run [qualifiedName]@ — start a run on the runtime.
--
-- Two modes:
--
--   * @--args JSON@ supplied (or all parameters are optional): runs
--     non-interactively.
--   * Otherwise: drops into the interactive prompt — pick the agent
--     def from a numbered menu, walk its JSON Schema asking for each
--     parameter, and confirm before POSTing.
module Katari.Cli.Run
  ( Options (..),
    optionsParser,
    run,
  )
where

import Control.Concurrent (threadDelay)
import Data.Aeson qualified as Aeson
import Data.Aeson.Encode.Pretty qualified as Pretty
import Data.Aeson.Key qualified as AesonKey
import Data.Aeson.KeyMap qualified as AesonKM
import Data.ByteString.Lazy.Char8 qualified as LC8
import Data.Char (isAsciiUpper)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Scientific qualified as Scientific
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Katari.Api.Client qualified as Api
import Katari.Api.Types qualified as Api
import Katari.Cli.Common qualified as Common
import Katari.Cli.Status qualified as Status
import Katari.Project.Config qualified as Project
import Options.Applicative
import System.Exit (ExitCode (..), exitWith)
import System.IO (hFlush, hPutStr, hPutStrLn, stderr, stdout)
import Text.Read (readMaybe)

data Options = Options
  { optQualifiedName :: Maybe Text,
    optProject :: Maybe Text,
    optSnapshot :: Maybe Text,
    optName :: Maybe Text,
    optArgs :: Maybe Text,
    optWait :: Bool,
    optApiUrl :: Maybe Text
  }
  deriving (Show)

optionsParser :: Parser Options
optionsParser =
  Options
    <$> optional
      ( argument
          str
          ( metavar "QUALIFIED_NAME"
              <> help "Agent qualified name, e.g. 'hello.main' (omit to pick interactively)"
          )
      )
    <*> optional
      ( strOption
          ( long "project"
              <> short 'p'
              <> metavar "NAME"
              <> help "Project to invoke under (defaults to the surrounding katari.toml's [package].name)"
          )
      )
    <*> optional (strOption (long "snapshot" <> short 's' <> metavar "ID" <> help "Pin to a snapshot id (else use the latest)"))
    <*> optional
      ( strOption
          ( long "as"
              <> metavar "NAME"
              <> help "Operator-supplied label for this run (shown in `katari ls runs` / admin UI)"
          )
      )
    <*> optional
      ( strOption
          ( long "args"
              <> metavar "JSON"
              <> help "Argument record as JSON, e.g. '{\"x\":1}' (default: {})"
          )
      )
    <*> switch (long "wait" <> help "Poll until the run finishes; print its result")
    <*> optional (strOption (long "api-url" <> metavar "URL" <> help "Override [runtime].url"))

run :: Options -> IO ()
run opts = do
  cfg <- Common.tryLoadProjectConfig
  client <- Common.resolveApiClient "run" opts.optApiUrl
  let nameFromCfg :: Project.ProjectConfig -> Text
      nameFromCfg c = c.packageSection.packageName
  projectName <- case opts.optProject <|> fmap nameFromCfg cfg of
    Just p -> pure p
    Nothing -> die "no --project and no surrounding katari.toml found"
  proj <- Common.resolveProjectId "run" client projectName

  -- Resolve qualified name (interactive picker if absent), and
  -- gather args (from --args JSON, otherwise walk the schema).
  (qname, args) <- resolveQualifiedNameAndArgs client proj opts

  runId <-
    Api.startRun
      client
      Api.StartRunRequest
        { Api.projectId = proj,
          Api.snapshotId = opts.optSnapshot,
          Api.qualifiedName = qname,
          Api.name = opts.optName,
          Api.args = args
        }
  hPutStrLn stderr ("Started " <> Text.unpack runId)
  if opts.optWait
    then pollUntilDone client runId
    else
      hPutStrLn
        stderr
        ("(re-run with --wait, or `katari status " <> Text.unpack runId <> "` to inspect)")

-- | Choose @(qualifiedName, args)@ via:
--
--   1. If @--args@ given AND @qualifiedName@ given, use both verbatim.
--   2. If @qualifiedName@ given but @--args@ missing, fetch its
--      definition and prompt the user through the schema.
--   3. If @qualifiedName@ missing, fetch every agent def, let the
--      user pick, then prompt for args (or use the supplied @--args@
--      if provided).
resolveQualifiedNameAndArgs ::
  Api.ApiClient ->
  Text ->
  Options ->
  IO (Text, Map Text Aeson.Value)
resolveQualifiedNameAndArgs client projectId opts = do
  case (opts.optQualifiedName, opts.optArgs) of
    (Just qn, Just argsJson) -> do
      args <- decodeArgsJson argsJson
      pure (qn, args)
    (Just qn, Nothing) -> do
      def <- findDefinition client projectId opts.optSnapshot qn
      args <- promptArgs def
      pure (qn, args)
    (Nothing, _) -> do
      (defs, _snapId) <-
        Api.listAgents client projectId opts.optSnapshot
      case defs of
        [] -> die "no agent definitions on this snapshot (did you run `katari apply`?)"
        _ -> do
          mDef <- pickFromList "Pick an agent:" defs renderDefLabel
          case mDef of
            Nothing -> die "nothing to pick"
            Just def -> do
              args <- case opts.optArgs of
                Just argsJson -> decodeArgsJson argsJson
                Nothing -> promptArgs def
              pure (def.qualifiedName, args)
  where
    renderDefLabel d = case d.description of
      Just desc -> d.qualifiedName <> "  — " <> desc
      Nothing -> d.qualifiedName

findDefinition ::
  Api.ApiClient ->
  Text ->
  Maybe Text ->
  Text ->
  IO Api.AgentDefinition
findDefinition client projectId snap qname = do
  (defs, _) <- Api.listAgents client projectId snap
  case filter (\d -> d.qualifiedName == qname) defs of
    [d] -> pure d
    [] -> die ("agent '" <> Text.unpack qname <> "' not found in this snapshot")
    multi -> die ("multiple agent defs named '" <> Text.unpack qname <> "' (" <> show (length multi) <> ")")

-- | Walk the agent's @parameters@ JSON Schema to gather an args object,
-- then confirm. Aborts if the user declines.
promptArgs :: Api.AgentDefinition -> IO (Map Text Aeson.Value)
promptArgs def = do
  hPutStrLn stderr ("Agent: " <> Text.unpack def.qualifiedName)
  argsValue <- promptForSchema [] def.parameters
  ok <- confirmAndProceed argsValue
  if not ok
    then die "user cancelled"
    else case argsValue of
      Aeson.Object o ->
        pure (Map.fromList [(AesonKey.toText k, v) | (k, v) <- AesonKM.toList o])
      _ -> die "expected the schema's top-level shape to be an object"

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

die :: String -> IO a
die = Common.dieIn "run"

decodeArgsJson :: Text -> IO (Map Text Aeson.Value)
decodeArgsJson s = case Common.decodeJsonText s of
  Right (Aeson.Object o) ->
    pure (Map.fromList [(AesonKey.toText k, v) | (k, v) <- AesonKM.toList o])
  Right _ -> die "--args must be a JSON object"
  Left err -> die ("--args is not valid JSON: " <> err)

pollUntilDone :: Api.ApiClient -> Text -> IO ()
pollUntilDone client runId = loop (50_000 :: Int)
  where
    -- Exponential backoff capped at 2 s. We deliberately have no overall
    -- timeout: a `katari run` invocation blocks until the run finishes
    -- (or the user hits Ctrl-C). Earlier versions of this loop gave up
    -- after 20 s of polling, which surprised users running long runs.
    maxDelay = 2_000_000 :: Int
    loop delay = do
      row <- Api.getRun client runId
      case row.state of
        Api.RunRunning -> threadDelay delay >> loop (min maxDelay (delay * 2))
        Api.RunCancelling -> threadDelay delay >> loop (min maxDelay (delay * 2))
        -- Pretty block on stderr so a downstream `| jq` keeps working
        -- on the bare result on stdout.
        done -> do
          hPutStr stderr (Text.unpack (Status.renderRunDetailed row))
          case done of
            Api.RunDone -> case row.result of
              Just v -> LC8.putStrLn (Aeson.encode v)
              Nothing -> pure ()
            Api.RunError -> exitWith (ExitFailure 1)
            _ -> pure ()

-- ---------------------------------------------------------------------------
-- Prompt helpers (inlined from the former Katari.Cli.Prompt module)
-- ---------------------------------------------------------------------------

pickFromList :: Text -> [a] -> (a -> Text) -> IO (Maybe a)
pickFromList title items render = case items of
  [] -> do
    putStrLn (Text.unpack title <> ": (nothing to choose from)")
    pure Nothing
  _ -> do
    putStrLn (Text.unpack title)
    let indexed = zip [1 :: Int ..] items
    mapM_ (\(i, x) -> putStrLn ("  " <> show i <> ". " <> Text.unpack (render x))) indexed
    Just <$> loop indexed
  where
    loop indexed = do
      putStr "> "
      hFlush stdout
      ln <- getLine
      case readMaybe ln :: Maybe Int of
        Just n
          | Just x <- lookup n indexed -> pure x
          | otherwise -> do
              putStrLn ("Out of range: " <> show n)
              loop indexed
        Nothing -> do
          putStrLn "Please enter a number from the list."
          loop indexed

promptYesNo :: Text -> Bool -> IO Bool
promptYesNo title defaultValue = do
  putStr (Text.unpack title <> " " <> (if defaultValue then "[Y/n] " else "[y/N] "))
  hFlush stdout
  ln <- getLine
  pure $ case map toLowerAscii (trim ln) of
    "" -> defaultValue
    "y" -> True
    "yes" -> True
    "n" -> False
    "no" -> False
    _ -> defaultValue
  where
    trim = dropWhile (== ' ') . reverse . dropWhile (== ' ') . reverse
    toLowerAscii c
      | isAsciiUpper c = toEnum (fromEnum c + 32)
      | otherwise = c

promptForSchema :: [Text] -> Aeson.Value -> IO Aeson.Value
promptForSchema path schema = case schema of
  Aeson.Object o -> promptForObjectSchema path o
  _ -> do
    putStrLn ("(non-object schema; please enter raw JSON for " <> pathLabel path <> ")")
    promptForRawJson path

promptForObjectSchema :: [Text] -> AesonKM.KeyMap Aeson.Value -> IO Aeson.Value
promptForObjectSchema path o = case AesonKM.lookup "enum" o of
  Just (Aeson.Array vs) -> promptForEnum path (Vector.toList vs)
  _ -> case AesonKM.lookup "type" o of
    Just (Aeson.String t) -> promptForType path t o
    _ -> do
      putStrLn ("(schema has no concrete 'type'; please enter raw JSON for " <> pathLabel path <> ")")
      promptForRawJson path

promptForType :: [Text] -> Text -> AesonKM.KeyMap Aeson.Value -> IO Aeson.Value
promptForType path ty o = case ty of
  "object" -> promptForObject path (childProperties o)
  "array" -> promptForArray path (childItems o)
  "string" -> promptForString path o
  "integer" -> promptForInteger path
  "number" -> promptForNumber path
  "boolean" -> Aeson.Bool <$> promptYesNo (Text.pack (pathLabel path) <> " (boolean):") False
  "null" -> pure Aeson.Null
  other -> do
    putStrLn ("(unrecognised type '" <> Text.unpack other <> "', please enter raw JSON)")
    promptForRawJson path

promptForObject :: [Text] -> [(Text, Aeson.Value)] -> IO Aeson.Value
promptForObject path props = do
  pairs <- traverse one props
  pure (Aeson.Object (AesonKM.fromList [(AesonKey.fromText k, v) | (k, v) <- pairs]))
  where
    one (k, sub) = do
      v <- promptForSchema (path <> [k]) sub
      pure (k, v)

childProperties :: AesonKM.KeyMap Aeson.Value -> [(Text, Aeson.Value)]
childProperties o = case AesonKM.lookup "properties" o of
  Just (Aeson.Object props) ->
    [(AesonKey.toText k, v) | (k, v) <- AesonKM.toAscList props]
  _ -> []

promptForArray :: [Text] -> Aeson.Value -> IO Aeson.Value
promptForArray path itemSchema = do
  n <- askLength
  vs <- mapM (\i -> promptForSchema (path <> [Text.pack ("[" <> show i <> "]")]) itemSchema) [0 .. n - 1]
  pure (Aeson.Array (Vector.fromList vs))
  where
    askLength = do
      putStr (pathLabel path <> " (array) length: ")
      hFlush stdout
      ln <- getLine
      case readMaybe ln :: Maybe Int of
        Just k | k >= 0 -> pure k
        _ -> do
          putStrLn "Please enter a non-negative integer."
          askLength

childItems :: AesonKM.KeyMap Aeson.Value -> Aeson.Value
childItems o = case AesonKM.lookup "items" o of
  Just v -> v
  Nothing -> Aeson.Object AesonKM.empty

promptForString :: [Text] -> AesonKM.KeyMap Aeson.Value -> IO Aeson.Value
promptForString path o = do
  putStr (pathLabel path <> " (string): ")
  hFlush stdout
  ln <- getLine
  case AesonKM.lookup "const" o of
    Just (Aeson.String s) -> pure (Aeson.String s)
    _ -> pure (Aeson.String (Text.pack ln))

promptForInteger :: [Text] -> IO Aeson.Value
promptForInteger path = loop
  where
    loop = do
      putStr (pathLabel path <> " (integer): ")
      hFlush stdout
      ln <- getLine
      case readMaybe ln :: Maybe Integer of
        Just n -> pure (Aeson.Number (fromInteger n))
        Nothing -> do
          putStrLn "Not a valid integer."
          loop

promptForNumber :: [Text] -> IO Aeson.Value
promptForNumber path = loop
  where
    loop = do
      putStr (pathLabel path <> " (number): ")
      hFlush stdout
      ln <- getLine
      case readMaybe ln :: Maybe Double of
        Just n -> pure (Aeson.Number (Scientific.fromFloatDigits n))
        Nothing -> do
          putStrLn "Not a valid number."
          loop

promptForEnum :: [Text] -> [Aeson.Value] -> IO Aeson.Value
promptForEnum path choices = do
  picked <- pickFromList (Text.pack (pathLabel path) <> " (enum)") choices renderChoice
  case picked of
    Just v -> pure v
    Nothing -> pure Aeson.Null
  where
    renderChoice = Text.pack . LC8.unpack . Aeson.encode

promptForRawJson :: [Text] -> IO Aeson.Value
promptForRawJson path = loop
  where
    loop = do
      putStr (pathLabel path <> " (JSON): ")
      hFlush stdout
      ln <- getLine
      case Aeson.eitherDecode (LC8.pack ln) of
        Right v -> pure v
        Left err -> do
          putStrLn ("Invalid JSON: " <> err)
          loop

pathLabel :: [Text] -> String
pathLabel [] = "value"
pathLabel xs = Text.unpack (Text.intercalate "." xs)

confirmAndProceed :: Aeson.Value -> IO Bool
confirmAndProceed args = do
  putStrLn "Args:"
  LC8.putStrLn (Pretty.encodePretty args)
  promptYesNo "Run?" True
