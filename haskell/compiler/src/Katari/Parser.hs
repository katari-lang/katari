-- | The Parse phase: source text to a 'Parsed' AST (lexer + parser). This module defines only the
-- phase's I/O; the lexer and parser are not yet implemented.
module Katari.Parser where

import Data.Text (Text)
import Katari.Data.AST (Module, Phase (Parsed))
import Katari.Data.ModuleName (ModuleName)
import Katari.Diagnostics (Diagnostics)

-- | Parse one module's source into a 'Parsed' AST, with the parse diagnostics (K1xxx range).
--
-- TODO: lexer + parser not yet implemented.
parseModule :: ModuleName -> Text -> (Module Parsed, Diagnostics)
parseModule _moduleName _source = error "Katari.Parser.parseModule: not yet implemented"
