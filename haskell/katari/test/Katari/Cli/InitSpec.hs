-- Black-box test for @katari init@: invokes 'Init.run' against a
-- temp directory and asserts the produced files.
module Katari.Cli.InitSpec (spec) where

import Katari.Cli.Init qualified as Init
import System.Directory (doesDirectoryExist, doesFileExist, withCurrentDirectory)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = describe "katari init" $ do
  it "scaffolds in cwd using the positional NAME as the package name" $ do
    withSystemTempDirectory "katari-init-test" $ \tmp ->
      withCurrentDirectory tmp $ do
        Init.run Init.Options {optName = Just "demo", optDir = Nothing}
        doesFileExist (tmp </> "katari.toml") `shouldReturn` True
        doesFileExist (tmp </> "src" </> "demo.ktr") `shouldReturn` True
        doesFileExist (tmp </> "docker-compose.yml") `shouldReturn` True
        -- A bare positional NAME does NOT create a subdirectory.
        doesDirectoryExist (tmp </> "demo") `shouldReturn` False

  it "scaffolds into --dir DIR and derives the package name from DIR" $ do
    withSystemTempDirectory "katari-init-test" $ \tmp ->
      withCurrentDirectory tmp $ do
        Init.run Init.Options {optName = Nothing, optDir = Just "myproj"}
        doesDirectoryExist (tmp </> "myproj") `shouldReturn` True
        doesFileExist (tmp </> "myproj" </> "katari.toml") `shouldReturn` True
        doesFileExist (tmp </> "myproj" </> "src" </> "myproj.ktr") `shouldReturn` True

  it "lets NAME override the package name when --dir is also given" $ do
    withSystemTempDirectory "katari-init-test" $ \tmp ->
      withCurrentDirectory tmp $ do
        Init.run Init.Options {optName = Just "foo", optDir = Just "bar"}
        doesFileExist (tmp </> "bar" </> "katari.toml") `shouldReturn` True
        doesFileExist (tmp </> "bar" </> "src" </> "foo.ktr") `shouldReturn` True

  it "rejects names that are not valid Katari identifiers" $ do
    -- 'Init.run' calls 'exitWith' on a bad name; we just confirm it
    -- exits non-zero rather than scribbling anything to disk.
    Init.run Init.Options {optName = Just "bad-name", optDir = Nothing}
      `shouldThrow` (== ExitFailure 2)
