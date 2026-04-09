module Katari.IR where

import Data.Map.Strict (Map)
import Data.Text (Text)
import Data.Word (Word32)

-- ---------------------------------------------------------------------------
-- Identifiers
-- ---------------------------------------------------------------------------

type VarId = Word32

type TaskId = Word32

type RequestId = Word32

type ConstId = Word32

type HandlerId = Word32

-- ---------------------------------------------------------------------------
-- Constant pool values
-- ---------------------------------------------------------------------------

data ConstVal
  = CVNull
  | CVBool Bool
  | CVInt Integer
  | CVNum Double
  | CVStr Text
  deriving (Show, Eq)

-- ---------------------------------------------------------------------------
-- Instructions
-- ---------------------------------------------------------------------------

data Instruction
  = -- 定数・移動
    ILoadConst VarId ConstId
  | ILoadNull VarId
  | IMove VarId VarId
  | -- Object
    INewObject VarId [(ConstId, VarId)]
  | IGetField VarId VarId ConstId
  | ISetField VarId VarId ConstId VarId
  | IHasField VarId VarId ConstId
  | -- Array
    INewArray VarId [VarId]
  | IArrGet VarId VarId VarId
  | IArrLen VarId VarId
  | IArrPush VarId VarId VarId
  | IArrSlice VarId VarId VarId VarId
  | -- 算術演算 (動的型判定: ランタイムが integer/number を判定する)
    IAdd VarId VarId VarId
  | ISub VarId VarId VarId
  | IMul VarId VarId VarId
  | IDiv VarId VarId VarId
  | IMod VarId VarId VarId
  | INeg VarId VarId
  | -- 比較
    ICmpEq VarId VarId VarId
  | ICmpNe VarId VarId VarId
  | ICmpLt VarId VarId VarId
  | ICmpLe VarId VarId VarId
  | ICmpGt VarId VarId VarId
  | ICmpGe VarId VarId VarId
  | -- 論理
    IAnd VarId VarId VarId
  | IOr VarId VarId VarId
  | INot VarId VarId
  | -- 文字列/配列結合 (ランタイムが lhs の型で分岐)
    IConcat VarId VarId VarId
  | -- 型変換
    IToString VarId VarId
  | ITypeOf VarId VarId
  | -- 制御フロー
    IJump Word32
  | IBranch VarId Word32 Word32
  | ISwitch VarId [(ConstId, Word32)] Word32
  | IReturn VarId
  | -- Agent 操作
    ICall VarId TaskId [VarId]
  | IPar VarId [(TaskId, [VarId])]
  | IRequest VarId RequestId [VarId]
  | -- Handle ライフサイクル
    IHandleBegin HandlerId
  | IHandleEnd VarId VarId HandlerId -- dst, scope_result, handler
  -- Handler 内命令
  | IReply VarId HandlerId [(Word32, VarId)] -- val, handler, state_updates
  | IBreak VarId HandlerId
  | -- For ループ内命令
    INext [(Word32, VarId)]
  | IForBreak VarId
  deriving (Show, Eq)

-- ---------------------------------------------------------------------------
-- Handle block
-- ---------------------------------------------------------------------------

data IRHandleBlock = IRHandleBlock
  { irhId :: HandlerId,
    irhStateVars :: [VarId], -- 状態変数 VarId リスト
    irhReqCases :: [(RequestId, [VarId], [Instruction])], -- (req, arg_vars, instructions)
    irhReturnCase :: Maybe (VarId, [Instruction]) -- (input_var, return 節命令列)
  }
  deriving (Show)

-- ---------------------------------------------------------------------------
-- Task
-- ---------------------------------------------------------------------------

data IRTask = IRTask
  { irTaskId :: TaskId,
    irTaskName :: Text, -- デバッグ用
    irTaskParams :: [VarId],
    irTaskBody :: [Instruction],
    irTaskHandlers :: [IRHandleBlock]
  }
  deriving (Show)

-- ---------------------------------------------------------------------------
-- Request definition
-- ---------------------------------------------------------------------------

data IRRequestDef = IRRequestDef
  { irReqId :: RequestId,
    irReqName :: Text,
    irReqFrom :: Maybe Text -- external の場合 "server:name"
  }
  deriving (Show)

-- ---------------------------------------------------------------------------
-- Name table
-- ---------------------------------------------------------------------------

data NameTable = NameTable
  { ntVars :: Map VarId Text,
    ntTasks :: Map TaskId Text,
    ntRequests :: Map RequestId Text
  }
  deriving (Show)

emptyNameTable :: NameTable
emptyNameTable = NameTable mempty mempty mempty

-- ---------------------------------------------------------------------------
-- Module
-- ---------------------------------------------------------------------------

data IRModule = IRModule
  { irmName :: Text,
    irmNameTable :: NameTable,
    irmConsts :: [ConstVal],
    irmRequests :: [IRRequestDef],
    irmTasks :: [IRTask]
  }
  deriving (Show)
