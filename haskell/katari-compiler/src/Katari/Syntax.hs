module Katari.Syntax where

import Data.Text (Text)

-- ---------------------------------------------------------------------------
-- Source location
-- ---------------------------------------------------------------------------

data SrcSpan = SrcSpan
  { ssFile :: FilePath,
    ssLine :: Int,
    ssCol :: Int
  }
  deriving (Show, Eq)

noSpan :: SrcSpan
noSpan = SrcSpan "<unknown>" 0 0

-- ---------------------------------------------------------------------------
-- Top-level module
-- ---------------------------------------------------------------------------

data Module = Module
  { modFile :: FilePath,
    modName :: Text, -- e.g. "lib.cron" (dot-separated qualified name)
    modDecls :: [Decl]
  }
  deriving (Show)

-- ---------------------------------------------------------------------------
-- Declarations
-- ---------------------------------------------------------------------------

data Decl
  = DeclVal SrcSpan ValDecl
  | DeclAgent SrcSpan AgentDecl
  | DeclRequest SrcSpan RequestDecl
  | DeclType SrcSpan TypeAliasDecl
  | DeclImport SrcSpan ImportDecl
  | DeclExtAgent SrcSpan ExternalAgentDecl
  | DeclExtReq SrcSpan ExternalReqDecl
  deriving (Show)

-- val name: Type = expr
data ValDecl = ValDecl
  { valAnnot :: Maybe Text,
    valName :: Text,
    valType :: Type,
    valExpr :: Expr
  }
  deriving (Show)

-- agent name(params) -> RetType with Effect { body }
data AgentDecl = AgentDecl
  { agentAnnot :: Maybe Text,
    agentName :: Text,
    agentParams :: [(Text, Type, Maybe Text)], -- (name, type, annotation)
    agentRet :: Maybe Type,
    agentWith :: Maybe RequestEffect, -- Nothing = 推論
    agentBody :: Block
  }
  deriving (Show)

-- request name(params) -> RetType
data RequestDecl = RequestDecl
  { reqAnnot :: Maybe Text,
    reqName :: Text,
    reqParams :: [(Text, Type, Maybe Text)], -- (name, type, annotation)
    reqRet :: Type
  }
  deriving (Show)

-- type Name = Type
data TypeAliasDecl = TypeAliasDecl
  { tyaName :: Text,
    tyaType :: Type
  }
  deriving (Show)

-- import path [as alias] [{ names }]
data ImportDecl = ImportDecl
  { impPath :: [Text], -- ["lib", "cron"]
    impAlias :: Maybe Text, -- as alias
    impNames :: Maybe [Text] -- { name1, name2 }
  }
  deriving (Show)

-- external agent name(...) -> T from "server:agent"
data ExternalAgentDecl = ExternalAgentDecl
  { extAgentAnnot :: Maybe Text,
    extAgentName :: Text,
    extAgentParams :: [(Text, Type, Maybe Text)],
    extAgentRet :: Maybe Type,
    extAgentWith :: Maybe RequestEffect,
    extAgentFrom :: Text -- "server:agent_name"
  }
  deriving (Show)

-- external request name(...) -> T from "server:req"
data ExternalReqDecl = ExternalReqDecl
  { extReqAnnot :: Maybe Text,
    extReqName :: Text,
    extReqParams :: [(Text, Type, Maybe Text)],
    extReqRet :: Type,
    extReqFrom :: Text
  }
  deriving (Show)

-- with 節
data RequestEffect
  = RENames [Text] -- with req1 | req2 | ...
  | REAgent -- with agent
  deriving (Show, Eq)

-- ---------------------------------------------------------------------------
-- Statements
-- ---------------------------------------------------------------------------

newtype Block = Block [Stmt]
  deriving (Show)

data Stmt
  = SLet SrcSpan Pat Expr
  | SHandle SrcSpan HandleStmt
  | SExpr SrcSpan Expr
  | SReturn SrcSpan Expr
  | SContinue SrcSpan Expr (Maybe [(Text, Expr)]) -- continue val [with {x=e}]
  | SForContinue SrcSpan (Maybe [(Text, Expr)]) -- continue [with {x=e}] (for loop)
  | SBreak SrcSpan Expr -- break val (handle用)
  | SForBreak SrcSpan Expr -- break val (for用)
  deriving (Show)

-- ---------------------------------------------------------------------------
-- Expressions
-- ---------------------------------------------------------------------------

data Expr
  = EIf SrcSpan Expr Block Block
  | EMatch SrcSpan Expr [CaseArm]
  | EFor SrcSpan ForExpr
  | EPar SrcSpan [Block]
  | EBlock SrcSpan Block
  | EBinOp SrcSpan BinOp Expr Expr
  | EUnOp SrcSpan UnOp Expr
  | ECall SrcSpan Expr [Expr]
  | EField SrcSpan Expr Text
  | EVar SrcSpan Text
  | ELit SrcSpan Lit
  | EObj SrcSpan [(Text, Expr)] -- {foo = expr, ...}
  | EArr SrcSpan [Expr]
  | ETempl SrcSpan [TemplElem] -- f"..."
  deriving (Show)

data CaseArm = CaseArm
  { caPat :: Pat,
    caBody :: Block
  }
  deriving (Show)

data TemplElem
  = TemplStr Text
  | TemplExpr Expr
  deriving (Show)

-- ---------------------------------------------------------------------------
-- Handle
-- ---------------------------------------------------------------------------

data HandleStmt = HandleStmt
  { hParams :: [(Text, Type, Maybe Text, Expr)], -- (name, type, annotation, init_expr)
    hReqCases :: [(Text, [Pat], Block)], -- (req_name, arg_pats, body)
    hThenClause :: Maybe (Text, Block) -- then (var) { body }
  }
  deriving (Show)

-- ---------------------------------------------------------------------------
-- For
-- ---------------------------------------------------------------------------

data ForExpr = ForExpr
  { fLetBinds :: [(Text, Expr)], -- let x of array_expr
    fVarBinds :: [(Text, Type, Expr)], -- var acc: T = init
    fBody :: Block,
    fThen :: Maybe Block
  }
  deriving (Show)

-- ---------------------------------------------------------------------------
-- Patterns
-- ---------------------------------------------------------------------------

data Pat
  = PVar Text -- x
  | PTyped Text Type -- x: T
  | PLit Lit -- null, true, 42, "foo"
  | PTag PrimTag Text -- integer(x), boolean(x), ...
  | PObj [(Text, Bool, Pat)] -- {foo = p, ...} (Bool = uniq)
  | PArr [Pat] -- [p1, p2, ...]
  deriving (Show)

data PrimTag = TagBoolean | TagInteger | TagNumber | TagString
  deriving (Show, Eq)

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

data Type
  = TNull
  | TBoolean
  | TInteger
  | TNumber
  | TString
  | TNever
  | TUnknown
  | TLitBool Bool
  | TLitInt Integer
  | TLitNum Double
  | TLitStr Text
  | TArray Type
  | TObj [ObjField]
  | TUnion [Type]
  | TInter [Type]
  | TAlias Text
  deriving (Show, Eq)

data ObjField = ObjField
  { ofName :: Text,
    ofOptional :: Bool,
    ofUniq :: Bool,
    ofType :: Type,
    ofAnnot :: Maybe Text -- semantic annotation @"..." for schema description
  }
  deriving (Show, Eq)

-- ---------------------------------------------------------------------------
-- Literals
-- ---------------------------------------------------------------------------

data Lit
  = LNull
  | LBool Bool
  | LInt Integer
  | LNum Double
  | LStr Text
  deriving (Show, Eq)

-- ---------------------------------------------------------------------------
-- Operators
-- ---------------------------------------------------------------------------

data BinOp
  = OpAdd
  | OpSub
  | OpMul
  | OpDiv
  | OpConcat
  | OpLt
  | OpLe
  | OpGt
  | OpGe
  | OpEq
  | OpNe
  | OpAnd
  | OpOr
  deriving (Show, Eq)

data UnOp
  = UnNeg -- -
  | UnNot -- !
  deriving (Show, Eq)
