-- | Import-graph utilities used by the identifier pass to flag cyclic
-- imports. Pure graph operations; no AST traversal beyond reading the
-- @import@ declarations of each module.
module Katari.Typechecker.ImportGraph
  ( findImportCycles,
  )
where

import Data.Graph (SCC (..), stronglyConnComp)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Katari.AST
  ( Declaration (..),
    ImportDeclaration (..),
    ImportKind (..),
    Module (..),
    Phase (Parsed),
  )

type ModuleName = Text

-- | Detect any non-trivial strongly-connected component in the import
-- graph. Self-imports are also flagged (as singleton lists). Each cycle
-- is returned as the list of module names that participate in it (order
-- follows 'Data.Graph.stronglyConnComp', which is stable for the same
-- input).
findImportCycles :: Map ModuleName (Module Parsed) -> [[ModuleName]]
findImportCycles modules =
  [ vs
    | CyclicSCC vs <-
        stronglyConnComp
          [ (name, name, Set.toList (importsOf m))
            | (name, m) <- Map.toList modules
          ]
  ]

importsOf :: Module Parsed -> Set ModuleName
importsOf m =
  Set.fromList
    [ importModuleName imp
      | DeclarationImport ImportDeclaration {kind = imp} <- m.declarations
    ]

importModuleName :: ImportKind -> ModuleName
importModuleName = \case
  ImportNames {moduleName} -> moduleName
  ImportModule {moduleName} -> moduleName
