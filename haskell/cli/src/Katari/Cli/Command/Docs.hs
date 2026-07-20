-- | @katari docs@ — emit the library API reference of the project's root package (or, with
-- @--stdlib@, of the wired-in prelude) as JSON.
--
-- Resolution is offline (disk + cache only), exactly like @build@ / @check@, so the output is
-- deterministic. The JSON contract (@katariDocsVersion = 1@) lives in "Katari.Docs" and is
-- documented in @docs/2026-07-17-library-api-reference.md@; this command is only the wiring: load,
-- compile, project the root package's own modules, and print. Default output is stdout — the
-- consumer is a generation pipeline (katari-web), not a file the project keeps.
module Katari.Cli.Command.Docs
  ( Options (..),
    optionsParser,
    run,
  )
where

import Data.Aeson.Encode.Pretty (encodePretty)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Map.Strict qualified as Map
import Katari.Cli.Common (assembleSourcesOrExit, cliVersion, compileResultOrExit, dieIn, resolveProjectRoot, writeOrExit)
import Katari.Cli.Options (GlobalOptions, directoryOption, globalOptionsParser)
import Katari.Compile qualified as Compile
import Katari.Docs (DocsDocument (..), extractModules, parsedExtraction, typedExtraction)
import Katari.Project.Config (PackageSection (..), ProjectConfig (..))
import Katari.Project.Discovery (emptyOverlay)
import Katari.Project.Error (renderProjectError)
import Katari.Project.Resolve (ResolvedPackage (..), ResolvedProject (..), loadProjectOffline)
import Options.Applicative
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory)

data Options = Options
  { global :: GlobalOptions,
    projectRoot :: Maybe FilePath,
    output :: Maybe FilePath,
    stdlib :: Bool
  }
  deriving stock (Show)

optionsParser :: Parser Options
optionsParser =
  Options
    <$> globalOptionsParser
    <*> directoryOption
    <*> optional
      ( strOption
          ( long "out"
              <> short 'o'
              <> metavar "FILE"
              <> help "Write the docs JSON to FILE (default: stdout)"
          )
      )
    <*> switch
      ( long "stdlib"
          <> help "Document the wired-in stdlib (prelude) instead of a project"
      )

run :: Options -> IO ()
run options = do
  document <- if options.stdlib then pure stdlibDocument else projectDocument options
  let encoded = encodePretty document <> "\n"
  case options.output of
    Just path -> writeOrExit "docs" "could not write docs output" $ do
      createDirectoryIfMissing True (takeDirectory path)
      LazyByteString.writeFile path encoded
    Nothing -> LazyByteString.putStr encoded

-- | The prelude's reference. The declarations come from the shared Parsed stdlib (the compile
-- driver retains no typed stdlib AST); the wire schemas come from compiling an empty input — the
-- stdlib is spliced into every compile, so an empty one lowers exactly the stdlib. The prelude
-- ships with the compiler, so it is versioned by 'cliVersion'.
stdlibDocument :: DocsDocument
stdlibDocument =
  DocsDocument
    { compilerVersion = cliVersion,
      packageName = "prelude",
      packageVersion = Just cliVersion,
      modules = extractModules parsedExtraction parsedModules result.loweredModules
    }
  where
    parsedModules = fst <$> Compile.stdlibParsed
    result = Compile.compile Compile.CompileInput {Compile.sources = mempty}

projectDocument :: Options -> IO DocsDocument
projectDocument options = do
  root <- resolveProjectRoot "docs" options.projectRoot
  resolved <-
    loadProjectOffline emptyOverlay root >>= \case
      Left projectError -> dieIn "docs" (renderProjectError projectError)
      Right loaded -> pure loaded
  sources <- assembleSourcesOrExit "docs" resolved
  result <- compileResultOrExit sources
  -- The reference covers the root package's own modules only: a dependency documents itself, so
  -- restating its modules here would duplicate every package's reference into its dependents'.
  let rootModuleNames = Map.keysSet resolved.rootPackage.sources
      package = resolved.rootPackage.config.package
  pure
    DocsDocument
      { compilerVersion = cliVersion,
        packageName = package.name,
        packageVersion = package.version,
        modules =
          extractModules
            typedExtraction
            (Map.restrictKeys result.typedModules rootModuleNames)
            result.loweredModules
      }
