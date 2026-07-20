-- | Pure text-context detection for completion dispatch. The parser recovers only at declaration
-- boundaries, so a half-typed expression never reaches the AST — the completion context must be
-- read off the source text around the cursor instead. Everything here is pure over 'Text' /
-- the pre-split line vector, so it is testable without an LSP session.
module Katari.LSP.CompletionContext
  ( detectMemberPrefix,
    detectLabelContext,
    declarationPrefix,
  )
where

import Data.Char (isAlphaNum, isSpace)
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector (Vector)
import Data.Vector qualified as Vector
import GHC.List (List)

-- | If the text up to the cursor ends with @\<path\>.@ or @\<path\>.\<partial\>@, the dotted path
-- before the final dot — so member completion holds while the member name is being typed
-- (@discord.wa|@ still lists discord's exports; the client filters by the partial). 'Nothing'
-- when the character before that dot is not part of an identifier, so @"abc".@ or a bare
-- identifier do not trigger member completion.
detectMemberPrefix :: Text -> Maybe Text
detectMemberPrefix text = case Text.unsnoc beforePartial of
  Just (rest, '.') ->
    let pathPart = Text.takeWhileEnd isPathCharacter rest
     in if Text.null pathPart || Text.last pathPart == '.'
          then Nothing
          else Just pathPart
  _ -> Nothing
  where
    beforePartial = Text.dropWhileEnd isIdentifierCharacter text

-- | If the cursor sits inside an open @(@ whose preceding token is an identifier (dotted callables
-- like @mod.func(@ and generic applications like @mod.func[T](@ included), that callable path and
-- the set of labels already used in the current call. The scan walks backwards tracking paren
-- depth; the first unmatched @(@ marks the call.
detectLabelContext :: Text -> Maybe (Text, Set Text)
detectLabelContext text = do
  openIndex <- findOuterOpenParen text
  let beforeParen = Text.take openIndex text
      inside = Text.drop (openIndex + 1) text
      base = dropGenericApplication (Text.stripEnd beforeParen)
      raw = Text.takeWhileEnd isPathCharacter base
      callable = dropTrailingDot raw
  if Text.null callable
    then Nothing
    else Just (callable, collectUsedLabels inside)
  where
    dropTrailingDot segment = case Text.unsnoc segment of
      Just (rest, '.') -> rest
      _ -> segment

-- | Strip a trailing balanced @[...]@ group, so the callable path of a generic application
-- (@mcp.provide[mcp.scope](@) is read from before the type arguments.
dropGenericApplication :: Text -> Text
dropGenericApplication text = case Text.unsnoc text of
  Just (_, ']') -> fromMaybe text (walk (reverse (zip [0 ..] (Text.unpack text))) 0)
  _ -> text
  where
    walk :: List (Int, Char) -> Int -> Maybe Text
    walk [] _ = Nothing
    walk ((index, character) : rest) depth
      | character == ']' = walk rest (depth + 1)
      | character == '[' && depth == 1 = Just (Text.take index text)
      | character == '[' = walk rest (depth - 1)
      | otherwise = walk rest depth

-- | The index (in code points) of the first @(@ scanning right-to-left that has no matching @)@ to
-- its right within the text.
findOuterOpenParen :: Text -> Maybe Int
findOuterOpenParen text = walk (reverse (zip [0 ..] (Text.unpack text))) 0
  where
    walk :: List (Int, Char) -> Int -> Maybe Int
    walk [] _ = Nothing
    walk ((index, character) : rest) depth
      | character == ')' = walk rest (depth + 1)
      | character == '(' && depth == 0 = Just index
      | character == '(' = walk rest (depth - 1)
      | otherwise = walk rest depth

-- | The @<ident> =@ labels already written in a partial argument list (split on top-level commas,
-- ignoring commas nested in parens / brackets / braces).
collectUsedLabels :: Text -> Set Text
collectUsedLabels inside =
  Set.fromList (concatMap labelOfSegment (splitTopLevel inside ','))
  where
    labelOfSegment segment =
      case Text.breakOn "=" segment of
        (_, equalsAndRest) | Text.null equalsAndRest -> []
        (leftHandSide, _) ->
          let trimmed = Text.strip leftHandSide
              identifier = Text.takeWhile isIdentifierCharacter trimmed
           in ([identifier | not (Text.null identifier || identifier /= trimmed)])

splitTopLevel :: Text -> Char -> List Text
splitTopLevel text separator = walk (Text.unpack text) [] [] (0 :: Int)
  where
    walk [] current accumulated _ =
      reverse (Text.pack (reverse current) : map Text.pack (reverse accumulated))
    walk (character : rest) current accumulated depth
      | character == separator && depth == 0 = walk rest [] (reverse current : accumulated) depth
      | character == '(' || character == '[' || character == '{' =
          walk rest (character : current) accumulated (depth + 1)
      | character == ')' || character == ']' || character == '}' =
          walk rest (character : current) accumulated (max 0 (depth - 1))
      | otherwise = walk rest (character : current) accumulated depth

isPathCharacter :: Char -> Bool
isPathCharacter character = isIdentifierCharacter character || character == '.'

isIdentifierCharacter :: Char -> Bool
isIdentifierCharacter character = isAlphaNum character || character == '_'

-- | The text to scan for call context: the lines of the enclosing top-level declaration up to the
-- cursor, joined with newlines. Calls span lines routinely (every argument on its own line), so a
-- current-line-only scan misses the open @(@; scanning the whole file would let an unmatched paren
-- in some earlier broken declaration leak in. A column-zero non-space character starts a top-level
-- declaration — the parser's own recovery anchor — so the walk gathers lines upward until it has
-- included one such line.
declarationPrefix :: Vector Text -> Int -> Int -> Text
declarationPrefix lineVector line character =
  Text.intercalate "\n" (reverse (currentPrefix : precedingLines))
  where
    currentLine = fromMaybe "" (lineVector Vector.!? line)
    currentPrefix = Text.take character currentLine
    precedingLines
      | startsDeclaration currentLine = []
      | otherwise = collect (line - 1)
    collect index = case lineVector Vector.!? index of
      Nothing -> []
      Just lineText
        | startsDeclaration lineText -> [lineText]
        | otherwise -> lineText : collect (index - 1)
    startsDeclaration lineText = case Text.uncons lineText of
      Just (firstCharacter, _) -> not (isSpace firstCharacter)
      Nothing -> False
