-- | @katari init@ — scaffold a new project.
--
-- Scaffolds in-place inside the current working directory by default.
-- Passing a positional @NAME@ argument only changes the package name;
-- it does NOT create a subdirectory. To scaffold into a fresh
-- subdirectory use the @--dir DIR@ flag.
--
-- Files produced:
--
-- @
-- katari.toml                       -- [package].name = \<name>
-- src/\<name>.ktr                    -- a hello-world template defining @agent main()@
-- docker-compose.yml                -- runtime + Postgres for local dev
-- .env.example                      -- KATARI_API_KEY / KATARI_SECRET_KEY etc.
-- .gitignore                        -- ignores .env, node_modules
-- README.md                         -- quickstart
-- db-init/01-create-databases.sql   -- creates katari_runtime DB on first boot
-- @
--
-- The package name must be a valid Katari identifier
-- (@[A-Za-z_][A-Za-z0-9_]*@). When neither @NAME@ nor @--dir@ is
-- provided, the name defaults to the basename of the current directory
-- (also identifier-validated).
module Katari.Cli.Init
  ( Options (..),
    optionsParser,
    run,
  )
where

import Control.Monad (when)
import Data.Maybe (fromMaybe)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import Katari.Project.Config (isValidPackageName)
import Katari.Version (katariVersion)
import Options.Applicative
import System.Directory
  ( createDirectoryIfMissing,
    doesDirectoryExist,
    doesFileExist,
    getCurrentDirectory,
  )
import System.Exit (ExitCode (..), exitWith)
import System.FilePath
  ( dropTrailingPathSeparator,
    takeDirectory,
    takeFileName,
    (</>),
  )
import System.IO (hPutStrLn, stderr)

data Options = Options
  { -- | Optional package name. When omitted we use the basename of the
    -- target directory (= @cwd@ unless @--dir@ moves it).
    optName :: Maybe String,
    -- | Optional subdirectory to scaffold into. When 'Nothing', the
    -- scaffold lands in the current working directory in place.
    optDir :: Maybe FilePath
  }
  deriving (Show)

optionsParser :: Parser Options
optionsParser =
  Options
    <$> optional
      ( argument
          str
          ( metavar "NAME"
              <> help "Package name (defaults to the target directory's basename)"
          )
      )
    <*> optional
      ( strOption
          ( long "dir"
              <> metavar "DIR"
              <> help "Scaffold into ./DIR/ instead of the current directory (DIR must be empty or absent)"
          )
      )

run :: Options -> IO ()
run opts = do
  (targetDir, packageName) <- resolveTarget opts
  case validateName packageName of
    Just err -> do
      hPutStrLn stderr ("katari init: " <> err)
      exitWith (ExitFailure 2)
    Nothing -> pure ()
  createDirectoryIfMissing True (targetDir </> "src")
  writeIfAbsent (targetDir </> "katari.toml") (katariTomlTemplate packageName)
  writeIfAbsent
    (targetDir </> "src" </> packageName <> ".ktr")
    (entryKtrTemplate packageName)
  writeIfAbsent (targetDir </> "docker-compose.yml") (dockerComposeTemplate packageName imageTag)
  writeIfAbsent (targetDir </> ".env.example") envExampleTemplate
  writeIfAbsent (targetDir </> ".gitignore") gitignoreTemplate
  writeIfAbsent (targetDir </> "README.md") (readmeTemplate packageName)
  writeIfAbsent
    (targetDir </> "db-init" </> "01-create-databases.sql")
    dbInitSqlTemplate
  putStrLn ("Scaffolded " <> packageName <> " at " <> targetDir)

-- | The katari runtime image tag baked into the scaffolded
-- @docker-compose.yml@. Always the same string as 'katariVersion'
-- (= the build's @RELEASE_VERSION@) so that a CLI built from tag
-- @vX.Y.Z[-pre]@ pins the matching GHCR image. Developer builds carry
-- the literal @"0.0.0-dev"@; pinning that intentionally yields a
-- @manifest not found@ on @docker compose up@ so dev binaries never
-- masquerade as a real release.
imageTag :: String
imageTag = katariVersion

-- | Resolve @(targetDir, packageName)@ from the parsed options.
--
-- * @--dir DIR@ chooses the target directory (refusing to clobber a
--   non-empty one); without it the cwd is used in place.
-- * The positional @NAME@ sets the package name when present;
--   otherwise the target directory's basename becomes the name.
resolveTarget :: Options -> IO (FilePath, String)
resolveTarget opts = do
  targetDir <- case opts.optDir of
    Just dir -> do
      exists <- doesDirectoryExist dir
      nonEmpty <- if exists then hasKatariProject dir else pure False
      when nonEmpty $ do
        hPutStrLn stderr ("katari init: refusing to scaffold into non-empty directory '" <> dir <> "'")
        exitWith (ExitFailure 2)
      pure dir
    Nothing -> getCurrentDirectory
  let derivedName = takeFileName (dropTrailingPathSeparator targetDir)
  pure (targetDir, fromMaybe derivedName opts.optName)

-- | Check whether a directory already contains a Katari project
-- (i.e. has @katari.toml@ or a @src/@ subdirectory).
hasKatariProject :: FilePath -> IO Bool
hasKatariProject path = do
  hasToml <- doesFileExist (path </> "katari.toml")
  hasSrc <- doesDirectoryExist (path </> "src")
  pure (hasToml || hasSrc)

-- | Validate that a string is a legal Katari identifier. Delegates to
-- 'Katari.Project.Config.isValidPackageName' for the actual check.
validateName :: String -> Maybe String
validateName name
  | isValidPackageName (Text.pack name) = Nothing
  | otherwise = Just "package name must match [A-Za-z_][A-Za-z0-9_]*"

-- | Write @path@ with @contents@ unless something already exists there.
-- Existing files are left alone (= partial scaffolds are idempotent).
-- Ensures the parent directory exists so callers can drop files into
-- subdirectories (e.g. @db-init\/...@) without a separate mkdir step.
writeIfAbsent :: FilePath -> String -> IO ()
writeIfAbsent path contents = do
  exists <- doesFileExist path
  if exists
    then hPutStrLn stderr ("katari init: skipped existing " <> path)
    else do
      createDirectoryIfMissing True (takeDirectory path)
      TextIO.writeFile path (Text.pack contents)

katariTomlTemplate :: String -> String
katariTomlTemplate name =
  unlines
    [ "[package]",
      "name = \"" <> name <> "\"",
      "version = \"0.1.0\"",
      "description = \"\"",
      "",
      "[runtime]",
      "url = \"http://localhost:8000\"",
      "",
      "[dependencies]",
      "# registry = \"https://github.com/katari-lang/katari-registry\"",
      "# snapshot = \"v0.1.0\"",
      "packages = []",
      "",
      "# [overrides.my_fork]",
      "# path = \"../my_fork\"",
      "#",
      "# [overrides.upstream]",
      "# git = \"https://github.com/...\"",
      "# ref = \"<full 40-hex commit sha>\""
    ]

entryKtrTemplate :: String -> String
entryKtrTemplate name =
  unlines
    [ "@\"Entry point for the '" <> name <> "' package.\"",
      "agent main() -> string {",
      "  \"hello from " <> name <> "\"",
      "}"
    ]

-- | Local-dev compose file. Pulls the published katari runtime image
-- (pinned to the CLI's own version) and a Postgres 17 container. The
-- @db-init@ mount creates @katari_runtime@ on first boot; the runtime
-- container then applies @schema.sql@ automatically at startup (see
-- @KATARI_AUTO_MIGRATE@ in katari-api-server\/src\/bin.ts).
dockerComposeTemplate :: String -> String -> String
dockerComposeTemplate name tag =
  unlines
    [ "# Local dev compose for the '" <> name <> "' katari project.",
      "# Spins up the katari runtime + Postgres. Copy `.env.example` to `.env`",
      "# before the first `docker compose up -d`.",
      "",
      "services:",
      "  runtime:",
      "    image: ghcr.io/katari-lang/katari:" <> tag,
      "    restart: unless-stopped",
      "    ports:",
      "      - \"${KATARI_PORT:-8000}:8000\"",
      "    environment:",
      "      - PORT=8000",
      "      - DATABASE_URL=postgresql://katari:katari@db:5432/katari_runtime",
      "      - LOG_LEVEL=${KATARI_LOG_LEVEL:-info}",
      "      - KATARI_API_KEY=${KATARI_API_KEY:?set KATARI_API_KEY in .env (copy from .env.example)}",
      "      - KATARI_SECRET_KEY=${KATARI_SECRET_KEY:?set KATARI_SECRET_KEY in .env (copy from .env.example)}",
      "    depends_on:",
      "      db:",
      "        condition: service_healthy",
      "",
      "  db:",
      "    image: postgres:17-alpine",
      "    restart: unless-stopped",
      "    environment:",
      "      - POSTGRES_USER=katari",
      "      - POSTGRES_PASSWORD=katari",
      "      - POSTGRES_DB=postgres",
      "    volumes:",
      "      - pgdata:/var/lib/postgresql/data",
      "      - ./db-init:/docker-entrypoint-initdb.d:ro",
      "    healthcheck:",
      "      test: [\"CMD-SHELL\", \"pg_isready -U katari -d postgres\"]",
      "      interval: 5s",
      "      timeout: 3s",
      "      retries: 5",
      "",
      "volumes:",
      "  pgdata:"
    ]

envExampleTemplate :: String
envExampleTemplate =
  unlines
    [ "# Copy to `.env` and fill in values before `docker compose up -d`.",
      "#",
      "# Generate strong values for prod:",
      "#   openssl rand -hex 16   # KATARI_API_KEY",
      "#   openssl rand -hex 32   # KATARI_SECRET_KEY (32-byte AES key, 64 hex chars)",
      "",
      "# ─── Required ────────────────────────────────────────────────────────────",
      "",
      "# Bearer token clients (admin UI, katari CLI, scripts) must send.",
      "# Set to literal \"disabled\" to turn auth off — only safe for local dev.",
      "KATARI_API_KEY=dev-katari-api-key",
      "",
      "# AES-256-GCM key for env secret encryption. Rotating this loses access",
      "# to every existing secret entry. Exactly 64 hex chars = 32 bytes.",
      "KATARI_SECRET_KEY=0000000000000000000000000000000000000000000000000000000000000000",
      "",
      "# ─── Optional ────────────────────────────────────────────────────────────",
      "",
      "# Host port the runtime listens on (default 8000).",
      "KATARI_PORT=8000",
      "",
      "# error | warn | info | debug | trace",
      "KATARI_LOG_LEVEL=info"
    ]

gitignoreTemplate :: String
gitignoreTemplate =
  unlines
    [ ".env",
      "node_modules/"
    ]

readmeTemplate :: String -> String
readmeTemplate name =
  unlines
    [ "# " <> name,
      "",
      "Katari project.",
      "",
      "## Quickstart",
      "",
      "```sh",
      "cp .env.example .env",
      "docker compose up -d",
      "katari apply",
      "```",
      "",
      "The runtime listens on `http://localhost:8000` by default. Point",
      "`katari apply` / `katari run` at it via `--api` or `KATARI_API_URL`.",
      "",
      "For production, generate strong values for `KATARI_API_KEY` and",
      "`KATARI_SECRET_KEY` in `.env` (see comments there)."
    ]

-- | Runs exactly once on first @docker compose up@: creates the runtime
-- database. The runtime container's startup migration step (= apply
-- @schema.sql@) then populates the schema.
dbInitSqlTemplate :: String
dbInitSqlTemplate = "CREATE DATABASE katari_runtime;\n"
