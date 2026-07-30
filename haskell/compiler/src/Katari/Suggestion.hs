-- | The "did you mean …?" tail an unresolved-name diagnostic carries.
--
-- Two rules keep a suggestion trustworthy. The candidates are always the names actually in scope at
-- the failing reference — this module never invents a name the reader could not have written — and a
-- candidate is offered only when it is within a few edits of what WAS written: a suggestion that is
-- not almost-right costs the reader more than no suggestion at all.
module Katari.Suggestion where

import Data.List (foldl', sortOn)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.List (List)

-- | At most 'suggestionLimit' names, nearest first, from the candidates worth offering for @written@.
-- Ties break on the name so the output is deterministic (diagnostics are compared byte-for-byte by
-- tests and by the agents that read them).
nearestNames :: Text -> List Text -> List Text
nearestNames written candidates
  -- A one- or two-character name has every other short name within its edit budget, so a suggestion
  -- there would be noise rather than a hint.
  | Text.length written < 3 = []
  | otherwise = take suggestionLimit [name | (_, name) <- sortOn id scored]
  where
    scored =
      [ (distance, candidate)
        | candidate <- distinct candidates,
          candidate /= written,
          let distance = editDistance written candidate,
          distance <= allowedDistance written candidate
      ]

-- | How many candidates a message offers. Three is the point where the list stops reading as a hint
-- and starts reading as a dump of the scope.
suggestionLimit :: Int
suggestionLimit = 3

-- | How far a candidate may sit from the written name and still be worth reading: a third of the
-- shorter name's characters, at least one edit and never more than three. Scaling by the shorter name
-- is what keeps a one-character slip in a short name suggestible without letting an unrelated long
-- name qualify.
allowedDistance :: Text -> Text -> Int
allowedDistance written candidate =
  max 1 (min 3 (min (Text.length written) (Text.length candidate) `div` 3))

-- | Optimal string alignment distance: the number of single-character insertions, deletions,
-- substitutions and ADJACENT TRANSPOSITIONS that turn one name into the other.
--
-- Transpositions count as one edit deliberately. The commonest real typo is a swap (@jion@ for
-- @join@), which a plain Levenshtein scores 2 — so keeping the budget tight enough to stay quiet
-- would drop exactly the suggestion the reader needs.
editDistance :: Text -> Text -> Int
editDistance leftText rightText =
  finalDistance (foldl' nextRow (firstRow, [], Nothing) (zip [1 ..] (Text.unpack leftText)))
  where
    rightCharacters = Text.unpack rightText
    firstRow = [0 .. length rightCharacters]

    -- The fold carries row @index-1@, row @index-2@ (the transposition case reads it) and the left's
    -- previous character, and produces the same triple for the next row.
    nextRow (previousRow, twoRowsBack, previousLeftCharacter) (index, leftCharacter) =
      ( index : buildRow index previousRow twoRowsBack previousLeftCharacter leftCharacter,
        previousRow,
        Just leftCharacter
      )

    -- One row, left to right: at column @j@, @leftValue@ is this row's cell at @j-1@, @previous@ is
    -- row @index-1@ from column @j-1@ on, and @twoBack@ is row @index-2@ from column @j-2@ on.
    buildRow index previousRow twoRowsBack previousLeftCharacter leftCharacter =
      -- Row @index-2@ is prefixed with a sentinel so its head is column @j-2@ at every step; that
      -- sentinel is only ever the head at column 1, where the transposition case is closed anyway.
      go index previousRow (0 : twoRowsBack) Nothing rightCharacters
      where
        go leftValue previous twoBack previousRightCharacter characters =
          case (previous, characters) of
            (upperLeft : upper : previousRest, rightCharacter : charactersRest) ->
              let substitution = upperLeft + (if rightCharacter == leftCharacter then 0 else 1)
                  -- A swap of the two names' adjacent characters, priced at one edit; reachable only
                  -- once both names have a previous character and row @index-2@ exists.
                  transposition = case (twoBack, previousRightCharacter, previousLeftCharacter) of
                    (diagonal : _, Just previousRight, Just previousLeft)
                      | leftCharacter == previousRight && previousLeft == rightCharacter ->
                          [diagonal + 1]
                    _ -> []
                  value = minimum ([leftValue + 1, upper + 1, substitution] <> transposition)
               in value : go value (upper : previousRest) (drop 1 twoBack) (Just rightCharacter) charactersRest
            _ -> []

    -- The last row's last entry is the whole-name distance. Total: every row carries at least its
    -- column-0 entry, and 0 is the distance an empty pair would have anyway.
    finalDistance (row, _, _) = foldl' (\_ value -> value) 0 row

-- | The names of @candidates@ without repeats, order preserved. The candidate lists come from scope
-- maps and export maps, which may name the same thing twice across namespaces.
distinct :: List Text -> List Text
distinct = go []
  where
    go seen names = case names of
      [] -> []
      name : rest
        | name `elem` seen -> go seen rest
        | otherwise -> name : go (name : seen) rest

-- | The @did you mean@ tail for a set of candidates, empty when there are none — so every caller can
-- append it unconditionally.
renderSuggestion :: List Text -> Text
renderSuggestion = \case
  [] -> ""
  [single] -> "; did you mean `" <> single <> "`?"
  several -> "; did you mean one of " <> Text.intercalate ", " (backticked <$> several) <> "?"
  where
    backticked name = "`" <> name <> "`"
