// TypeScript mirror of Katari.IR (Haskell).
//
// Canonical definitions now live in `@katari-lang/types`. This module
// re-exports everything so that internal runtime imports (`../ir/types.js`)
// and external consumers (`@katari-lang/runtime`) continue to work
// without modification.

export {
  splitQualifiedName,
  joinQualifiedName,
} from "@katari-lang/types";

export type {
  BlockId,
  VarId,
  QualifiedName,
  IRMetadata,
  IRModule,
  NameTable,
  ExitKind,
  ContKind,
  Param,
  Handler,
  UserBlock,
  AgentBlock,
  Block,
  DelegateBlock,
  DelegateTarget,
  ExternalDispatch,
  Arg,
  LiteralValue,
  MatchPattern,
  TypePatternTag,
  MatchArm,
  CallData,
  MakeClosureData,
  LoadLiteralData,
  MatchBlock,
  ForBlock,
  HandleBlock,
  TupleBlock,
  ArrayBlock,
  RecordBlock,
  ExitData,
  ContData,
  BindPatternData,
  Statement,
} from "@katari-lang/types";
