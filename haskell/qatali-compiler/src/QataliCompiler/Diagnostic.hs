module QataliCompiler.Diagnostic (
    Severity (..),
    Diagnostic (..),
    DiagnosticCode (..),
    mkError,
    mkWarning,
    mkNote,
) where

import           Data.Text             (Text)
import           QataliCompiler.SrcLoc (SrcSpan)

data Severity = SevError | SevWarning | SevNote
    deriving (Eq, Ord, Show)

-- | A numbered diagnostic code for structured error reporting.
newtype DiagnosticCode = DiagnosticCode {codeNum :: Int}
    deriving (Eq, Ord, Show)

data Diagnostic = Diagnostic
    { severity :: !Severity
    , code     :: !(Maybe DiagnosticCode)
    , span     :: !SrcSpan
    , message  :: !Text
    , notes    :: ![Text]
    }
    deriving (Eq, Show)

mkError :: SrcSpan -> Text -> Diagnostic
mkError sp msg = Diagnostic SevError Nothing sp msg []

mkWarning :: SrcSpan -> Text -> Diagnostic
mkWarning sp msg = Diagnostic SevWarning Nothing sp msg []

mkNote :: SrcSpan -> Text -> Diagnostic
mkNote sp msg = Diagnostic SevNote Nothing sp msg []
