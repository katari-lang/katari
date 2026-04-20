module Katari.IR where

import Data.Map.Strict (Map)
import Data.Text (Text)
import Data.Word (Word32)

-- ---------------------------------------------------------------------------
-- Identifiers
-- ---------------------------------------------------------------------------

type VarId = Word32

type AgentId = Word32

type RequestId = Word32

type ConstId = Word32

type HandlerId = Word32

type ForId = Word32

type ThreadId = Word32

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
  | IComplete VarId -- thread 正常完了 (Normal signal)
  | IReturn VarId -- ソースの return 文 (FnReturn signal → FN_BODY まで巻き上げ)
  | -- Agent 操作
    ICall VarId AgentId [(Text, VarId)]
  | IPar VarId [ThreadId]
  | IRequest VarId RequestId [(Text, VarId)]
  | -- Handle
    IHandle VarId HandlerId -- dst, handle_def_id
  | IContinue VarId [(VarId, VarId)] -- val, [(state_var, new_val_var)]
  | IHandleBreak VarId -- HandleBreak signal
  | -- For
    IFor VarId ForId -- dst, for_def_id
  | IForContinue [(VarId, VarId)] -- [(state_var, new_val_var)]
  | IForBreak VarId -- ForBreak signal
  deriving (Show, Eq)

-- ---------------------------------------------------------------------------
-- Thread
-- ---------------------------------------------------------------------------

data ThreadKind
  = TkFnBody -- agent エントリポイント
  | TkBlock -- par branch / block 式
  | TkHandlerTarget -- handle body (残り文)
  | TkRequestHandler -- request case handler
  | TkHandleThen -- handle then 節
  | TkForBody -- for loop body
  | TkForThen -- for then 節
  deriving (Show, Eq)

data IRThread = IRThread
  { itId :: ThreadId,
    itKind :: ThreadKind,
    itParams :: [VarId],
    itBody :: [Instruction]
  }
  deriving (Show)

-- ---------------------------------------------------------------------------
-- Handle definition
-- ---------------------------------------------------------------------------

data IRHandleDef = IRHandleDef
  { ihdId :: HandlerId,
    ihdStateVars :: [VarId], -- state variable VarIds
    ihdStateInits :: [VarId], -- vars holding initial values
    ihdBody :: ThreadId, -- HANDLER_TARGET thread
    ihdReqCases :: [(RequestId, ThreadId)], -- (req_id, REQUEST_HANDLER thread)
    ihdThen :: Maybe ThreadId -- HANDLE_THEN thread
  }
  deriving (Show)

-- ---------------------------------------------------------------------------
-- For definition
-- ---------------------------------------------------------------------------

data IRForDef = IRForDef
  { ifdId :: ForId,
    ifdIterVars :: [VarId], -- element vars (let x of arr)
    ifdArrays :: [VarId], -- array vars
    ifdStateVars :: [VarId], -- state variable VarIds
    ifdStateInits :: [VarId], -- vars holding initial values
    ifdBody :: ThreadId, -- FOR_BODY thread
    ifdThen :: Maybe ThreadId -- FOR_THEN thread
  }
  deriving (Show)

-- ---------------------------------------------------------------------------
-- Agent definition
-- ---------------------------------------------------------------------------

data IRAgentDef = IRAgentDef
  { iadId :: AgentId,
    iadName :: Text,
    iadEntry :: ThreadId, -- FN_BODY thread
    iadParamNames :: [Text] -- parameter names in declaration order
  }
  deriving (Show)

-- ---------------------------------------------------------------------------
-- Request definition
-- ---------------------------------------------------------------------------

data IRRequestDef = IRRequestDef
  { irReqId :: RequestId,
    irReqName :: Text,
    irReqFrom :: Maybe Text, -- external の場合 "server:name"
    irReqParamNames :: [Text] -- parameter names in declaration order
  }
  deriving (Show)

-- ---------------------------------------------------------------------------
-- Name table
-- ---------------------------------------------------------------------------

data NameTable = NameTable
  { ntVars :: Map VarId Text,
    ntAgents :: Map AgentId Text,
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
    irmThreads :: [IRThread],
    irmHandles :: [IRHandleDef],
    irmFors :: [IRForDef],
    irmAgents :: [IRAgentDef]
  }
  deriving (Show)
