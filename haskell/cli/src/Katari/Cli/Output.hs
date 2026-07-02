-- | Output conventions for the whole CLI, in one place:
--
--   * stdout carries /results only/ (a run's outcome JSON, a listing, a raw env value) so every
--     command pipes cleanly;
--   * stderr carries progress, hints, warnings, prompts — the conversation with the human;
--   * ANSI styling goes to stderr only, and only when stderr is a capable terminal ('NO_COLOR' and
--     @TERM=dumb@ both disable it). stdout is never styled: its reader may be a pipe.
--
-- 'OutputContext' is built once per invocation from the global flags plus terminal detection and
-- threaded to everything that prints.
module Katari.Cli.Output
  ( OutputContext (..),
    newOutputContext,
    progress,
    hint,
    warn,
    verboseLog,
    printJson,
    printText,
    renderTable,
    styled,
    compactTimestamp,
  )
where

import Data.Aeson (ToJSON)
import Data.Aeson.Encode.Pretty qualified as Pretty
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Maybe (isNothing)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import GHC.List (List)
import Katari.Cli.Options (GlobalOptions (..))
import System.Console.ANSI (Color (..), ColorIntensity (..), ConsoleIntensity (..), ConsoleLayer (..), SGR (..), setSGRCode)
import System.Environment (lookupEnv)
import System.IO (hIsTerminalDevice, stderr, stdin, stdout)

-- | Everything a printing site needs to decide how (and whether) to speak.
data OutputContext = OutputContext
  { -- | stderr accepts ANSI styling.
    color :: Bool,
    -- | The session may prompt: stdin and stderr are both terminals and @--no-input@ was not given.
    -- (A dumb terminal is still interactive — prompts fall back to their numbered form.)
    interactive :: Bool,
    -- | The terminal understands cursor movement (false for @TERM=dumb@); selects arrow-key menus
    -- over the numbered fallback.
    ansiCapable :: Bool,
    quiet :: Bool,
    verbose :: Bool
  }
  deriving stock (Show)

-- | Detect the terminal situation once. Styling and interactivity are independent judgements: a
-- piped stderr kills colour but @--no-input@ alone must not (its output is still read by a human).
newOutputContext :: GlobalOptions -> IO OutputContext
newOutputContext options = do
  stdinIsTerminal <- hIsTerminalDevice stdin
  stderrIsTerminal <- hIsTerminalDevice stderr
  noColorRequested <- lookupEnv "NO_COLOR"
  terminalKind <- lookupEnv "TERM"
  let dumbTerminal = terminalKind == Just "dumb"
      capable = stderrIsTerminal && not dumbTerminal
  pure
    OutputContext
      { color = capable && isNothing noColorRequested,
        interactive = stdinIsTerminal && stderrIsTerminal && not options.noInput,
        ansiCapable = capable,
        quiet = options.quiet,
        verbose = options.verbose
      }

-- | A progress line: what the CLI is doing right now. stderr, silenced by @--quiet@.
progress :: OutputContext -> Text -> IO ()
progress context message
  | context.quiet = pure ()
  | otherwise = TextIO.hPutStrLn stderr message

-- | A dim afterthought — e.g. the deterministic command equivalent to what was just done
-- interactively. stderr, silenced by @--quiet@.
hint :: OutputContext -> Text -> IO ()
hint context message
  | context.quiet = pure ()
  | otherwise = TextIO.hPutStrLn stderr (styled context [SetColor Foreground Dull Cyan] ("hint: " <> message))

-- | A warning is information the user should not lose, so @--quiet@ does not silence it.
warn :: OutputContext -> Text -> IO ()
warn context message =
  TextIO.hPutStrLn stderr (styled context [SetColor Foreground Vivid Yellow] ("warning: " <> message))

-- | A @--verbose@ trace line (HTTP requests and responses).
verboseLog :: OutputContext -> Text -> IO ()
verboseLog context message
  | context.verbose = TextIO.hPutStrLn stderr (styled context [SetConsoleIntensity FaintIntensity] message)
  | otherwise = pure ()

-- | A result document on stdout: pretty JSON (machine-consumable, and 2-space indented for humans).
printJson :: (ToJSON a) => a -> IO ()
printJson value = do
  LazyByteString.hPut stdout (Pretty.encodePretty' (Pretty.defConfig {Pretty.confIndent = Pretty.Spaces 2}) value)
  TextIO.hPutStrLn stdout ""

-- | A result line on stdout.
printText :: Text -> IO ()
printText = TextIO.hPutStrLn stdout

-- | Wrap text in ANSI styling when the context allows it, and pass it through untouched otherwise.
styled :: OutputContext -> List SGR -> Text -> Text
styled context codes text
  | context.color = Text.pack (setSGRCode codes) <> text <> Text.pack (setSGRCode [Reset])
  | otherwise = text

-- | Render rows as space-aligned columns (each column as wide as its widest cell). Pure so the
-- alignment is unit-testable; the caller decides the handle.
renderTable :: List Text -> List (List Text) -> Text
renderTable header rows =
  Text.intercalate "\n" (map renderRow (header : rows))
  where
    widths = columnWidths (header : rows)
    renderRow cells =
      Text.stripEnd (Text.intercalate "  " (zipWith pad widths cells))
    pad width cell = cell <> Text.replicate (width - Text.length cell) " "

-- | Each column's width across every row (rows may be ragged; missing cells count as empty).
columnWidths :: List (List Text) -> List Int
columnWidths rows = case rows of
  [] -> []
  _ -> map width [0 .. columnCount - 1]
  where
    columnCount = maximum (1 : map length rows)
    width index = maximum (0 : [Text.length cell | row <- rows, cell <- take 1 (drop index row)])

-- | An ISO-8601 timestamp cut down for table cells: @2026-07-01T12:34:56.789Z@ → @2026-07-01 12:34@.
-- Purely textual — anything shorter than the expected shape passes through untouched.
compactTimestamp :: Text -> Text
compactTimestamp timestamp
  | Text.length timestamp >= 16 = Text.replace "T" " " (Text.take 16 timestamp)
  | otherwise = timestamp
