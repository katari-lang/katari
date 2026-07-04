-- | Format-preserving edits of @katari.toml@ — the write half of @katari add@ / @katari remove@.
--
-- Only the @packages@ array inside the @[dependencies]@ table is ever rewritten; every other byte of
-- the file (comments, blank lines, unrelated tables, spacing) passes through untouched. That narrow
-- contract is what makes a text-level edit safe: rather than round-tripping the whole document
-- through a TOML parser (which would lose comments and formatting), we locate the one span we own and
-- splice a freshly-rendered array into it.
--
-- The scanner is deliberately conservative: an array holding a comment, a nested array, or a string
-- that does not close on its own line makes the edit refuse rather than guess. Callers must also
-- re-parse the returned text and verify the decoded package list before writing it to disk — that
-- gate turns any blind spot of this scanner into an abort instead of a corrupted config.
module Katari.Project.Edit
  ( EditError (..),
    renderEditError,
    rewritePackages,
  )
where

import Data.Char (isAlpha, isAlphaNum, isSpace)
import Data.List (findIndex)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.List (List)

-- | Why an edit was refused. One free-text reason is enough: every refusal has the same remedy
-- (edit the file by hand), so callers only ever render it.
newtype EditError = EditError
  { reason :: Text
  }
  deriving stock (Show, Eq)

renderEditError :: EditError -> Text
renderEditError editError =
  "cannot rewrite [dependencies].packages: " <> editError.reason <> " — edit katari.toml by hand"

-- | Rewrite the @[dependencies].packages@ array to hold exactly @names@ (already deduplicated and
-- ordered by the caller), preserving the rest of the file byte-for-byte. A missing @packages@ key is
-- inserted right under the table header; a missing @[dependencies]@ table is appended at the end.
rewritePackages :: Text -> List Text -> Either EditError Text
rewritePackages text names = do
  mapM_ requireRenderableName names
  let rendered = renderPackagesArray names
      fileLines = Text.splitOn "\n" text
  case findIndex isDependenciesHeader fileLines of
    Nothing -> Right (appendDependenciesTable text rendered)
    Just headerIndex -> rewriteInTable fileLines headerIndex rendered

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
rewriteInTable :: List Text -> Int -> Text -> Either EditError Text
rewriteInTable fileLines headerIndex rendered =
  case splitAt headerIndex fileLines of
    (beforeTable, header : afterHeader) -> do
      let (tableLines, restLines) = break isTableHeader afterHeader
      body <- rewriteTableBody tableLines rendered
      Right (joinLines (beforeTable <> (header : body) <> restLines))
    -- 'findIndex' returned this index, so the split always yields the header; refuse rather than crash
    -- if that invariant is ever broken.
    (_, []) -> Left EditError {reason = "internal error locating the [dependencies] table"}

-- | Rewrite the body lines of the @[dependencies]@ table: replace the @packages@ assignment's array
-- when the key exists, otherwise insert the assignment right under the header.
rewriteTableBody :: List Text -> Text -> Either EditError (List Text)
rewriteTableBody tableLines rendered =
  case findPackagesAssignment tableLines of
    Nothing -> Right (("packages = " <> rendered) : tableLines)
    Just (lineIndex, prefix, afterBracket) -> do
      let followingLines = drop (lineIndex + 1) tableLines
      (suffix, consumedFollowing) <- scanArraySpan afterBracket followingLines
      let (beforeAssignment, _) = splitAt lineIndex tableLines
          afterSpan = drop (lineIndex + 1 + consumedFollowing) tableLines
      Right (beforeAssignment <> ((prefix <> rendered <> suffix) : afterSpan))

-- | Find the @packages = [@ assignment among the table's lines: its index, the line's text up to (and
-- excluding) the opening bracket — preserved verbatim so the key's spacing style survives — and the
-- text after the bracket.
findPackagesAssignment :: List Text -> Maybe (Int, Text, Text)
findPackagesAssignment tableLines =
  case [(index, match) | (index, line) <- zip [0 ..] tableLines, Just match <- [matchPackagesLine line]] of
    (found : _) -> Just (let (index, (prefix, afterBracket)) = found in (index, prefix, afterBracket))
    [] -> Nothing

-- | Match one line as @packages = [@ (any spacing), splitting it at the opening bracket. A line whose
-- key merely starts with @packages@ (e.g. @packages_extra@) is not a match; a @packages@ key whose
-- value is not an array is also treated as no match, and the duplicate-key insert that follows makes
-- the caller's re-parse gate reject the result rather than this scanner guessing.
matchPackagesLine :: Text -> Maybe (Text, Text)
matchPackagesLine line = do
  let (indent, afterIndent) = Text.span isSpace line
  afterKey <- Text.stripPrefix "packages" afterIndent
  let (spaceAfterKey, afterKeySpace) = Text.span isSpace afterKey
  afterEquals <- Text.stripPrefix "=" afterKeySpace
  let (spaceAfterEquals, value) = Text.span isSpace afterEquals
  afterBracket <- Text.stripPrefix "[" value
  -- The rendered replacement carries its own brackets, so the preserved prefix stops before this one.
  Just (indent <> "packages" <> spaceAfterKey <> "=" <> spaceAfterEquals, afterBracket)

-- ===========================================================================
-- Scanning the array span
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

-- | Scan from just after the opening bracket to the matching close, across as many lines as the array
-- spans. Returns the text after the closing bracket (the original line's tail, e.g. a trailing
-- comment) and how many of @followingLines@ the span consumed.
scanArraySpan :: Text -> List Text -> Either EditError (Text, Int)
scanArraySpan firstLine followingLines = go ScanPlain firstLine followingLines 0
  where
    go state currentLine remainingLines consumed = case scanLine state currentLine of
      Left editError -> Left editError
      Right (Right suffix) -> Right (suffix, consumed)
      Right (Left endState) -> case endState of
        ScanPlain -> case remainingLines of
          nextLine : moreLines -> go ScanPlain nextLine moreLines (consumed + 1)
          [] -> Left EditError {reason = "the packages array never closes"}
        -- TOML basic / literal strings are single-line; reaching a line's end inside one means the
        -- file is not something this scanner understands.
        _ -> Left EditError {reason = "a string in the packages array does not close on its line"}

-- | Walk one line's characters: either the array closes here (returning the tail after @]@), or the
-- line ends in the given state.
scanLine :: ScanState -> Text -> Either EditError (Either ScanState Text)
scanLine state text = case Text.uncons text of
  Nothing -> Right (Left state)
  Just (character, rest) -> case state of
    ScanPlain -> case character of
      ']' -> Right (Right rest)
      -- A comment inside the array cannot be preserved through a rewrite; refuse instead of dropping it.
      '#' -> Left EditError {reason = "the packages array holds a comment"}
      '[' -> Left EditError {reason = "the packages array holds a nested array"}
      '"' -> scanLine ScanBasic rest
      '\'' -> scanLine ScanLiteral rest
      _ -> scanLine ScanPlain rest
    ScanBasic -> case character of
      '\\' -> scanLine ScanBasicEscape rest
      '"' -> scanLine ScanPlain rest
      _ -> scanLine ScanBasic rest
    ScanBasicEscape -> scanLine ScanBasic rest
    ScanLiteral -> case character of
      '\'' -> scanLine ScanPlain rest
      _ -> scanLine ScanLiteral rest

-- ===========================================================================
-- Rendering
-- ===========================================================================

-- | Append a fresh @[dependencies]@ table at the end of the file, separated by one blank line. The
-- file's trailing newlines are normalised to the single final one this writes.
appendDependenciesTable :: Text -> Text -> Text
appendDependenciesTable text rendered =
  let body = Text.dropWhileEnd (== '\n') text
      separator = if Text.null body then "" else "\n\n"
   in body <> separator <> "[dependencies]\npackages = " <> rendered <> "\n"

renderPackagesArray :: List Text -> Text
renderPackagesArray names =
  "[" <> Text.intercalate ", " ["\"" <> name <> "\"" | name <- names] <> "]"

-- | Refuse a name that could not be spliced into the array as a plain quoted string. Callers validate
-- names as identifiers long before this; the check keeps the renderer safe on its own terms.
requireRenderableName :: Text -> Either EditError ()
requireRenderableName name = case Text.uncons name of
  Just (first, rest)
    | (isAlpha first || first == '_') && Text.all (\character -> isAlphaNum character || character == '_') rest ->
        Right ()
  _ -> Left EditError {reason = "package name '" <> name <> "' is not a valid identifier"}

joinLines :: List Text -> Text
joinLines = Text.intercalate "\n"
