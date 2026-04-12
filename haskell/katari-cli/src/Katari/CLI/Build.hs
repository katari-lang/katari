module Katari.CLI.Build
  ( runBuild,
  )
where

import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Maybe (fromMaybe)
import Katari.CLI.Compiler (buildAllOrDie, buildOrDie, schemasToValue)
import Katari.CLI.Project (loadProjectOrDie)
import Katari.CLI.Types (BuildOpts (..))
import Katari.Emit (emitModule)
import Katari.Schema (moduleSchemas)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath (replaceExtension, takeExtension, (</>))

runBuild :: BuildOpts -> IO ()
runBuild BuildOpts {..} = do
  let path = fromMaybe "." boPath
  isFile <- doesFileExist path
  if isFile && takeExtension path == ".ktr"
    then buildSingleFile path
    else buildProject path

buildProject :: FilePath -> IO ()
buildProject root = do
  let distDir = root </> "dist"
  modules <- loadProjectOrDie root
  (ge, irModule) <- buildAllOrDie modules
  let binary = emitModule irModule
  createDirectoryIfMissing True distDir
  BS.writeFile (distDir </> "out.ktri") binary
  let schemas = moduleSchemas ge
      jsonBytes = Aeson.encode (schemasToValue schemas)
  BL.writeFile (distDir </> "schema.json") jsonBytes
  putStrLn ("Built: " ++ root ++ " -> " ++ distDir ++ "/")

buildSingleFile :: FilePath -> IO ()
buildSingleFile fp = do
  modules <- loadProjectOrDie fp
  irModule <- buildOrDie modules
  let binary = emitModule irModule
      outPath = replaceExtension fp ".ktri"
  BS.writeFile outPath binary
  putStrLn ("Built: " ++ fp ++ " -> " ++ outPath)
