// TypeScript mirror of Katari.IR (Haskell).
//
// Canonical definitions now live in `@katari-lang/types`. This module
// re-exports everything so that internal runtime imports (`../ir/types.js`)
// and external consumers (`@katari-lang/runtime`) continue to work
// without modification.

export type {
  AgentBlock,
  ApplyGenericsData,
  BindPatternData,
  Block,
  BlockId,
  CallData,
  ContData,
  ContKind,
  DelegateBlock,
  DelegateTarget,
  ExitData,
  ExitKind,
  ExternalDispatch,
  ForBlock,
  GetFieldBlock,
  HandleBlock,
  Handler,
  IRMetadata,
  IRModule,
  LiteralValue,
  LoadLiteralData,
  MakeClosureData,
  MatchArm,
  MatchBlock,
  MatchPattern,
  NameTable,
  QualifiedName,
  RecordBlock,
  Statement,
  TupleBlock,
  TypePatternTag,
  UserBlock,
  VarId,
} from "@katari-lang/types";
export {
  joinQualifiedName,
  splitQualifiedName,
} from "@katari-lang/types";
