-- Black-box test for @katari init@: invokes 'Init.run' against a
-- temp directory and asserts the produced files.
module Katari.Cli.InitSpec (spec) where

import qualified Katari.Cli.Init as Init
import System.Directory (doesDirectoryExist, doesFileExist, withCurrentDirectory)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = describe "katari init" $ do
  it "scaffolds katari.toml and src/<pkg>.ktr for a fresh name" $ do
    withSystemTempDirectory "katari-init-test" $ \tmp ->
      withCurrentDirectory tmp $ do
        Init.run Init.Options {optName = Just "demo"}
        doesDirectoryExist (tmp </> "demo") `shouldReturn` True
        doesFileExist (tmp </> "demo" </> "katari.toml") `shouldReturn` True
        doesFileExist (tmp </> "demo" </> "src" </> "demo.ktr") `shouldReturn` True

  it "rejects names that are not valid Katari identifiers" $ do
    -- 'Init.run' calls 'exitWith' on a bad name; we just confirm it
    -- exits non-zero rather than scribbling anything to disk.
    Init.run Init.Options {optName = Just "bad-name"}
      `shouldThrow` (== ExitFailure 2)
