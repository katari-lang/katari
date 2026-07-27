-- | Does @katari.lock@ still describe the closure @katari.toml@ asks for?
--
-- The lock is the source of truth for what compiles: every offline load reads the closure out of it
-- and never consults the registry. That only stays honest while the lock and the manifest agree.
-- When they drift, the compiler is fed a package set nobody asked for and reports success about it —
-- a wrong answer dressed as a green one. This module is the one place that decides whether they
-- agree; "Katari.Project.Resolve" refuses the load on whatever it reports.
--
-- The two are in sync when all of the following hold:
--
--   1. The lock's @[lock].snapshot@ equals the manifest's @[dependencies].snapshot@ (an absent pin
--      must match an absent pin).
--   2. Every package the closure reaches — the root's @[dependencies].packages@ plus, transitively,
--      the names each locked package declares — has an entry in the lock.
--   3. Every entry in the lock is reachable that way, so removing a dependency cannot leave its
--      resolution behind.
--   4. Each locked package's source is the one the manifest sends it to: an @[overrides.\<name>]@
--      entry must match the recorded @path@ (or @url@ + @rev@) exactly, and a name with no override
--      must be locked as a git source, since only the registry could have supplied it.
--
-- One thing is deliberately /not/ checked: whether a snapshot-sourced package's @(url, rev)@ still
-- matches the registry's pin for it. That fact lives on the network, and these checks must run
-- offline. Rule 1 stands in for it, and stands in for it completely — even for the mutable
-- @staging@ set, because the lock froze whatever @staging@ held at lock time and re-freezing it is
-- exactly what @katari lock@ is for.
module Katari.Project.Reconcile
  ( manifestMismatches,
    closureMismatches,
  )
where

import Data.List (sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.List (List)
import Katari.Project.Config
  ( DependenciesSection (..),
    GitOverride (..),
    OverrideSource (..),
    PathOverride (..),
    ProjectConfig (..),
  )
import Katari.Project.Error
  ( DependencyInfo (..),
    LockMismatch (..),
    SnapshotPinInfo (..),
    SourceChangeInfo (..),
  )
import Katari.Project.Lockfile
  ( GitSource (..),
    LockedSource (..),
    Lockfile (..),
    PathLock (..),
  )

-- | Everything answerable from the root manifest and the lock alone: the snapshot pin, and where
-- each locked package was resolved from. Runs before any package is loaded, so a drifted lock is
-- reported as a lock problem rather than as the cache miss it would otherwise cause downstream.
--
-- A project that declares no dependencies and locks none has no closure to disagree about: the
-- snapshot pin resolved nothing, so a stale (or absent) pin cannot have changed what compiles. That
-- is what keeps a freshly scaffolded project — which pins a snapshot but has yet to add a package —
-- from having to lock before it can be checked.
manifestMismatches :: ProjectConfig -> Lockfile -> List LockMismatch
manifestMismatches config lockfile
  | null config.dependencies.packages && Map.null lockfile.packages = []
  | otherwise = snapshotPinMismatch <> sourceMismatches
  where
    snapshotPinMismatch
      | lockfile.snapshot == config.dependencies.snapshot = []
      | otherwise =
          [SnapshotPinChanged SnapshotPinInfo {locked = lockfile.snapshot, declared = config.dependencies.snapshot}]

    sourceMismatches =
      [ DependencySourceChanged
          SourceChangeInfo
            { dependency = name,
              locked = renderLockedSource lockedSource,
              declared = renderExpectedSource expected
            }
        | (name, lockedSource) <- Map.toAscList lockfile.packages,
          let expected = expectedSourceFor config name,
          not (agrees expected lockedSource)
      ]

-- | Everything that needs the dependency graph: which names the closure actually reaches, given the
-- root's declared list and each locked package's own declared list. Runs after the locked packages
-- are loaded, since their @[dependencies].packages@ is the only place the graph's edges are written
-- down.
--
-- Callers run 'manifestMismatches' first and stop on any result, so by the time this runs the root's
-- direct dependencies are known to be locked and only transitive gaps remain to report.
closureMismatches :: List Text -> Map Text (List Text) -> List LockMismatch
closureMismatches declared lockedGraph =
  [DependencyMissingFromLock DependencyInfo {dependency = name} | name <- sort (Set.toList missing)]
    <> [DependencyOrphanedInLock DependencyInfo {dependency = name} | name <- sort (Set.toList orphaned)]
  where
    locked = Map.keysSet lockedGraph
    reachable = walk Set.empty declared
    missing = Set.difference reachable locked
    orphaned = Set.difference locked reachable

    -- Breadth of the graph is tiny (a project's whole closure), so a plain worklist is enough; the
    -- visited set is what terminates it on a dependency cycle.
    walk :: Set Text -> List Text -> Set Text
    walk visited pending = case pending of
      [] -> visited
      name : rest
        | Set.member name visited -> walk visited rest
        | otherwise ->
            walk (Set.insert name visited) (Map.findWithDefault [] name lockedGraph <> rest)

-- ===========================================================================
-- Where a dependency is supposed to come from
-- ===========================================================================

-- | The manifest's answer to "where does this dependency come from". An override names the source
-- outright; anything else is the registry's business, which an offline check cannot inspect beyond
-- knowing it must be a git source.
data ExpectedSource
  = ExpectedOverride OverrideSource
  | ExpectedSnapshot

expectedSourceFor :: ProjectConfig -> Text -> ExpectedSource
expectedSourceFor config name = maybe ExpectedSnapshot ExpectedOverride (Map.lookup name config.overrides)

-- | Whether a recorded resolution is the one the manifest asks for. Total over both sums, so every
-- combination is a decision rather than a fallthrough.
agrees :: ExpectedSource -> LockedSource -> Bool
agrees expected lockedSource = case (expected, lockedSource) of
  (ExpectedOverride (OverridePath override), LockedPath lock) -> lock.location == override.path
  (ExpectedOverride (OverrideGit override), LockedGit lock) -> lock.url == override.url && lock.rev == override.rev
  (ExpectedOverride (OverridePath _), LockedGit _) -> False
  (ExpectedOverride (OverrideGit _), LockedPath _) -> False
  -- The registry only ever hands out git sources, so a path lock proves an override was deleted.
  -- Whether the git pin itself still matches the snapshot is rule 1's job, not this one's.
  (ExpectedSnapshot, LockedGit _) -> True
  (ExpectedSnapshot, LockedPath _) -> False

renderLockedSource :: LockedSource -> Text
renderLockedSource lockedSource = case lockedSource of
  LockedPath lock -> "path " <> Text.pack lock.location
  LockedGit lock -> "git " <> lock.url <> " @ " <> lock.rev

renderExpectedSource :: ExpectedSource -> Text
renderExpectedSource expected = case expected of
  ExpectedOverride (OverridePath override) -> "path " <> Text.pack override.path
  ExpectedOverride (OverrideGit override) -> "git " <> override.url <> " @ " <> override.rev
  ExpectedSnapshot -> "the registry snapshot"
