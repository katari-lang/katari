-- | @katari ls [TARGET]@ — the read side of every resource, under one verb with uniform flags.
--
-- Targets: @runs@ (the default — the listing reached for most), @agents@, @snapshots@, @projects@,
-- @escalations@, @files@, @env@, @packages@. Human output is an aligned table on stdout; @--json@
-- prints the runtime's payload verbatim. Ids render shortened — every command that takes an id accepts
-- a unique prefix, so the 8-character form is directly usable.
--
-- @packages@ is the one target that reads the REGISTRY rather than the runtime: it answers "what can
-- I @katari add@", which until it existed had no answer short of opening the registry repository's
-- TOML by hand. It lives here rather than under a verb of its own because @ls@ is already where a
-- user looks to find out what exists, and a second listing verb would mean learning two — the cost is
-- one branch that builds no runtime client, which @projects@ already establishes is allowed. Its
-- @--json@ is synthesized (there is no runtime payload to pass through), and is the shape a script
-- would feed back into @katari add@.
module Katari.Cli.Command.Ls
  ( Options (..),
    optionsParser,
    run,
    PackageRow (..),
    packageRows,
    packageVersionCell,
    packageStatusCell,
  )
where

import Data.Aeson (Value (..))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import GHC.List (List)
import Katari.Cli.Api
  ( AgentView (..),
    AgentsResponse (..),
    EnvEntry (..),
    EscalationPresentation (..),
    EscalationView (..),
    FileRow (..),
    ProjectRow (..),
    RunDetail (..),
    RunListQuery (..),
    SnapshotRow (..),
    listAgents,
    listEnv,
    listEscalations,
    listFiles,
    listProjects,
    listRuns,
    listSnapshots,
    oauthTargetDescription,
    parseRunState,
    runStateLabel,
  )
import Katari.Cli.Common (RuntimeContext (..), dieIn, isPreludeName, makeRuntimeClient, resolveProjectRoot, tryLoadNearestConfig, withRuntimeContext)
import Katari.Cli.Options (GlobalOptions, globalOptionsParser)
import Katari.Cli.Output (compactTimestamp, newOutputContext, printJson, printText, renderTable)
import Katari.Cli.Prompt (compactJson, renderSchemaBrief)
import Katari.Data.JSONSchema (JSONSchema)
import Katari.Project.Config (DependenciesSection (..), ProjectConfig (..), loadKatariTomlLenient)
import Katari.Project.Discovery (configFilename)
import Katari.Project.Error (renderProjectError)
import Katari.Project.Lockfile (Lockfile (..), loadLockfile, lockfileFilename)
import Katari.Project.Snapshot (Snapshot (..), SnapshotEntry (..), loadSnapshotFromUrl)
import Network.HTTP.Client.TLS (newTlsManager)
import Options.Applicative
import System.Directory (doesFileExist)
import System.FilePath ((</>))

-- | What to list.
data Target
  = TargetRuns
  | TargetAgents
  | TargetSnapshots
  | TargetProjects
  | TargetEscalations
  | TargetFiles
  | TargetEnv
  | TargetPackages
  deriving stock (Show, Eq)

data Options = Options
  { global :: GlobalOptions,
    projectName :: Maybe Text,
    target :: Maybe Text,
    json :: Bool,
    -- | @runs@ only: restrict to one lifecycle state.
    state :: Maybe Text,
    -- | @runs@ only: how many to show (newest first).
    limit :: Maybe Int,
    -- | @agents@ only: include the @prelude.*@ stdlib callables.
    includePrimitives :: Bool,
    -- | @agents@ only: read a pinned snapshot instead of the head.
    snapshotId :: Maybe Text
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
              <> help "Project to list under (default: the surrounding katari.toml's [package].name)"
          )
      )
    <*> optional
      ( strArgument
          ( metavar "TARGET"
              <> help "One of: runs (default), agents, snapshots, projects, escalations, files, env, packages"
          )
      )
    <*> switch (long "json" <> help "Print the runtime's JSON payload instead of a table")
    <*> optional (strOption (long "state" <> metavar "STATE" <> help "runs: only this state (running|cancelling|done|error|cancelled)"))
    <*> optional (option auto (long "limit" <> metavar "N" <> help "runs: show at most N, newest first (default 20)"))
    <*> switch (long "all" <> help "agents: include prelude.* callables")
    <*> optional (strOption (long "snapshot" <> short 's' <> metavar "ID" <> help "agents: read this snapshot instead of the head"))

run :: Options -> IO ()
run options = do
  target <- parseTarget (fromMaybe "runs" options.target)
  case target of
    -- The registry listing never reaches the runtime at all: it answers from the project's pinned
    -- snapshot plus its lock, so it works with nothing deployed and no KATARI_API_KEY set.
    TargetPackages -> listRegistryPackages options
    -- Listing projects is the one target that must work before any project is deployed, so it wires
    -- its own client instead of resolving a project id.
    TargetProjects -> do
      output <- newOutputContext options.global
      config <- tryLoadNearestConfig "ls"
      client <- makeRuntimeClient "ls" options.global output config
      (raw, projects) <- listProjects client
      emit options raw $
        table
          ["ID", "NAME", "DESCRIPTION", "CREATED"]
          [[shortId project.id, project.name, fromMaybe "" project.description, compactTimestamp (fromMaybe "" project.createdAt)] | project <- projects]
    _ -> do
      context <- withRuntimeContext "ls" options.global options.projectName
      case target of
        TargetRuns -> do
          (raw, runs) <-
            listRuns context.client context.projectId RunListQuery {state = fmap parseRunState options.state, limit = Just (fromMaybe 20 options.limit)}
          emit options raw $
            table
              ["ID", "STATE", "AGENT", "NAME", "CREATED", "COMPLETED"]
              [ [shortId row.id, runStateLabel row.state, row.qualifiedName, row.name, compactTimestamp row.createdAt, maybe "" compactTimestamp row.completedAt]
                | row <- runs
              ]
        TargetAgents -> do
          (raw, response) <- listAgents context.client context.projectId options.snapshotId
          -- Apply the prelude/@--all@ filter to both output modes: the JSON path must agree with the
          -- table, so machine consumers get the same set and @--all@ has an effect under @--json@.
          let visibleName name = options.includePrimitives || not (isPreludeName name)
              agents = [view | view <- response.agents, visibleName view.qualifiedName]
          emit options (filterAgentsPayload visibleName raw) $
            table
              ["AGENT", "INPUT", "OUTPUT"]
              [[view.qualifiedName, briefSchema view.input, briefSchema view.output] | view <- agents]
        TargetSnapshots -> do
          (raw, snapshots) <- listSnapshots context.client context.projectId
          emit options raw $
            table
              ["ID", "MESSAGE", "CREATED"]
              [[shortId row.id, fromMaybe "" row.message, compactTimestamp row.createdAt] | row <- snapshots]
        TargetEscalations -> do
          (raw, escalations) <- listEscalations context.client context.projectId
          emit options raw $
            table
              ["ID", "RUN", "REQUEST", "QUESTION", "CREATED"]
              [ let (requestCell, questionCell) = escalationCells row
                 in [shortId row.id, shortId row.runId, requestCell, questionCell, compactTimestamp row.createdAt]
                | row <- escalations
              ]
        TargetFiles -> do
          (raw, files) <- listFiles context.client context.projectId
          emit options raw $
            table
              ["ID", "SIZE", "CONTENT-TYPE", "KIND"]
              [[shortId row.id, Text.pack (show row.size), fromMaybe "" row.contentType, fromMaybe "" row.semanticKind] | row <- files]
        TargetEnv -> do
          (raw, entries) <- listEnv context.client context.projectId
          emit options raw $
            table
              ["KEY", "SECRET", "UPDATED"]
              [[entry.key, if entry.isSecret then "yes" else "", compactTimestamp (fromMaybe "" entry.updatedAt)] | entry <- entries]

-- | One addable package, as the listing knows it.
data PackageRow = PackageRow
  { name :: Text,
    -- | The version label the snapshot publishes. 'Nothing' when the name resolves from a root
    --   @[overrides]@ entry (which pins a location, not a released version) or when the snapshot
    --   entry carries no label.
    version :: Maybe Text,
    -- | The name comes from a root @[overrides]@ entry, which outranks the snapshot for it.
    overridden :: Bool,
    -- | Named in @[dependencies].packages@ — already an @import@ away.
    declared :: Bool,
    -- | Present in @katari.lock@ without being declared: pulled in as some dependency's dependency,
    --   so adding it costs no new download.
    inClosure :: Bool
  }
  deriving stock (Show, Eq)

-- | @katari ls packages@ — every package this project could @katari add@, and which it already has.
--
-- The catalogue comes from the REGISTRY SNAPSHOT, never from @katari.lock@: a lock records the
-- resolved closure — what the project already uses — so it cannot name a package the project has not
-- asked for, which is exactly the question here. The lock's job is the other column: it is what
-- distinguishes "not yours" from "already downloaded as somebody else's dependency". The answer is
-- therefore snapshot-specific and needs a project, which is also why there is no registry-wide
-- variant: two projects on different pins legitimately get different answers, and a global listing
-- would name versions neither of them would actually resolve.
listRegistryPackages :: Options -> IO ()
listRegistryPackages options = do
  root <- resolveProjectRoot "ls" Nothing
  -- The lenient load, for the same reason `add` uses it: an [overrides.X] written before X is
  -- declared is the state a user is in when they ask what they can add, and a listing that refuses
  -- there would be a worse answer than the command it feeds.
  config <-
    loadKatariTomlLenient (root </> configFilename) >>= \case
      Left projectError -> dieIn "ls" (renderProjectError projectError)
      Right loaded -> pure loaded
  registry <- case config.dependencies.registry of
    Just registry -> pure registry
    Nothing -> dieIn "ls" "no [dependencies].registry configured, so there is no registry to list"
  -- A registry root with no pin cannot be listed: which packages exist is a property of one cut, and
  -- guessing a cut here would list versions this project would not resolve.
  case config.dependencies.snapshot of
    Just _ -> pure ()
    Nothing -> dieIn "ls" "no [dependencies].snapshot pinned; run `katari update` to pin the registry's newest cut"
  manager <- newTlsManager
  snapshot <-
    loadSnapshotFromUrl manager registry config.dependencies.snapshot >>= \case
      Left projectError -> dieIn "ls" (renderProjectError projectError)
      Right loaded -> pure loaded
  locked <- lockedPackageNames (root </> lockfileFilename)
  let rows = packageRows config snapshot locked
  emit options (packagesPayload config rows) $
    table
      ["PACKAGE", "VERSION", "STATUS"]
      [[row.name, packageVersionCell row, packageStatusCell row] | row <- rows]

-- | The names @katari.lock@ holds, or none when there is no lock / it does not parse. An unreadable
-- lock only costs this listing its "in closure" column, so it is not worth failing a read-only
-- command over.
lockedPackageNames :: FilePath -> IO (Set Text)
lockedPackageNames path = do
  exists <- doesFileExist path
  if not exists
    then pure Set.empty
    else
      loadLockfile path >>= \case
        Left _ -> pure Set.empty
        Right lockfile -> pure (Map.keysSet lockfile.packages)

-- | Every name @katari add@ would accept, name-ordered: the snapshot's packages, plus any root
-- @[overrides]@ entry (an override resolves a name the snapshot never has to carry, so leaving them
-- out would make the listing a lie about what is addable).
packageRows :: ProjectConfig -> Snapshot -> Set Text -> List PackageRow
packageRows config snapshot locked =
  [ PackageRow
      { name = name,
        version = if overridden then Nothing else Map.lookup name snapshot.packages >>= \entry -> entry.version,
        overridden = overridden,
        declared = name `elem` config.dependencies.packages,
        inClosure = Set.member name locked
      }
    | name <- Set.toAscList (Map.keysSet snapshot.packages <> Map.keysSet config.overrides),
      let overridden = Map.member name config.overrides
  ]

-- | The VERSION cell. An override pins a location rather than a release, so it says so instead of
-- borrowing the snapshot's label for a source the project will not fetch.
packageVersionCell :: PackageRow -> Text
packageVersionCell row
  | row.overridden = "(override)"
  | otherwise = fromMaybe "" row.version

-- | The STATUS cell: what this project's relationship to the package already is.
packageStatusCell :: PackageRow -> Text
packageStatusCell row
  | row.declared = "added"
  | row.inClosure = "in closure"
  | otherwise = ""

-- | The @--json@ document. Synthesized rather than passed through (there is no runtime behind this
-- target), and shaped so a script can select names out of it and hand them straight to @katari add@.
packagesPayload :: ProjectConfig -> List PackageRow -> Aeson.Value
packagesPayload config rows =
  Aeson.object
    [ ("registry", Aeson.toJSON config.dependencies.registry),
      ("snapshot", Aeson.toJSON config.dependencies.snapshot),
      ("packages", Aeson.toJSON (map packageObject rows))
    ]
  where
    packageObject row =
      Aeson.object
        [ ("name", Aeson.toJSON row.name),
          ("version", Aeson.toJSON row.version),
          ("overridden", Aeson.toJSON row.overridden),
          ("declared", Aeson.toJSON row.declared),
          ("inClosure", Aeson.toJSON row.inClosure)
        ]

parseTarget :: Text -> IO Target
parseTarget word = case word of
  "runs" -> pure TargetRuns
  "agents" -> pure TargetAgents
  "snapshots" -> pure TargetSnapshots
  "projects" -> pure TargetProjects
  "escalations" -> pure TargetEscalations
  "files" -> pure TargetFiles
  "env" -> pure TargetEnv
  "packages" -> pure TargetPackages
  other -> dieIn "ls" ("unknown target '" <> other <> "' (expected runs, agents, snapshots, projects, escalations, files, env or packages)")

-- | Route to @--json@ (verbatim payload) or the rendered table.
emit :: Options -> Aeson.Value -> Text -> IO ()
emit options raw rendered
  | options.json = printJson raw
  | otherwise = printText rendered

table :: List Text -> List (List Text) -> Text
table = renderTable

shortId :: Text -> Text
shortId = Text.take 8

-- | One cell must not wreck the table: long JSON previews truncate.
preview :: Text -> Text
preview text
  | Text.length text > 40 = Text.take 37 text <> "..."
  | otherwise = text

-- | The REQUEST / QUESTION cells, rendered per presentation kind: an oauth escalation reads as the
-- OAuth authorization it needs (matching status / the picker) rather than leaking the
-- runtime-synthesized request name and its raw argument; a form escalation keeps the request name and
-- a truncated question preview.
escalationCells :: EscalationView -> (Text, Text)
escalationCells row = case row.presentation of
  PresentationOauth {url, name} -> ("OAuth authorization", oauthTargetDescription url name)
  PresentationForm _ -> (row.request, maybe "" (preview . compactJson) row.argument)

-- | A schema cell: the decoded brief form, or a shrug when the document does not decode (version skew).
briefSchema :: Aeson.Value -> Text
briefSchema document = case Aeson.fromJSON document of
  Aeson.Success (schema :: JSONSchema) -> renderSchemaBrief schema
  Aeson.Error _ -> "(unreadable schema)"

-- | Filter the raw agents payload's @agents@ array by the same visibility predicate the table uses,
-- so @--json@ output honours the prelude/@--all@ filter instead of leaking the full stdlib set. Any
-- element the CLI cannot read a @qualifiedName@ off is kept (a filter must not silently drop rows it
-- does not understand).
filterAgentsPayload :: (Text -> Bool) -> Aeson.Value -> Aeson.Value
filterAgentsPayload keepName document = case document of
  Object payload -> case KeyMap.lookup "agents" payload of
    Just (Array agents) -> Object (KeyMap.insert "agents" (Array (Vector.filter keepAgent agents)) payload)
    _ -> document
  _ -> document
  where
    keepAgent agent = case agent of
      Object fields -> case KeyMap.lookup "qualifiedName" fields of
        Just (String name) -> keepName name
        _ -> True
      _ -> True
