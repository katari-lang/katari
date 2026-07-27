-- | Format-preserving edits of @katari.toml@ — the write half of @katari add@ / @katari remove@ /
-- @katari update@.
--
-- Only one key inside the @[dependencies]@ table is ever rewritten (@packages@ for add/remove,
-- @snapshot@ for update); every other byte of the file (comments, blank lines, unrelated tables,
-- spacing) passes through untouched. That narrow contract is what makes a text-level edit safe:
-- rather than round-tripping the whole document through a TOML parser (which would lose comments and
-- formatting), we locate the one span we own and splice a freshly-rendered value into it.
--
-- Both edits are the same operation over a different value shape, so they share everything but a
-- 'ValueEdit': the key to find, the replacement text, and how far the old value extends.
--
-- The scanners are deliberately conservative: an array holding a comment, a nested array, or a
-- string that does not close on its own line makes the edit refuse rather than guess. Callers must
-- also re-parse the returned text and verify the decoded value before writing it to disk — that gate
-- turns any blind spot of these scanners into an abort instead of a corrupted config.
module Katari.Project.Edit
  ( EditError (..),
    renderEditError,
    rewritePackages,
    rewriteSnapshot,
  )
where

import Data.Char (isAlpha, isAlphaNum, isAsciiLower, isAsciiUpper, isDigit, isSpace)
import Data.List (findIndex)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.List (List)

-- | Why an edit was refused. The key it concerns plus one free-text reason: every refusal has the
-- same remedy (edit the file by hand), so callers only ever render it.
data EditError = EditError
  { key :: Text,
    reason :: Text
  }
  deriving stock (Show, Eq)

renderEditError :: EditError -> Text
renderEditError editError =
  "cannot rewrite [dependencies]." <> editError.key <> ": " <> editError.reason <> " — edit katari.toml by hand"

-- | One key's replacement inside @[dependencies]@: which key, the already-rendered TOML value to put
-- there, and how to find where the old value ends.
data ValueEdit = ValueEdit
  { key :: Text,
    -- | The new value as TOML text, brackets or quotes included.
    rendered :: Text,
    -- | Scan the old value from its first character across as many lines as it spans, returning the
    -- text that follows it on its last line (a trailing comment, say) and how many of the following
    -- lines it consumed.
    scanValue :: Text -> List Text -> Either EditError (Text, Int)
  }

-- | Rewrite the @[dependencies].packages@ array to hold exactly @names@ (already deduplicated and
-- ordered by the caller), preserving the rest of the file byte-for-byte.
rewritePackages :: Text -> List Text -> Either EditError Text
rewritePackages text names = do
  mapM_ (requireRenderableName keyPackages) names
  rewriteDependencyKey
    text
    ValueEdit {key = keyPackages, rendered = renderPackagesArray names, scanValue = scanArraySpan keyPackages}

-- | Rewrite the @[dependencies].snapshot@ pin to @name@, preserving the rest of the file
-- byte-for-byte.
rewriteSnapshot :: Text -> Text -> Either EditError Text
rewriteSnapshot text name = do
  requireRenderableSnapshot name
  rewriteDependencyKey
    text
    ValueEdit {key = keySnapshot, rendered = "\"" <> name <> "\"", scanValue = scanStringSpan keySnapshot}

keyPackages, keySnapshot :: Text
keyPackages = "packages"
keySnapshot = "snapshot"

-- | Splice one key's value inside the @[dependencies]@ table. A missing key is inserted right under
-- the table header; a missing @[dependencies]@ table is appended at the end of the file.
rewriteDependencyKey :: Text -> ValueEdit -> Either EditError Text
rewriteDependencyKey text edit =
  let fileLines = Text.splitOn "\n" text
   in case findIndex isDependenciesHeader fileLines of
        Nothing -> Right (appendDependenciesTable text edit)
        Just headerIndex -> rewriteInTable fileLines headerIndex edit

-- ===========================================================================
-- Locating the span
-- ===========================================================================

-- | Whether a line is the @[dependencies]@ table header (only whitespace or a comment may follow it).
isDependenciesHeader :: Text -> Bool
isDependenciesHeader line =
  maybe False isLineTail (Text.stripPrefix "[dependencies]" (Text.stripStart line))

-- | Whether a line opens any table (ends the @[dependencies]@ table's extent).
isTableHeader :: Text -> Bool
isTableHeader line = "[" `Text.isPrefixOf` Text.stripStart line

-- | Whether text may trail a complete construct on its line: nothing but whitespace or a comment.
isLineTail :: Text -> Bool
isLineTail rest =
  let trimmed = Text.stripStart rest
   in Text.null trimmed || "#" `Text.isPrefixOf` trimmed

-- | Rewrite inside an existing @[dependencies]@ table (its header is at @headerIndex@).
rewriteInTable :: List Text -> Int -> ValueEdit -> Either EditError Text
rewriteInTable fileLines headerIndex edit =
  case splitAt headerIndex fileLines of
    (beforeTable, header : afterHeader) -> do
      let (tableLines, restLines) = break isTableHeader afterHeader
      body <- rewriteTableBody tableLines edit
      Right (joinLines (beforeTable <> (header : body) <> restLines))
    -- 'findIndex' returned this index, so the split always yields the header; refuse rather than crash
    -- if that invariant is ever broken.
    (_, []) -> Left EditError {key = edit.key, reason = "internal error locating the [dependencies] table"}

-- | Rewrite the body lines of the @[dependencies]@ table: replace the key's value when it is there,
-- otherwise insert the assignment right under the header.
rewriteTableBody :: List Text -> ValueEdit -> Either EditError (List Text)
rewriteTableBody tableLines edit =
  case findAssignment edit.key tableLines of
    Nothing -> Right ((edit.key <> " = " <> edit.rendered) : tableLines)
    Just (lineIndex, prefix, value) -> do
      let followingLines = drop (lineIndex + 1) tableLines
      (suffix, consumedFollowing) <- edit.scanValue value followingLines
      let (beforeAssignment, _) = splitAt lineIndex tableLines
          afterSpan = drop (lineIndex + 1 + consumedFollowing) tableLines
      Right (beforeAssignment <> ((prefix <> edit.rendered <> suffix) : afterSpan))

-- | Find the @\<key> =@ assignment among the table's lines: its index, the line's text up to (and
-- including) the @=@ and the spacing around it — preserved verbatim so the key's style survives —
-- and the value text that follows.
findAssignment :: Text -> List Text -> Maybe (Int, Text, Text)
findAssignment key tableLines =
  case [(index, match) | (index, line) <- zip [0 ..] tableLines, Just match <- [matchAssignment key line]] of
    (found : _) -> Just (let (index, (prefix, value)) = found in (index, prefix, value))
    [] -> Nothing

-- | Match one line as @\<key> = \<value>@ (any spacing), splitting it just before the value. A line
-- whose key merely starts with @key@ (e.g. @packages_extra@) is not a match, because the @=@ then
-- fails to follow.
matchAssignment :: Text -> Text -> Maybe (Text, Text)
matchAssignment key line = do
  let (indent, afterIndent) = Text.span isSpace line
  afterKey <- Text.stripPrefix key afterIndent
  let (spaceAfterKey, afterKeySpace) = Text.span isSpace afterKey
  afterEquals <- Text.stripPrefix "=" afterKeySpace
  let (spaceAfterEquals, value) = Text.span isSpace afterEquals
  Just (indent <> key <> spaceAfterKey <> "=" <> spaceAfterEquals, value)

-- ===========================================================================
-- Scanning a value's span
-- ===========================================================================

-- | Where the scanner is inside the array's text.
data ScanState
  = -- | Between values.
    ScanPlain
  | -- | Inside a basic @"..."@ string.
    ScanBasic
  | -- | Inside a basic string, right after a backslash.
    ScanBasicEscape
  | -- | Inside a literal @'...'@ string.
    ScanLiteral

-- | Scan an array value from its opening bracket to the matching close, across as many lines as the
-- array spans. Returns the text after the closing bracket (the original line's tail, e.g. a trailing
-- comment) and how many of @followingLines@ the span consumed.
scanArraySpan :: Text -> Text -> List Text -> Either EditError (Text, Int)
scanArraySpan key value followingLines = case Text.stripPrefix "[" value of
  Nothing -> Left EditError {key = key, reason = "the value is not an array"}
  Just afterBracket -> go ScanPlain afterBracket followingLines 0
  where
    go state currentLine remainingLines consumed = case scanLine key state currentLine of
      Left editError -> Left editError
      Right (Right suffix) -> Right (suffix, consumed)
      Right (Left endState) -> case endState of
        ScanPlain -> case remainingLines of
          nextLine : moreLines -> go ScanPlain nextLine moreLines (consumed + 1)
          [] -> Left EditError {key = key, reason = "the array never closes"}
        -- TOML basic / literal strings are single-line; reaching a line's end inside one means the
        -- file is not something this scanner understands.
        _ -> Left EditError {key = key, reason = "a string in the array does not close on its line"}

-- | Walk one line's characters: either the array closes here (returning the tail after @]@), or the
-- line ends in the given state.
scanLine :: Text -> ScanState -> Text -> Either EditError (Either ScanState Text)
scanLine key state text = case Text.uncons text of
  Nothing -> Right (Left state)
  Just (character, rest) -> case state of
    ScanPlain -> case character of
      ']' -> Right (Right rest)
      -- A comment inside the array cannot be preserved through a rewrite; refuse instead of dropping it.
      '#' -> Left EditError {key = key, reason = "the array holds a comment"}
      '[' -> Left EditError {key = key, reason = "the array holds a nested array"}
      '"' -> scanLine key ScanBasic rest
      '\'' -> scanLine key ScanLiteral rest
      _ -> scanLine key ScanPlain rest
    ScanBasic -> case character of
      '\\' -> scanLine key ScanBasicEscape rest
      '"' -> scanLine key ScanPlain rest
      _ -> scanLine key ScanBasic rest
    ScanBasicEscape -> scanLine key ScanBasic rest
    ScanLiteral -> case character of
      '\'' -> scanLine key ScanPlain rest
      _ -> scanLine key ScanLiteral rest

-- | Scan a quoted string value to its closing quote. A TOML basic or literal string closes on its
-- own line, so this never consumes a following line; a multi-line (@\"\"\"@) form or a bare value is
-- refused rather than guessed at.
scanStringSpan :: Text -> Text -> List Text -> Either EditError (Text, Int)
scanStringSpan key value _followingLines = case Text.uncons value of
  Just (quoteCharacter, afterQuote)
    | quoteCharacter == '"' || quoteCharacter == '\'' ->
        -- A multi-line delimiter opens with three quotes, whose first two would otherwise read as an
        -- empty string and leave the rest of the value spliced in behind the replacement.
        if Text.replicate 2 (Text.singleton quoteCharacter) `Text.isPrefixOf` afterQuote
          then Left EditError {key = key, reason = "the value is a multi-line string"}
          else case closeQuotedString quoteCharacter afterQuote of
            Just suffix -> Right (suffix, 0)
            Nothing -> Left EditError {key = key, reason = "the string value does not close on its line"}
  _ -> Left EditError {key = key, reason = "the value is not a single-line quoted string"}

-- | The text following a quoted string's closing quote, or 'Nothing' when it never closes. Only a
-- basic string honours backslash escapes; a literal string, by TOML's rule, has none.
closeQuotedString :: Char -> Text -> Maybe Text
closeQuotedString quoteCharacter = go
  where
    go text = case Text.uncons text of
      Nothing -> Nothing
      Just (character, rest)
        | character == quoteCharacter -> Just rest
        | character == '\\' && quoteCharacter == '"' -> Text.uncons rest >>= \(_, afterEscaped) -> go afterEscaped
        | otherwise -> go rest

-- ===========================================================================
-- Rendering
-- ===========================================================================

-- | Append a fresh @[dependencies]@ table at the end of the file, separated by one blank line. The
-- file's trailing newlines are normalised to the single final one this writes.
appendDependenciesTable :: Text -> ValueEdit -> Text
appendDependenciesTable text edit =
  let body = Text.dropWhileEnd (== '\n') text
      separator = if Text.null body then "" else "\n\n"
   in body <> separator <> "[dependencies]\n" <> edit.key <> " = " <> edit.rendered <> "\n"

renderPackagesArray :: List Text -> Text
renderPackagesArray names =
  "[" <> Text.intercalate ", " ["\"" <> name <> "\"" | name <- names] <> "]"

-- | Refuse a name that could not be spliced into the array as a plain quoted string. Callers validate
-- names as identifiers long before this; the check keeps the renderer safe on its own terms.
requireRenderableName :: Text -> Text -> Either EditError ()
requireRenderableName key name = case Text.uncons name of
  Just (first, rest)
    | (isAlpha first || first == '_') && Text.all (\character -> isAlphaNum character || character == '_') rest ->
        Right ()
  _ -> Left EditError {key = key, reason = "package name '" <> name <> "' is not a valid identifier"}

-- | Refuse a snapshot name that could not be spliced in as a plain quoted string. Snapshot ids are
-- @[A-Za-z0-9._-]@ tokens by the registry's own layout rule (the name becomes a path segment), so
-- anything else would need escaping this renderer deliberately does not do.
requireRenderableSnapshot :: Text -> Either EditError ()
requireRenderableSnapshot name
  | not (Text.null name) && Text.all isSnapshotChar name = Right ()
  | otherwise =
      Left EditError {key = keySnapshot, reason = "snapshot name '" <> name <> "' must contain only [A-Za-z0-9._-]"}
  where
    isSnapshotChar character =
      isAsciiLower character || isAsciiUpper character || isDigit character || character `elem` ['.', '_', '-']

joinLines :: List Text -> Text
joinLines = Text.intercalate "\n"
