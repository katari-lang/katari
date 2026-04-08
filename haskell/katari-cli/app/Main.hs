module Main where

import Options.Applicative
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import qualified Data.ByteString as BS
import System.Exit (exitFailure, exitSuccess)
import System.IO (hPutStrLn, stderr)
import Control.Exception (catch, SomeException)

import Katari.Lexer (lexFile, LexError (..))
import Katari.Parser (parseModule, ParseError)
import Katari.Module (buildGlobalEnv, ModuleError (..))
import Katari.Typechecker (typecheck, TypeError (..))
import Katari.Lowering (lowerModules, LowerError (..))
import Katari.Emit (emitModule)
import Katari.Syntax (Module (..))

-- ---------------------------------------------------------------------------
-- CLI
-- ---------------------------------------------------------------------------

data Command
  = Compile CompileOpts
  deriving (Show)

data CompileOpts = CompileOpts
  { coInput  :: FilePath
  , coOutput :: Maybe FilePath
  } deriving (Show)

cliParser :: Parser Command
cliParser = subparser
  (  command "compile" (info compileParser (progDesc "Compile a .ktr file to .ktri binary"))
  )

compileParser :: Parser Command
compileParser = fmap Compile $ CompileOpts
  <$> argument str (metavar "FILE" <> help "Input .ktr file")
  <*> optional (option str (short 'o' <> long "output" <> metavar "OUT" <> help "Output .ktri file"))

-- ---------------------------------------------------------------------------
-- Main
-- ---------------------------------------------------------------------------

main :: IO ()
main = do
  cmd <- execParser (info (cliParser <**> helper) (fullDesc <> progDesc "Katari compiler"))
  case cmd of
    Compile opts -> runCompile opts

runCompile :: CompileOpts -> IO ()
runCompile opts = do
  let fp  = coInput opts
      out = case coOutput opts of
              Just o  -> o
              Nothing -> replaceExt fp ".ktri"

  -- Read source
  src <- TIO.readFile fp `catch` \(e :: SomeException) -> do
    hPutStrLn stderr ("Error reading file: " ++ show e)
    exitFailure

  -- Lex
  toks <- case lexFile fp src of
    Left (LexError msg) -> do
      hPutStrLn stderr ("Lex error: " ++ msg)
      exitFailure
    Right toks -> return toks

  -- Parse
  m <- case parseModule fp toks of
    Left err -> do
      hPutStrLn stderr ("Parse error: " ++ show err)
      exitFailure
    Right m -> return m

  -- Build global environment
  ge <- case buildGlobalEnv [m] of
    Left err -> do
      hPutStrLn stderr ("Module error: " ++ show err)
      exitFailure
    Right ge -> return ge

  -- Typecheck
  case typecheck ge [m] of
    Left err -> do
      hPutStrLn stderr ("Type error: " ++ show err)
      exitFailure
    Right () -> return ()

  -- Lower
  irModule <- case lowerModules ge [m] of
    Left (LowerError msg) -> do
      hPutStrLn stderr ("Lowering error: " ++ msg)
      exitFailure
    Right ir -> return ir

  -- Emit
  let binary = emitModule irModule
  BS.writeFile out binary
  putStrLn ("Compiled: " ++ fp ++ " → " ++ out)

-- Replace file extension
replaceExt :: FilePath -> String -> FilePath
replaceExt fp newExt =
  let base = reverse (dropWhile (/= '.') (reverse fp))
  in if null base then fp ++ newExt else base ++ drop 1 newExt
