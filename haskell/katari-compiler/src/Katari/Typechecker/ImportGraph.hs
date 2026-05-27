-- | Import-graph utilities used by the identifier pass to flag cyclic
-- imports. Pure graph operations; no AST traversal beyond reading the
-- @import@ declarations of each module.
module Katari.Typechecker.ImportGraph
  ( findImportCycles,
    topologicalSort,
    importsOf,
  )
where

import Data.Graph (SCC (..), stronglyConnComp)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
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

-- | Compute a topological ordering of the module graph, grouped into
-- parallel levels. Each inner set contains modules whose dependencies
-- are all in earlier levels, so they can be processed in parallel.
-- Cyclic modules are excluded (reject them via 'findImportCycles' first).
topologicalSort :: Map ModuleName (Module Parsed) -> [Set ModuleName]
topologicalSort modules = go (Map.keysSet modules) Set.empty
  where
    deps = Map.map (\m -> importsOf m `Set.intersection` Map.keysSet modules) modules
    go remaining processed
      | Set.null remaining = []
      | Set.null ready = []
      | otherwise = ready : go (remaining Set.\\ ready) (processed `Set.union` ready)
      where
        ready = Set.filter
          (\m -> Set.isSubsetOf (Map.findWithDefault Set.empty m deps) processed)
          remaining

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
