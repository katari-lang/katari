{- | Top-level API for the Qatali compiler.

Compilation pipeline:

> Source Text
>   → (Parse)     → AST SrcSpan
>   → (Typecheck) → diagnostics
>   → (Lower)     → IRModule       (TODO Phase 7)
>   → (Emit)      → Text / Binary  (TODO Phase 7)
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

import qualified Data.Map.Strict               as Map
import           Data.Text                     (Text)
import qualified Data.Text                     as T

import           QataliCompiler.Diagnostic
import           QataliCompiler.Name
import           QataliCompiler.Parse.Parser   (parseModule)
import           QataliCompiler.SrcLoc
import           QataliCompiler.Type.Normalize (TypeDefs (..))
import           QataliCompiler.Typecheck.Check (checkModule, runCheck)

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

{- | Compile a source file.

Currently runs parse + typecheck; lowering and emit are TODO.
-}
compileText :: FilePath -> Text -> Either CompileError CompileResult
compileText fp src = do
    -- Phase 1: Parse
    ast <- case parseModule fp src of
        Left  e -> Left (ParseError (T.pack (show e)))
        Right a -> Right a
    -- Phase 2: Typecheck
    case runCheck emptyTypeDefs (checkModule ast) of
        Left  errs -> Left (TypeError errs)
        Right ()   -> pure ()
    -- TODO Phase 7: Lower → Emit
    Left (EmitError "TODO: lowering/emit not yet connected")
