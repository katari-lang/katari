module Katari.Data.AST where

type data NameRefKind where
  VariableRef :: NameRefKind
  TypeRef :: NameRefKind
  ModuleRef :: NameRefKind
  LabelRef :: NameRefKind

type data Phase where
  Parsed :: Phase
  Identified :: Phase
  Zonked :: Phase
