// @katari-lang/types — shared type definitions.
//
// This package contains pure type definitions (+ minimal helper
// functions) shared across the Katari TypeScript ecosystem. It has zero
// runtime dependencies so that lightweight consumers like `katari-port`
// can depend on just this package instead of the full runtime.

export type { Json } from "./json.js";

export type { RawValue } from "./raw-value.js";

export {
  splitQualifiedName,
  joinQualifiedName,
} from "./ir.js";
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
} from "./ir.js";

export type {
  JsonSchema,
  AgentDefinition,
  SchemaBundle,
} from "./schema.js";

export type { SidecarBundle } from "./sidecar.js";
