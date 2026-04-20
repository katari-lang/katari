-- | Public API re-exports
module Katari
  ( module Katari.Syntax,
    module Katari.IR,
    module Katari.Types,
    module Katari.Module,
    module Katari.Typechecker,
    module Katari.Lowering,
    module Katari.Emit,
    module Katari.Lexer,
    module Katari.Parser,
  )
where

import Katari.Emit
import Katari.IR
import Katari.Lexer
import Katari.Lowering
import Katari.Module
import Katari.Parser
import Katari.Syntax
import Katari.Typechecker
import Katari.Types
