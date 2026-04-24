-- | Typechecker phase 1:
-- Attach unique identifiers to each definition and reference in the AST.
-- Input  : Parsed AST * n (with module name)
-- Output : AST carrying @Identified@ metadata on every @NameRef@, plus a
--          mapping from unique identifiers to their source name / position /
--          origin.
--
-- このフェーズではもっぱら名前解決と、そのスコープチェックを行う。
--
--   1. 値空間の名前参照 (variable-ref) : agent 定義、ローカル変数、ローカル
--      agent 定義、constructor、req、ext agent はすべて @VariableId@ を持つ。
--   2. 型空間の名前参照 (type-ref)     : enum 定義自体、および TypeName /
--      QualifiedTypeNode の型コンストラクタ名。
--   3. モジュール空間の名前参照 (module-ref) : import の alias、および値・型の
--      qualified 参照の左辺。
module Katari.Typechecker.Identifier where

import Control.Monad (foldM)
import Control.Monad.Except (Except)
import Control.Monad.Reader (ReaderT)
import Control.Monad.State.Strict
import Control.Monad.Trans.Except
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Text
import GHC.TypeLits (Symbol)
import Katari.AST (Module, SourceSpan)
import Katari.Parser (Parsed)

-- | 値空間の一意 id。ローカル変数、agent / ext agent、req、constructor 等を
-- すべてこの空間で番号付けする。
newtype VariableId = VariableId Int
  deriving (Eq, Ord, Show)

-- | 型空間の一意 id。enum 宣言が持つ。
newtype TypeId = TypeId Int
  deriving (Eq, Ord, Show)

-- | モジュール空間の一意 id。import された（あるいは alias された）モジュールが
-- 持つ。
newtype ModuleId = ModuleId Int
  deriving (Eq, Ord, Show)

-- | Identifier pass 後の AST が運ぶ metadata。
--
-- @NameRef@ の @symbol@ が 3 種 (variable-ref / type-ref / module-ref) で
-- それぞれに一意 id を付与する。Expression / Pattern の @symbol@ には識別子
-- レベルの情報は載せず、後段 Typechecker の型付けフェーズで置き換えられる
-- ことを想定した空のマーカーを用意する。
data Identified (symbol :: Symbol) where
  IdentifiedVariable :: VariableId -> Identified "variable-ref"
  IdentifiedType :: TypeId -> Identified "type-ref"
  IdentifiedModule :: ModuleId -> Identified "module-ref"
  IdentifiedExpression :: Identified "expression"
  IdentifiedPattern :: Identified "pattern"
  -- | Argument / field labels cannot be resolved at Identifier-pass time
  -- because resolution requires the callee's / subject's type. Filled in by
  -- the Typechecker.
  IdentifiedLabel :: Identified "label-ref"

deriving instance Show (Identified symbol)

deriving instance Eq (Identified symbol)

data ModuleData = ModuleData
  { moduleName :: Text,
    -- | 0 ~ EOF of the module source
    moduleSourceSpan :: SourceSpan,
    moduleAST :: Module Identified
  }

data VariableData = VariableData
  { variableName :: Text,
    -- | Position of the variable definition (agent / ext agent / req / constructor / local variable / local agent ...)
    variableSourceSpan :: SourceSpan
  }

data TypeData = TypeData
  { typeName :: Text,
    -- | Position of the type definition (enum declaration)
    typeSourceSpan :: SourceSpan
  }

data IdentifierResult = IdentifierResult
  { identifiedModules :: Map ModuleId ModuleData,
    identifiedVariables :: Map VariableId VariableData,
    identifiedTypes :: Map TypeId TypeData
  }

-- | identify 関数
-- 入力は (module 名 |-> Module Parsed) の Map
identify :: Map Text (Module Parsed) -> Either String IdentifierResult
identify moduleMap = evalState (runExceptT go) initialIdentifierState
  where
    go = do
      identifiedModules <- idntifyModules moduleMap
      undefined
    initialIdentifierState =
      IdentifierState
        { nextId = 0
        }

newtype IdentifierState = IdentifierState
  { nextId :: Int
  }

type Identifier a = ExceptT String (State IdentifierState) a

newId :: Identifier Int
newId = do
  st <- get
  let currentId = st.nextId
  modify (\IdentifierState {nextId} -> IdentifierState {nextId = nextId + 1})
  return currentId

idntifyModules :: Map Text (Module Parsed) -> Identifier (Map ModuleId (Module Identified))
idntifyModules moduleMap = do
  -- Assign ModuleId to each module
  moduleIdMap <-
    foldM
      ( \acc moduleName -> do
          moduleId <- ModuleId <$> newId
          return (Map.insert moduleName moduleId acc)
      )
      Map.empty
      (Map.keys moduleMap)
  undefined