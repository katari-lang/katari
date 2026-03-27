{- | Code generation: Qatali IR → output text (or binary).

Currently targets a human-readable text format of the IR.
Future backends may emit binary bytecode or other formats.
-}
module QataliCompiler.Codegen.Emit (
    EmitConfig (..),
    OutputFormat (..),
    emit,
    emitToText,
) where

import           Data.Text                 (Text)
import           Prettyprinter             (defaultLayoutOptions, layoutPretty)
import           Prettyprinter.Render.Text (renderStrict)

import           QataliCompiler.IR.IR      (IRModule)
import           QataliCompiler.IR.Pretty  (prettyModule)

-- | Output format for code generation.
data OutputFormat
    = -- | Human-readable IR text (for debugging)
      FormatText
    | -- | TODO: binary bytecode for qatali-runtime
      FormatBinary
    deriving (Eq, Show)

-- | Configuration for the emit phase.
data EmitConfig = EmitConfig
    { format :: !OutputFormat
    }
    deriving (Eq, Show)

-- | Emit an IR module to text.
emitToText :: IRModule -> Text
emitToText m = renderStrict (layoutPretty defaultLayoutOptions (prettyModule m))

{- | Emit an IR module according to the given config.
TODO: implement binary emission
-}
emit :: EmitConfig -> IRModule -> Either Text Text
emit cfg m = case cfg.format of
    FormatText   -> Right (emitToText m)
    FormatBinary -> Left "TODO: binary emission not yet implemented"
