{- | Lowering pass: typed AST → Qatali IR.

This pass translates the type-annotated AST into ANF-style IR.

TODO: Phase 7 — full rewrite to match new AST and type system.
-}
module QataliCompiler.Compile.Lower (
    LowerM,
    LowerEnv (..),
    LowerState (..),
    runLower,
    lowerModule,
) where

import           Control.Monad.Reader       (ReaderT, runReaderT)
import           Control.Monad.State.Strict (StateT, evalStateT)
import           Data.Map.Strict            (Map)

import           QataliCompiler.Diagnostic  (Diagnostic)
import           QataliCompiler.IR.IR
import           QataliCompiler.Name        (Name)
import           QataliCompiler.Syntax.AST

-- ---------------------------------------------------------------------------
-- Lowering monad

data LowerEnv = LowerEnv
    { leLocalNames :: !(Map Name Name)
    }

data LowerState = LowerState
    { lsNextId :: !Int
    }

type LowerM = ReaderT LowerEnv (StateT LowerState (Either [Diagnostic]))

runLower :: LowerM a -> Either [Diagnostic] a
runLower m = evalStateT (runReaderT m env0) state0
  where
    env0 = LowerEnv mempty
    state0 = LowerState 0

-- ---------------------------------------------------------------------------
-- Lowering (stub)

lowerModule :: Module TypeInfo -> LowerM IRModule
lowerModule _m = error "TODO: lowerModule — Phase 7"
