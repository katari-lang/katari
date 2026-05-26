-- | Shared helpers for extracting nested TOML sub-tables.
--
-- tomland's @tableMap@ does not reliably decode nested @[prefix.name]@
-- sections. This module provides a generic 'extractNestedTables'
-- combinator that walks 'Toml.PrefixTree' entries under a given
-- top-level piece, strips the prefix from the fully-qualified key,
-- and decodes each leaf with a caller-supplied function.
module Katari.Project.Toml
  ( extractNestedTables,
  )
where

import qualified Data.HashMap.Strict as HashMap
import qualified Data.List.NonEmpty as NonEmpty
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Toml.Type.Key as Toml
import qualified Toml.Type.PrefixTree as Toml
import qualified Toml.Type.TOML as Toml

-- | Walk every nested sub-table under @sectionName@ in the raw TOML
-- AST, decode each leaf via @decodeSub@, and collect the results into
-- a 'Map'. The key passed to @decodeSub@ is the dot-joined tail after
-- stripping the leading @sectionName@ piece.
extractNestedTables ::
  forall e a.
  Text ->
  (Text -> Toml.TOML -> Either e a) ->
  Toml.TOML ->
  Either e (Map Text a)
extractNestedTables sectionName decodeSub toml =
  case HashMap.lookup sectionPiece (Toml.tomlTables toml) of
    Nothing -> Right Map.empty
    Just tree -> Map.fromList <$> walk tree
  where
    sectionPiece = Toml.Piece sectionName

    walk :: Toml.PrefixTree Toml.TOML -> Either e [(Text, a)]
    walk = \case
      Toml.Leaf fullKey sub ->
        case dropSectionPrefix fullKey of
          Nothing -> Right []
          Just name -> do
            value <- decodeSub name sub
            Right [(name, value)]
      Toml.Branch _ _ children ->
        concat <$> traverse walk (HashMap.elems children)

    dropSectionPrefix :: Toml.Key -> Maybe Text
    dropSectionPrefix key = case NonEmpty.toList (Toml.unKey key) of
      Toml.Piece p : rest@(_ : _) | p == sectionName ->
        Just (Text.intercalate "." [piece | Toml.Piece piece <- rest])
      _ -> Nothing
