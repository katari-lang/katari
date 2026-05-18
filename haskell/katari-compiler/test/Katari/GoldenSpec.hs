-- | Golden / snapshot tests for the compile pipeline.
--
-- For every @.ktr@ source under @test/golden/cases/@ this module runs
-- 'compile' and asserts that the produced IR JSON, schema JSON, and
-- diagnostic text match the corresponding files under
-- @test/golden/expected/@. The IR and schema files are only emitted
-- when 'compile' produces an artefact; cases that intentionally fail
-- (undefined name, type error, ...) only produce a diagnostics file.
--
-- Run with @KATARI_GOLDEN_ACCEPT=1 stack test@ to overwrite the
-- expected files with the current pipeline output. Use this when an
-- intentional behaviour change has shifted the snapshot — review the
-- @git diff@ before committing.
module Katari.GoldenSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.Aeson.Encode.Pretty qualified as Aeson
import Data.ByteString.Lazy qualified as ByteStringLazy
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Text.IO qualified as TextIO
import Katari.Compile
  ( CompileInput (..),
    CompileResult (..),
    SourceEntry (..),
    compile,
  )
import Katari.Diagnostic (Diagnostic)
import Katari.Diagnostic.Render (renderDiagnostic)
import System.Directory (doesFileExist, listDirectory)
import System.Environment (lookupEnv)
import System.FilePath (takeBaseName, takeExtension, (</>))
import Test.Hspec

casesDir :: FilePath
casesDir = "test/golden/cases"

expectedDir :: FilePath
expectedDir = "test/golden/expected"

spec :: Spec
spec = describe "golden / snapshot" $ do
  caseFiles <- runIO discoverCases
  mapM_ goldenCase caseFiles

discoverCases :: IO [FilePath]
discoverCases = do
  entries <- listDirectory casesDir
  pure $ sort [casesDir </> entry | entry <- entries, takeExtension entry == ".ktr"]

goldenCase :: FilePath -> Spec
goldenCase path = describe ("compiling " <> takeBaseName path) $ do
  result <- runIO $ do
    sourceText <- TextIO.readFile path
    let entry =
          SourceEntry
            { filePath = path,
              sourceText = sourceText
            }
        input = CompileInput {sources = Map.singleton "main" entry}
    pure (compile input, sourceText)

  let (compiled, sourceText) = result
      baseName = takeBaseName path
      diagnosticsText = renderDiagnostics sourceText path compiled.diagnostics
      irJson = case compiled.irModule of
        Just irModule -> Just (prettyJson irModule)
        Nothing -> Nothing
      schemaJson = case compiled.schemaEntries of
        Just entries -> Just (prettyJson entries)
        Nothing -> Nothing

  it "diagnostics snapshot matches" $
    matchesGolden (expectedDir </> baseName <> ".diagnostics.txt") diagnosticsText

  it "IR JSON snapshot matches when artefacts are produced" $
    case irJson of
      Just text -> matchesGolden (expectedDir </> baseName <> ".ir.json") text
      Nothing ->
        -- A missing artefact is also a snapshot fact: assert that the
        -- expected file does not exist either, so a regression that
        -- starts producing IR for a previously-failing case fails the
        -- snapshot rather than silently passing.
        absentGolden (expectedDir </> baseName <> ".ir.json")

  it "schema JSON snapshot matches when artefacts are produced" $
    case schemaJson of
      Just text -> matchesGolden (expectedDir </> baseName <> ".schema.json") text
      Nothing -> absentGolden (expectedDir </> baseName <> ".schema.json")

-- ===========================================================================
-- Helpers
-- ===========================================================================

renderDiagnostics :: Text -> FilePath -> [Diagnostic] -> Text
renderDiagnostics sourceText path diagnostics =
  Text.unlines
    (map (renderDiagnostic (Map.singleton path sourceText)) diagnostics)

prettyJson :: (Aeson.ToJSON a) => a -> Text
prettyJson value =
  Text.decodeUtf8 (ByteStringLazy.toStrict (Aeson.encodePretty' prettyConfig value))
    <> "\n"
  where
    prettyConfig =
      Aeson.defConfig
        { Aeson.confIndent = Aeson.Spaces 2,
          Aeson.confCompare = compare,
          Aeson.confTrailingNewline = False
        }

-- | Compare actual content to the expected file. Honour the
-- @KATARI_GOLDEN_ACCEPT@ env var to overwrite the expected file
-- instead of asserting equality.
matchesGolden :: FilePath -> Text -> Expectation
matchesGolden expectedPath actualText = do
  acceptEnv <- lookupEnv "KATARI_GOLDEN_ACCEPT"
  case acceptEnv of
    Just "1" -> TextIO.writeFile expectedPath actualText
    _ -> do
      exists <- doesFileExist expectedPath
      if exists
        then do
          expectedText <- TextIO.readFile expectedPath
          actualText `shouldBe` expectedText
        else
          expectationFailure
            ( "missing golden file: "
                <> expectedPath
                <> " (run KATARI_GOLDEN_ACCEPT=1 stack test to create it)"
            )

absentGolden :: FilePath -> Expectation
absentGolden expectedPath = do
  acceptEnv <- lookupEnv "KATARI_GOLDEN_ACCEPT"
  case acceptEnv of
    Just "1" -> pure () -- accept-mode never asserts absence
    _ -> do
      exists <- doesFileExist expectedPath
      if exists
        then
          expectationFailure
            ( "unexpected golden file present: "
                <> expectedPath
                <> " (the pipeline no longer produces this artefact for the case)"
            )
        else pure ()
