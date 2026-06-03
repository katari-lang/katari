// @katari-lang/types — shared type definitions.
//
// This package contains pure type definitions (+ minimal helper
// functions) shared across the Katari TypeScript ecosystem. It has zero
// runtime dependencies so that lightweight consumers like `katari-port`
// can depend on just this package instead of the full runtime.

export type {
  AgentBlock,
  Arg,
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
  Param,
  QualifiedName,
  RecordBlock,
  Statement,
  TupleBlock,
  TypePatternTag,
  UserBlock,
  VarId,
} from "./ir.js";
export {
  joinQualifiedName,
  splitQualifiedName,
} from "./ir.js";
export type { Json } from "./json.js";
export type { RawValue } from "./raw-value.js";

export type {
  AgentDefinition,
  JsonSchema,
  SchemaBundle,
} from "./schema.js";

export type { SidecarBundle } from "./sidecar.js";
