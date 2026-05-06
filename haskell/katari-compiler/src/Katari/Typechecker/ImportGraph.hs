-- | Import-graph utilities used by the identifier pass to flag cyclic
-- imports. Pure graph operations; no AST traversal beyond reading the
-- @import@ declarations of each module.
module Katari.Typechecker.ImportGraph
  ( findImportCycles,
  )
where

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
-- graph. Self-imports are also flagged. Each cycle is returned as the
-- list of module names that participate in it (order is implementation
-- defined but stable for the same input).
findImportCycles :: Map ModuleName (Module Parsed) -> [[ModuleName]]
findImportCycles modules =
  let graph = Map.map importsOf modules
      nodes = Map.keys graph
      sccs = strongComponents graph nodes
      multi = filter (\xs -> length xs > 1) sccs
      selfLoops = [[n] | n <- nodes, n `Set.member` Map.findWithDefault Set.empty n graph]
   in multi <> selfLoops

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

-- | Minimal Tarjan implementation. Not optimised for large graphs (we
-- expect <1000 modules) but stable and dependency-free.
strongComponents :: Map ModuleName (Set ModuleName) -> [ModuleName] -> [[ModuleName]]
strongComponents graph allNodes =
  let go (visited, ordered) node
        | Set.member node visited = (visited, ordered)
        | otherwise =
            let (visited', subOrdered) = dfs visited node
             in (visited', subOrdered <> ordered)
      dfs visited node
        | Set.member node visited = (visited, [])
        | otherwise =
            let visited1 = Set.insert node visited
                successors = Set.toList (Map.findWithDefault Set.empty node graph)
                (visited2, sub) = foldl stepDfs (visited1, []) successors
             in (visited2, node : sub)
      stepDfs (vis, acc) n =
        let (vis', sub) = dfs vis n
         in (vis', sub <> acc)
      (_, postOrder) = foldl go (Set.empty, []) allNodes
      reversed = reverseGraph graph
      assignSccs (visited, sccs) node
        | Set.member node visited = (visited, sccs)
        | otherwise =
            let (visited', component) = collect reversed visited node
             in (visited', component : sccs)
      collect rev visited node
        | Set.member node visited = (visited, [])
        | otherwise =
            let visited1 = Set.insert node visited
                successors = Set.toList (Map.findWithDefault Set.empty node rev)
                (visited2, sub) = foldl (\(v, acc) n -> let (v', s) = collect rev v n in (v', s <> acc)) (visited1, []) successors
             in (visited2, node : sub)
      (_, components) = foldl assignSccs (Set.empty, []) postOrder
   in components

reverseGraph :: Map ModuleName (Set ModuleName) -> Map ModuleName (Set ModuleName)
reverseGraph graph =
  Map.fromListWith
    Set.union
    [ (target, Set.singleton source)
      | (source, targets) <- Map.toList graph,
        target <- Set.toList targets
    ]
