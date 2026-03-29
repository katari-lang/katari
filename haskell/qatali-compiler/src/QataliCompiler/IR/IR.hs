{- | Qatali Intermediate Representation.

This module re-exports the full IR definition for convenience.
The IR is a VarId-based bytecode organized in basic blocks, designed for:

  * Binary serialization and compact network transmission
  * Async execution with PostgreSQL persistence
  * Server-to-server algebraic effect handling
  * Hot-swapping of function definitions by name

All variables are referenced by numeric 'VarId's. A 'NameTable' maps
IDs back to human-readable names for persistence and debugging.
-}
module QataliCompiler.IR.IR (
    -- * Identifier newtypes and name table
    module QataliCompiler.IR.Types,
    -- * Instructions and terminators
    module QataliCompiler.IR.Instruction,
    -- * Module structure
    module QataliCompiler.IR.Module,
) where

import QataliCompiler.IR.Instruction
import QataliCompiler.IR.Module
import QataliCompiler.IR.Types
