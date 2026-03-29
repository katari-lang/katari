{- | Top-level API for the Qatali compiler.

Compilation pipeline:

> Source Text
>   → (Parse)     → AST SrcSpan
>   → (Typecheck) → diagnostics + TypeDefs
>   → (Lower)     → IR Program
>   → (Emit)      → Text / Binary
-}
module QataliCompiler.Lib (
    -- * Pipeline entry point
    compileText,
    CompileResult (..),
    CompileError (..),

    -- * Re-exports for convenience
    module QataliCompiler.SrcLoc,
    module QataliCompiler.Name,
    module QataliCompiler.Diagnostic,
) where

import qualified Data.Map.Strict                as Map
import           Data.Text                      (Text)
import qualified Data.Text                      as T

import           QataliCompiler.Codegen.Emit    (emitToText)
import           QataliCompiler.Compile.Lower   (lowerModule)
import           QataliCompiler.Diagnostic
import           QataliCompiler.Name
import           QataliCompiler.Parse.Parser    (parseModule)
import           QataliCompiler.SrcLoc
import           QataliCompiler.Type.Defs       (TypeDefs (..))
import           QataliCompiler.Typecheck.Check  (checkModule, runCheckWithDefs)

-- | Errors that can occur during compilation.
data CompileError
    = ParseError  !Text
    | TypeError   ![Diagnostic]
    | LowerError  ![Diagnostic]
    | EmitError   !Text
    deriving (Show)

-- | The result of a successful compilation.
data CompileResult = CompileResult
    { crOutput :: !Text
    }
    deriving (Show)

-- | Empty type definitions (used until declaration registration is fully wired).
emptyTypeDefs :: TypeDefs
emptyTypeDefs = TypeDefs Map.empty Map.empty Map.empty

-- | Compile a source file through the full pipeline.
compileText :: FilePath -> Text -> Either CompileError CompileResult
compileText fp src = do
    -- Phase 1: Parse
    ast <- case parseModule fp src of
        Left  e -> Left (ParseError (T.pack (show e)))
        Right a -> Right a
    -- Phase 2: Typecheck (also collects TypeDefs)
    ((), typeDefs) <- case runCheckWithDefs emptyTypeDefs (checkModule ast) of
        Left  errs -> Left (TypeError errs)
        Right r    -> Right r
    -- Phase 3: Lower (AST → IR)
    program <- case lowerModule typeDefs ast of
        Left  errs -> Left (LowerError errs)
        Right p    -> Right p
    -- Phase 4: Emit (IR → Text)
    Right (CompileResult (emitToText program))
