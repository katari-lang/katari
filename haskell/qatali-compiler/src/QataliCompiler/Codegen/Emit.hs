{- | Code generation: Qatali IR → output text or binary.

Supports two output formats:
  * 'FormatText'   — human-readable pretty-printed IR (for debugging)
  * 'FormatBinary' — compact binary bytecode for the runtime
-}
module QataliCompiler.Codegen.Emit (
    EmitConfig (..),
    OutputFormat (..),
    emit,
    emitToText,
) where

import qualified Data.ByteString.Lazy       as BL
import           Data.Text                  (Text)
import           Prettyprinter              (defaultLayoutOptions, layoutPretty)
import           Prettyprinter.Render.Text  (renderStrict)

import           QataliCompiler.IR.Binary   (encodeProgram)
import           QataliCompiler.IR.Module   (Program)
import           QataliCompiler.IR.Pretty   (prettyProgram)

-- | Output format for code generation.
data OutputFormat
    = -- | Human-readable IR text (for debugging)
      FormatText
    | -- | Binary bytecode for qatali-runtime
      FormatBinary
    deriving (Eq, Show)

-- | Configuration for the emit phase.
newtype EmitConfig = EmitConfig
    { format :: OutputFormat
    }
    deriving (Eq, Show)

-- | Emit a program to human-readable text.
emitToText :: Program -> Text
emitToText p = renderStrict (layoutPretty defaultLayoutOptions (prettyProgram p))

-- | Emit a program according to the given config.
data EmitResult
    = EmitText   !Text
    | EmitBinary !BL.ByteString

emit :: EmitConfig -> Program -> Either Text EmitResult
emit cfg p = case cfg.format of
    FormatText   -> Right (EmitText (emitToText p))
    FormatBinary -> Right (EmitBinary (encodeProgram p))
