module Katari.AST where

import GHC.Base (Symbol, Type)

data Position = Position
  { line :: Int,
    column :: Int
  }

data SourceSpan = SrcSpan
  { filePath :: FilePath,
    startPosition :: Position,
    endPosistion :: Position
  }

newtype Module (metadata :: Symbol -> Type) = Module
  { declarations :: (metadata "module") [Declaration metadata],
    sourceSpan :: SourceSpan
  }

data Declaration (metadata :: Symbol -> Type)
  = DeclarationVal (ValDeclaration metadata)
  | DeclarationAgent (AgentDeclaration metadata)
  | DeclarationRequest (RequestDeclaration metadata)
  | DeclarationType (TypeAliasDeclaration metadata)
  | DeclarationImport (ImportDeclaration metadata)
  | DeclarationExternalAgent (ExternalAgentDeclaration metadata)
  | Declaration
