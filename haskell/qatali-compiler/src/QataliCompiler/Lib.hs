{- | Top-level API for the Qatali compiler.

Compilation pipeline:

> Source Text
>   → (Parse)     → AST SrcSpan
>   → (Typecheck) → diagnostics + TypeDefs
>   → (Lower)     → IR Program
>   → (Emit)      → Text / Binary
-}
module QataliCompiler.Lib (
    -- * Single-file pipeline
    compileText,
    CompileResult (..),
    CompileError (..),

    -- * Multi-module pipeline
    compileModules,
    ModuleInput (..),

    -- * Re-exports for convenience
    module QataliCompiler.SrcLoc,
    module QataliCompiler.Name,
    module QataliCompiler.Diagnostic,
) where

import           Data.List.NonEmpty               (NonEmpty (..))
import           Data.Text                       (Text)
import qualified Data.Text                       as T

import           QataliCompiler.Codegen.Emit     (emitToText)
import           QataliCompiler.Compile.Lower    (lowerModule)
import           QataliCompiler.Diagnostic
import           QataliCompiler.Name
import           QataliCompiler.Parse.Parser     (parseModule)
import           QataliCompiler.SrcLoc
import           QataliCompiler.Type.Defs        (ModuleInterface (..),
                                                   emptyModuleInterface,
                                                   mergeTypeDefs)
import           QataliCompiler.Typecheck.Check  (checkModule,
                                                   runCheckWithDefs,
                                                   runCheckWithInterfaces)
import           QataliCompiler.Typecheck.Prim  (primInterfaces,
                                                   primTypeDefs)

-- | Errors that can occur during compilation.
data CompileError
    = ParseError  !Text
    | TypeError   ![Diagnostic]
    | LowerError  ![Diagnostic]
    | EmitError   !Text
    deriving (Show)

-- | The result of a successful compilation.
data CompileResult = CompileResult
    { crOutput    :: !Text
    , crInterface :: !ModuleInterface  -- ^ exported interface for downstream modules
    }
    deriving (Show)

-- | Input for one module in a multi-module compilation.
data ModuleInput = ModuleInput
    { miInputModuleName :: !ModuleName
    , miFilePath        :: !FilePath
    , miSource          :: !Text
    }

-- | Compile a single source file through the full pipeline.
compileText :: FilePath -> Text -> Either CompileError CompileResult
compileText fp src = do
    ast <- case parseModule fp src of
        Left  e -> Left (ParseError (T.pack (show e)))
        Right a -> Right a
    ((), typeDefs, resolvedImpls) <- case runCheckWithDefs primTypeDefs (checkModule ast) of
        Left  errs -> Left (TypeError errs)
        Right r    -> Right r
    program <- case lowerModule typeDefs resolvedImpls ast of
        Left  errs -> Left (LowerError errs)
        Right p    -> Right p
    -- Build a stub module interface (no module name available in single-file mode)
    let stubName = ModuleName ("_main" :| [])
        iface    = emptyModuleInterface stubName
    Right (CompileResult (emitToText program) iface)

-- | Compile multiple modules in dependency order.
-- Each module may reference interfaces from previously compiled modules.
compileModules :: [ModuleInput] -> Either CompileError [CompileResult]
compileModules inputs = go [] inputs
  where
    go acc [] = Right (reverse acc)
    go acc (ModuleInput mn fp src : rest) = do
        ast <- case parseModule fp src of
            Left  e -> Left (ParseError (T.pack (show e)))
            Right a -> Right a
        -- Merge prim + previously compiled interfaces into a single TypeDefs
        let prevIfaces   = primInterfaces ++ map crInterface acc
            mergedDefs   = foldr (mergeTypeDefs . miTypeDefs) primTypeDefs prevIfaces
        ((), iface, typeDefs, resolvedImpls) <- case runCheckWithInterfaces mergedDefs prevIfaces mn (checkModule ast) of
            Left  errs -> Left (TypeError errs)
            Right r    -> Right r
        program <- case lowerModule typeDefs resolvedImpls ast of
            Left  errs -> Left (LowerError errs)
            Right p    -> Right p
        go (CompileResult (emitToText program) iface : acc) rest
