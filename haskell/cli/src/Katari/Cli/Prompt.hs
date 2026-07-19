-- | Interactive prompts — the human half of the CLI's two modes. Complete input runs deterministic
-- and promptless; when something is missing /and/ the session is interactive, these prompts fill the
-- gap. Callers guard on 'OutputContext.interactive' and hard-error when it is off, so a pipe or CI
-- run never blocks on a question.
--
-- Conventions:
--
--   * Prompts render on stderr and read stdin; stdout stays reserved for results.
--   * Every prompt returns @Maybe@ — 'Nothing' is the user backing out (Esc \/ @q@ \/ EOF), which
--     callers turn into a "cancelled" exit rather than an error.
--   * On an ANSI-capable terminal 'select' is an arrow-key menu (redrawn in place, cursor hidden);
--     on a dumb one it degrades to a numbered list. Both read the same answers.
--
-- 'promptFromSchema' walks a callable's input schema (the compiler's typed 'JSONSchema', decoded off
-- the IR wire) and interviews the user field by field: records destructure with breadcrumbed labels,
-- required fields first; unions become menus; consts fill themselves in. The pure coercion /
-- classification helpers live at the bottom, where the unit tests reach them.
module Katari.Cli.Prompt
  ( -- * Primitives
    select,
    inputLine,
    inputSecret,
    confirm,

    -- * Schema-driven interview
    promptFromSchema,

    -- * Pure helpers (unit-tested)
    TypedInputKind (..),
    coerceTypedInput,
    constLabels,
    renderSchemaBrief,
    compactJson,
  )
where

import Control.Exception (bracket_)
import Control.Monad (forM, forM_)
import Data.Aeson (Value (..))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Scientific qualified as Scientific
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Text.IO qualified as TextIO
import Data.Vector qualified as Vector
import GHC.List (List)
import Katari.Cli.Output (OutputContext (..), styled)
import Katari.Data.JSONSchema (AdditionalProperties (..), DescribedSchema (..), JSONSchema (..), ObjectSchema (..))
import Katari.Schema (constructorDiscriminatorKey, valueNestingKey)
import System.Console.ANSI
  ( Color (..),
    ColorIntensity (..),
    ConsoleIntensity (..),
    ConsoleLayer (..),
    SGR (..),
    hClearFromCursorToScreenEnd,
    hClearLine,
    hCursorUpLine,
    hGetTerminalSize,
    hHideCursor,
    hShowCursor,
  )
import System.IO
  ( BufferMode (..),
    hFlush,
    hGetBuffering,
    hGetEcho,
    hSetBuffering,
    hSetEcho,
    hWaitForInput,
    isEOF,
    stderr,
    stdin,
  )
import System.IO.Error (catchIOError, isEOFError)
import Text.Read (readMaybe)

-- ===========================================================================
-- Selection menu
-- ===========================================================================

-- | Ask the user to pick one of the labelled items. Arrow keys (or @j@/@k@) move, Enter picks,
-- Esc/@q@ cancels. The menu erases itself and leaves a one-line summary of the choice.
select :: OutputContext -> Text -> List (Text, a) -> IO (Maybe a)
select context question items = case items of
  [] -> pure Nothing
  _
    | context.ansiCapable -> arrowSelect context question items
    | otherwise -> numberedSelect context question items

arrowSelect :: OutputContext -> Text -> List (Text, a) -> IO (Maybe a)
arrowSelect context question items = do
  TextIO.hPutStrLn stderr (questionLine context question <> " " <> dim context hintText)
  drawItems 0
  outcome <- withRawInput (bracket_ (hHideCursor stderr) (hShowCursor stderr) (loop 0))
  eraseMenu
  case outcome of
    Nothing -> TextIO.hPutStrLn stderr (questionLine context question <> " " <> dim context "(cancelled)")
    Just index -> forM_ (labelAt index) $ \label ->
      TextIO.hPutStrLn stderr (questionLine context question <> " " <> label)
  pure (outcome >>= valueAt)
  where
    hintText = "(↑/↓ move, Enter picks, Esc cancels)"

    -- Erase the menu (items + header) and leave the choice as a plain line the scrollback keeps. A
    -- long header or item wraps onto several physical rows on a narrow terminal, so the cursor must
    -- rise by the true wrapped-row count — moving up a fixed one-row-per-line would leave the wrapped
    -- remainder on screen. The visible widths ignore the ANSI styling codes, which take no columns.
    eraseMenu = do
      terminalSize <- hGetTerminalSize stderr
      let rowsToClear = case terminalSize of
            Just (_, width) | width > 0 -> sum [physicalRows width lineWidth | lineWidth <- lineWidths]
            _ -> length items + 1
      hCursorUpLine stderr rowsToClear
      hClearFromCursorToScreenEnd stderr

    -- The header is @"? " <> question@ then a space then the hint; each item is a two-column marker
    -- then its label.
    lineWidths =
      (2 + Text.length question + 1 + Text.length hintText)
        : [2 + Text.length label | (label, _) <- items]

    physicalRows width lineWidth = max 1 ((lineWidth + width - 1) `div` width)

    labelAt index = fmap fst (itemAt index)
    valueAt index = fmap snd (itemAt index)
    itemAt index = case drop index items of
      (item : _) -> Just item
      [] -> Nothing

    drawItems cursor =
      forM_ (zip [0 :: Int ..] items) $ \(index, (label, _)) -> do
        hClearLine stderr
        TextIO.hPutStrLn stderr $
          if index == cursor
            then styled context [SetColor Foreground Vivid Cyan] ("❯ " <> label)
            else "  " <> label

    redraw cursor = do
      hCursorUpLine stderr (length items)
      drawItems cursor

    loop cursor = do
      key <- readKeyEvent
      case key of
        KeyUp -> moveTo (cursor - 1) cursor
        KeyDown -> moveTo (cursor + 1) cursor
        KeyEnter -> pure (Just cursor)
        KeyCancel -> pure Nothing
        KeyOther -> loop cursor

    moveTo next current =
      let clamped = max 0 (min (length items - 1) next)
       in if clamped == current then loop current else redraw clamped >> loop clamped

-- | The dumb-terminal fallback: a numbered list read as a line of input.
numberedSelect :: OutputContext -> Text -> List (Text, a) -> IO (Maybe a)
numberedSelect context question items = do
  TextIO.hPutStrLn stderr (questionLine context question)
  forM_ (zip [1 :: Int ..] items) $ \(number, (label, _)) ->
    TextIO.hPutStrLn stderr ("  " <> Text.pack (show number) <> ") " <> label)
  loop
  where
    loop = do
      answer <- readAnswer ("Number (1-" <> Text.pack (show (length items)) <> ", empty cancels): ")
      case answer of
        Nothing -> pure Nothing
        Just line
          | Text.null (Text.strip line) -> pure Nothing
          | otherwise -> case readMaybe (Text.unpack (Text.strip line)) of
              Just number
                | number >= 1 && number <= length items ->
                    pure (fmap snd (safeIndex (number - 1)))
              _ -> loop
    safeIndex index = case drop index items of
      (item : _) -> Just item
      [] -> Nothing

-- ===========================================================================
-- Line input
-- ===========================================================================

-- | Read one line of input under the given label. 'Nothing' on EOF (the user closed the stream).
inputLine :: OutputContext -> Text -> IO (Maybe Text)
inputLine context label = readAnswer (questionLine context label <> " ")

-- | Like 'inputLine' but with terminal echo off, for values that must not land in the scrollback
-- (secrets). Prints the newline the suppressed echo swallowed.
inputSecret :: OutputContext -> Text -> IO (Maybe Text)
inputSecret context label = do
  originalEcho <- hGetEcho stdin
  answer <-
    bracket_
      (hSetEcho stdin False)
      (hSetEcho stdin originalEcho)
      (readAnswer (questionLine context label <> " "))
  TextIO.hPutStrLn stderr ""
  pure answer

-- | A yes/no question with a default (chosen by a bare Enter). 'Nothing' on EOF.
confirm :: OutputContext -> Text -> Bool -> IO (Maybe Bool)
confirm context question defaultAnswer = loop
  where
    suffix = if defaultAnswer then " [Y/n] " else " [y/N] "
    loop = do
      answer <- readAnswer (questionLine context question <> suffix)
      case answer of
        Nothing -> pure Nothing
        Just line -> case Text.toLower (Text.strip line) of
          "" -> pure (Just defaultAnswer)
          "y" -> pure (Just True)
          "yes" -> pure (Just True)
          "n" -> pure (Just False)
          "no" -> pure (Just False)
          _ -> loop

-- | Print a prompt (no newline) and read the answer line; 'Nothing' on EOF.
readAnswer :: Text -> IO (Maybe Text)
readAnswer prompt = do
  TextIO.hPutStr stderr prompt
  hFlush stderr
  end <- isEOF
  if end
    then TextIO.hPutStrLn stderr "" >> pure Nothing
    else
      (Just <$> TextIO.getLine) `catchIOError` \ioException ->
        if isEOFError ioException then TextIO.hPutStrLn stderr "" >> pure Nothing else ioError ioException

questionLine :: OutputContext -> Text -> Text
questionLine context question = styled context [SetConsoleIntensity BoldIntensity] ("? " <> question)

dim :: OutputContext -> Text -> Text
dim context = styled context [SetConsoleIntensity FaintIntensity]

-- ===========================================================================
-- Raw keyboard input
-- ===========================================================================

data KeyEvent = KeyUp | KeyDown | KeyEnter | KeyCancel | KeyOther

-- | Put stdin into character-at-a-time, no-echo mode for the given action, restoring the previous
-- modes even when the action throws (including a Ctrl-C 'Control.Exception.UserInterrupt').
withRawInput :: IO a -> IO a
withRawInput action = do
  originalBuffering <- hGetBuffering stdin
  originalEcho <- hGetEcho stdin
  bracket_
    (hSetBuffering stdin NoBuffering >> hSetEcho stdin False)
    (hSetBuffering stdin originalBuffering >> hSetEcho stdin originalEcho)
    action

-- | Read one key, decoding the arrow-key escape sequences. A bare Esc is disambiguated from the
-- start of a sequence by a short wait: no follow-up byte means the user pressed Esc itself.
readKeyEvent :: IO KeyEvent
readKeyEvent = do
  character <- getChar
  case character of
    '\ESC' -> do
      pending <- hWaitForInput stdin escapeDelayMilliseconds
      if not pending
        then pure KeyCancel
        else do
          second <- getChar
          -- Arrow keys arrive either as a CSI sequence (ESC [ A/B) or, when the terminal is in
          -- application-cursor-key mode (DECCKM — the default under tmux and many xterm setups), as
          -- an SS3 sequence (ESC O A/B). Both introducers map to the same final-byte decoding, so a
          -- picker keeps working regardless of which mode the terminal is in.
          case second of
            '[' -> decodeArrowFinalByte
            'O' -> decodeArrowFinalByte
            _ -> pure KeyCancel
    '\r' -> pure KeyEnter
    '\n' -> pure KeyEnter
    '\EOT' -> pure KeyCancel
    'q' -> pure KeyCancel
    'j' -> pure KeyDown
    'k' -> pure KeyUp
    _ -> pure KeyOther
  where
    decodeArrowFinalByte = do
      third <- getChar
      pure $ case third of
        'A' -> KeyUp
        'B' -> KeyDown
        _ -> KeyOther

escapeDelayMilliseconds :: Int
escapeDelayMilliseconds = 50

-- ===========================================================================
-- Schema-driven interview
-- ===========================================================================

-- | Interview the user for a value satisfying @schema@, labelling every question with the breadcrumb
-- @path@ (e.g. @arg.user.name@). 'Nothing' means the user cancelled somewhere inside.
promptFromSchema :: OutputContext -> List Text -> JSONSchema -> IO (Maybe Value)
promptFromSchema context path schema = case schema of
  SchemaConst value -> autoFill value
  SchemaNull -> autoFill Null
  SchemaAny -> rawJsonLoop
  SchemaGeneric _ -> rawJsonLoop
  SchemaNever -> do
    TextIO.hPutStrLn stderr (pathLabel path <> ": no value can satisfy this parameter (its type is never)")
    pure Nothing
  SchemaBoolean -> fmap Bool <$> select context (pathLabel path) [("true", True), ("false", False)]
  SchemaInteger -> typedLoop InputInteger "integer"
  SchemaNumber -> typedLoop InputNumber "number"
  SchemaString -> fmap String <$> inputLine context (pathLabel path <> " (string)")
  SchemaArray element -> promptArray context path element
  SchemaTuple elements -> promptTuple context path elements
  SchemaObject objectSchema -> promptObject context path objectSchema
  SchemaAnyOf branches -> promptAnyOf context path branches
  -- A description annotates, never constrains: the interview asks for the inner shape.
  SchemaDescribed described -> promptFromSchema context path described.schema
  where
    autoFill value = do
      TextIO.hPutStrLn stderr (dim context (pathLabel path <> " = " <> compactJson value <> " (fixed)"))
      pure (Just value)

    rawJsonLoop = typedLoop InputRawJson "JSON"

    typedLoop kind description = do
      answer <- inputLine context (pathLabel path <> " (" <> description <> ")")
      case answer of
        Nothing -> pure Nothing
        Just line -> case coerceTypedInput kind line of
          Right value -> pure (Just value)
          Left problem -> do
            TextIO.hPutStrLn stderr ("  " <> problem)
            typedLoop kind description

promptArray :: OutputContext -> List Text -> JSONSchema -> IO (Maybe Value)
promptArray context path element = do
  countAnswer <- promptCount
  case countAnswer of
    Nothing -> pure Nothing
    Just count -> do
      elements <- forM [0 .. count - 1] $ \index ->
        promptFromSchema context (path <> [Text.pack (show index)]) element
      pure (fmap (Array . Vector.fromList) (sequence elements))
  where
    promptCount = do
      answer <- inputLine context (pathLabel path <> " (array — how many items?)")
      case answer of
        Nothing -> pure Nothing
        Just line -> case readMaybe (Text.unpack (Text.strip line)) of
          Just count | count >= (0 :: Int) -> pure (Just count)
          _ -> do
            TextIO.hPutStrLn stderr "  enter a non-negative whole number"
            promptCount

promptTuple :: OutputContext -> List Text -> List JSONSchema -> IO (Maybe Value)
promptTuple context path elements = do
  values <- forM (zip [0 :: Int ..] elements) $ \(index, element) ->
    promptFromSchema context (path <> [Text.pack (show index)]) element
  pure (fmap (Array . Vector.fromList) (sequence values))

promptObject :: OutputContext -> List Text -> ObjectSchema -> IO (Maybe Value)
promptObject context path objectSchema = do
  requiredPairs <- walkFields requiredFields (\_ -> pure True)
  case requiredPairs of
    Nothing -> pure Nothing
    Just required -> do
      optionalPairs <- walkFields optionalFields wantsOptional
      case optionalPairs of
        Nothing -> pure Nothing
        Just optional -> do
          extraPairs <- promptAdditional
          pure $
            (\extra -> Object (KeyMap.fromList [(Key.fromText name, value) | (name, value) <- required <> optional <> extra]))
              <$> extraPairs
  where
    requiredFields = [(name, fieldSchema) | (name, fieldSchema) <- objectSchema.properties, name `elem` objectSchema.required]
    optionalFields = [(name, fieldSchema) | (name, fieldSchema) <- objectSchema.properties, name `notElem` objectSchema.required]

    wantsOptional name = do
      answer <- confirm context ("set optional " <> pathLabel (path <> [name]) <> "?") False
      pure (answer == Just True)

    -- Walk fields in order, asking @wanted@ before each (required fields are always wanted); a
    -- cancel inside any field cancels the whole object.
    walkFields fields wanted = go fields []
      where
        go remaining accumulated = case remaining of
          [] -> pure (Just (reverse accumulated))
          (name, fieldSchema) : rest -> do
            include <- wanted name
            if not include
              then go rest accumulated
              else do
                value <- promptFromSchema context (path <> [name]) fieldSchema
                case value of
                  Nothing -> pure Nothing
                  Just filled -> go rest ((name, filled) : accumulated)

    promptAdditional = case objectSchema.additionalProperties of
      AdditionalPropertiesSchema valueSchema -> collectExtra valueSchema []
      AdditionalPropertiesBoolean _ -> pure (Just [])

    collectExtra valueSchema accumulated = do
      answer <- inputLine context (pathLabel path <> " — additional key (empty to finish)")
      case answer of
        Nothing -> pure Nothing
        Just line
          | Text.null (Text.strip line) -> pure (Just (reverse accumulated))
          | otherwise -> do
              let key = Text.strip line
              value <- promptFromSchema context (path <> [key]) valueSchema
              case value of
                Nothing -> pure Nothing
                Just filled -> collectExtra valueSchema ((key, filled) : accumulated)

promptAnyOf :: OutputContext -> List Text -> List JSONSchema -> IO (Maybe Value)
promptAnyOf context path branches = case constLabels branches of
  -- A union of literals is one menu, not a branch choice followed by a fixed value.
  Just options -> select context (pathLabel path) options
  Nothing -> do
    chosen <- select context (pathLabel path <> " — pick a variant") [(renderSchemaBrief branch, branch) | branch <- branches]
    case chosen of
      Nothing -> pure Nothing
      Just branch -> promptFromSchema context path branch

pathLabel :: List Text -> Text
pathLabel = Text.intercalate "."

-- ===========================================================================
-- Pure helpers
-- ===========================================================================

-- | What a free-text answer must parse as.
data TypedInputKind = InputInteger | InputNumber | InputRawJson
  deriving stock (Show, Eq)

-- | Parse one line of typed input into a JSON value. Numbers ride through aeson so their JSON
-- rendering is exact; @InputInteger@ additionally rejects a fractional answer.
coerceTypedInput :: TypedInputKind -> Text -> Either Text Value
coerceTypedInput kind input =
  let trimmed = Text.strip input
      decoded = Aeson.eitherDecodeStrict' (TextEncoding.encodeUtf8 trimmed)
   in case kind of
        InputRawJson -> case decoded of
          Right value -> Right value
          Left _ -> Left "not valid JSON — try again (strings need quotes)"
        InputInteger -> case decoded of
          Right (Number number)
            | Scientific.isInteger number -> Right (Number number)
            | otherwise -> Left "not a whole number — try again"
          _ -> Left "not an integer — try again"
        InputNumber -> case decoded of
          Right (Number number) -> Right (Number number)
          _ -> Left "not a number — try again"

-- | When every branch of a union is a literal, the labels for a one-step menu over them.
constLabels :: List JSONSchema -> Maybe (List (Text, Value))
constLabels = traverse constLabel
  where
    constLabel = \case
      SchemaConst value -> Just (compactJson value, value)
      SchemaDescribed described -> constLabel described.schema
      _ -> Nothing

-- | A one-line description of a schema, for menu labels.
renderSchemaBrief :: JSONSchema -> Text
renderSchemaBrief = \case
  SchemaAny -> "any json"
  SchemaNever -> "never"
  SchemaNull -> "null"
  SchemaBoolean -> "boolean"
  SchemaInteger -> "integer"
  SchemaNumber -> "number"
  SchemaString -> "string"
  SchemaConst value -> compactJson value
  SchemaArray element -> "array of " <> renderSchemaBrief element
  SchemaTuple elements -> "tuple (" <> Text.intercalate ", " (map renderSchemaBrief elements) <> ")"
  SchemaObject objectSchema -> case dataConstructorBrief objectSchema of
    Just brief -> brief
    Nothing -> "record {" <> Text.intercalate ", " [name | (name, _) <- objectSchema.properties] <> "}"
  SchemaAnyOf branches -> Text.intercalate " | " (map renderSchemaBrief branches)
  SchemaGeneric _ -> "any json (generic)"
  SchemaDescribed described -> renderSchemaBrief described.schema

-- | If an object schema is a @data@ value's wire schema — a @$katari_constructor@ const over fields nested
-- under @$katari_value@ (see "Katari.Schema") — a brief naming the constructor and its fields, so a union
-- picker distinguishes the variants (otherwise every @data@ arm reads @record {…}@).
dataConstructorBrief :: ObjectSchema -> Maybe Text
dataConstructorBrief objectSchema = case lookup constructorDiscriminatorKey objectSchema.properties of
  Just (SchemaConst (String name)) ->
    let fields = case lookup valueNestingKey objectSchema.properties of
          Just (SchemaObject valueObject) -> [fieldName | (fieldName, _) <- valueObject.properties]
          _ -> []
     in Just (if null fields then name else name <> " {" <> Text.intercalate ", " fields <> "}")
  _ -> Nothing

-- | A JSON value rendered compactly for labels and hints.
compactJson :: Value -> Text
compactJson = TextEncoding.decodeUtf8Lenient . LazyByteString.toStrict . Aeson.encode
