module Katari.Cli.InitSpec (spec) where

import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Katari.Cli.Command.Init qualified as Init
import Katari.Cli.Options (GlobalOptions (..))
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

-- | Non-interactive globals (the test harness has no TTY anyway; --no-input makes it explicit).
quietGlobals :: GlobalOptions
quietGlobals = GlobalOptions {quiet = True, verbose = False, noInput = True, url = Nothing}

scaffold :: FilePath -> IO ()
scaffold directory =
  Init.run Init.Options {global = quietGlobals, name = Just "demo", directory = Just directory}

spec :: Spec
spec = describe "katari init" $ do
  it "scaffolds every project file with the name interpolated" $
    withSystemTempDirectory "katari-init" $ \directory -> do
      scaffold directory
      mapM_
        (\path -> doesFileExist (directory </> path) `shouldReturn` True)
        ["katari.toml", "src/main.ktr", ".gitignore", ".env.example", "compose.yaml", "README.md"]
      config <- TextIO.readFile (directory </> "katari.toml")
      config `shouldSatisfy` Text.isInfixOf "name = \"demo\""
      readme <- TextIO.readFile (directory </> "README.md")
      readme `shouldSatisfy` Text.isInfixOf "# demo"

  it "never overwrites an existing file on a re-run" $
    withSystemTempDirectory "katari-init" $ \directory -> do
      scaffold directory
      TextIO.writeFile (directory </> "katari.toml") "# customised\n"
      scaffold directory
      customised <- TextIO.readFile (directory </> "katari.toml")
      customised `shouldBe` "# customised\n"

  it "rejects an invalid package name" $
    withSystemTempDirectory "katari-init" $ \directory ->
      Init.run Init.Options {global = quietGlobals, name = Just "not a name", directory = Just directory}
        `shouldThrow` anyException
