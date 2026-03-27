{- | Abstract Syntax Tree for the Qatali language.

The AST is parameterized by an annotation type @ann@, which carries
extra information attached to each node. Typical instantiations:

  * @ann ~ SrcSpan@   — after parsing (position info only)
  * @ann ~ TypeInfo@  — after type checking (position + type)
-}
module QataliCompiler.Syntax.AST (
    -- * Phase annotations
    TypeInfo (..),

    -- * Top-level
    Module (..),
    Decl (..),

    -- * Source-level type parameters
    SrcTypeParam (..),
    SrcBound (..),
    SrcDataTypeParam (..),
    SrcVariance (..),

    -- * Function helpers
    Param (..),
    LetTarget (..),
    FnBody (..),

    -- * Expressions
    Expr (..),
    Stmt (..),
    MatchArm (..),
    HandleCase (..),
    HandleReturn (..),
    TemplateSegment (..),
    BinOp (..),
    UnaryOp (..),

    -- * Tuple / Array elements (with spread)
    TupleElem (..),
    ArrayElem (..),

    -- * Patterns
    Pat (..),
    ObjectPat (..),
    SpreadPat (..),

    -- * Type expressions (source syntax)
    TyExpr (..),
) where

import           QataliCompiler.Name           (ModuleName, Name, QualifiedName)
import           QataliCompiler.SrcLoc         (SrcSpan)
import           QataliCompiler.Syntax.Literal (Literal)
import           QataliCompiler.Type.Type      (Type)

-- | Type annotation attached to every AST node after type checking.
data TypeInfo = TypeInfo
    { tiSpan :: !SrcSpan
    , tiType :: !Type
    }
    deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- Source-level type parameters

-- | A generic type parameter (for let/fn/type): name + optional bound.
data SrcTypeParam ann = SrcTypeParam
    { stpAnn   :: !ann
    , stpName  :: !Name
    , stpBound :: !(Maybe (SrcBound ann))
    }
    deriving (Eq, Show, Functor, Foldable, Traversable)

-- | A generic bound constraint.
data SrcBound ann
    = SrcBoundSub !ann !(TyExpr ann)   -- ^ @sub T@ (upper bound, T <: U)
    | SrcBoundSup !ann !(TyExpr ann)   -- ^ @sup T@ (lower bound, T :> U)
    | SrcBoundIs  !ann !(TyExpr ann)   -- ^ @is T@  (exact, T = U)
    deriving (Eq, Show, Functor, Foldable, Traversable)

-- | A data declaration's type parameter: variance + name + optional bound.
data SrcDataTypeParam ann = SrcDataTypeParam
    { sdtpAnn      :: !ann
    , sdtpVariance :: !SrcVariance
    , sdtpName     :: !Name
    , sdtpBound    :: !(Maybe (SrcBound ann))
    }
    deriving (Eq, Show, Functor, Foldable, Traversable)

-- | Variance annotation for data type parameters.
data SrcVariance = SrcOut | SrcIn | SrcInOut | SrcNone
    deriving (Eq, Ord, Show)

-- ---------------------------------------------------------------------------
-- Top-level

-- | A source module.
data Module ann = Module
    { modAnn   :: !ann
    , modName  :: !ModuleName
    , modDecls :: ![Decl ann]
    }
    deriving (Eq, Show, Functor, Foldable, Traversable)

-- | A top-level declaration.
data Decl ann
    = DeclLet !ann !(LetTarget ann) ![SrcTypeParam ann] !(Maybe (TyExpr ann)) !(Expr ann)
      -- ^ @let name\<T sub U\>: Type = expr@
    | DeclFn !ann !Name ![SrcTypeParam ann] ![Param ann] !(Maybe (TyExpr ann)) !(FnBody ann)
      -- ^ @fn name\<T\>(x: A, y: B): C => expr | block@
    | DeclType !ann !Name ![SrcTypeParam ann] !(TyExpr ann)
      -- ^ @type Name\<T\> = ...@
    | DeclData !ann !Name ![SrcDataTypeParam ann] ![(Name, TyExpr ann)]
      -- ^ @data Name\<out T sub U\>(field1: T1, field2: T2)@
    | DeclEffect !ann !Name ![SrcDataTypeParam ann] ![(Name, TyExpr ann)] !(TyExpr ann)
      -- ^ @effect Name\<out T\>(field: T) => RetTy@
    | DeclImport !ann !ModuleName !(Maybe Name) !(Maybe [Name])
      -- ^ @import Foo.Bar as F (item1, item2)@
    deriving (Eq, Show, Functor, Foldable, Traversable)

-- ---------------------------------------------------------------------------
-- Function helpers

-- | A let target: single variable or destructuring pattern.
data LetTarget ann
    = LetName !Name
    | LetPat  !(Pat ann)
    deriving (Eq, Show, Functor, Foldable, Traversable)

-- | A function parameter: name + type annotation.
data Param ann = Param
    { paramAnn  :: !ann
    , paramName :: !Name
    , paramType :: !(TyExpr ann)
    }
    deriving (Eq, Show, Functor, Foldable, Traversable)

-- | A function body: expression or block.
data FnBody ann
    = FnExpr  !(Expr ann)
    | FnBlock !ann ![Stmt ann]
    deriving (Eq, Show, Functor, Foldable, Traversable)

-- ---------------------------------------------------------------------------
-- Expressions

-- | Core expression type, parameterized by annotation @ann@.
data Expr ann
    = EVar         !ann !QualifiedName
      -- ^ Variable reference
    | ELit         !ann !Literal
      -- ^ Literal value
    | EApp         !ann !(Expr ann) ![TyExpr ann] ![Expr ann]
      -- ^ Function application @f\<T\>(arg1, arg2)@
    | EFn          !ann ![SrcTypeParam ann] ![Param ann] !(Maybe (TyExpr ann)) !(FnBody ann)
      -- ^ Anonymous function @fn \<T\>(x: A): B => expr | block@
    | EMatch       !ann !(Expr ann) ![MatchArm ann]
      -- ^ Pattern match @match expr { case pat => expr, ... }@
    | EIf          !ann !(Expr ann) !(Expr ann) !(Maybe (Expr ann))
      -- ^ Conditional @if cond then else@
    | EBlock       !ann ![Stmt ann]
      -- ^ Block expression @{ stmt; stmt; expr }@
    | EHandle      !ann !(Expr ann) ![HandleCase ann] !(Maybe (HandleReturn ann))
      -- ^ Effect handler @handle expr { case Eff(x) => ..., return x => ... }@
    | EObject      !ann !(Maybe (Expr ann)) ![(Name, Expr ann)]
      -- ^ Object literal @{ ...spread, a = 1, b = 2 }@
    | ETuple       !ann ![TupleElem ann]
      -- ^ Tuple literal @(a, ...t, b)@
    | EArray       !ann ![ArrayElem ann]
      -- ^ Array literal @[a, ...arr, b]@
    | EField       !ann !(Expr ann) !Name
      -- ^ Field access @expr.field@
    | EIndex       !ann !(Expr ann) !(Expr ann)
      -- ^ Indexing @expr[expr]@
    | EReturn      !ann !(Maybe (Expr ann))
      -- ^ Return @return expr@
    | ETemplateLit !ann ![TemplateSegment ann]
      -- ^ Template literal @`hello ${name}!`@
    | EBinOp       !ann !BinOp !(Expr ann) !(Expr ann)
      -- ^ Binary operation
    | EUnaryOp     !ann !UnaryOp !(Expr ann)
      -- ^ Unary operation
    deriving (Eq, Show, Functor, Foldable, Traversable)

-- | A template literal segment.
data TemplateSegment ann
    = TmplStr  !ann !Name
    | TmplExpr !(Expr ann)
    deriving (Eq, Show, Functor, Foldable, Traversable)

-- | A statement inside a block.
data Stmt ann
    = StmtExpr   !(Expr ann)
    | StmtLet    !ann !(LetTarget ann) !(Maybe (TyExpr ann)) !(Expr ann)
    | StmtReturn !ann !(Maybe (Expr ann))
    deriving (Eq, Show, Functor, Foldable, Traversable)

-- | A match arm: pattern → body.
data MatchArm ann = MatchArm
    { maAnn  :: !ann
    , maPat  :: !(Pat ann)
    , maBody :: !(Expr ann)
    }
    deriving (Eq, Show, Functor, Foldable, Traversable)

-- | A handler case for an effect.
data HandleCase ann = HandleCase
    { hcAnn    :: !ann
    , hcEffect :: !Name
    , hcParams :: ![Pat ann]
    , hcBody   :: !(Expr ann)
    }
    deriving (Eq, Show, Functor, Foldable, Traversable)

-- | A handler return clause.
data HandleReturn ann = HandleReturn
    { hrAnn   :: !ann
    , hrParam :: !Name
    , hrBody  :: !(Expr ann)
    }
    deriving (Eq, Show, Functor, Foldable, Traversable)

-- ---------------------------------------------------------------------------
-- Binary / Unary operators

-- | Binary operators.
data BinOp
    = OpAdd | OpSub | OpMul | OpDiv | OpMod
    | OpEq | OpNeq | OpLt | OpLe | OpGt | OpGe
    | OpAnd | OpOr
    | OpConcat   -- ^ @++@
    deriving (Eq, Ord, Show)

-- | Unary operators.
data UnaryOp = OpNeg | OpNot
    deriving (Eq, Ord, Show)

-- ---------------------------------------------------------------------------
-- Tuple / Array elements (with spread support)

-- | A tuple element: plain or spread.
data TupleElem ann
    = TElem   !(Expr ann)
    | TSpread !(Expr ann)
    deriving (Eq, Show, Functor, Foldable, Traversable)

-- | An array element: plain or spread.
data ArrayElem ann
    = AElem   !(Expr ann)
    | ASpread !(Expr ann)
    deriving (Eq, Show, Functor, Foldable, Traversable)

-- ---------------------------------------------------------------------------
-- Patterns

-- | A pattern for match/let destructuring.
data Pat ann
    = PVar    !ann !Name
      -- ^ Variable pattern
    | PLit    !ann !Literal
      -- ^ Literal pattern
    | PWild   !ann
      -- ^ Wildcard @_@
    | PCon    !ann !QualifiedName ![Pat ann]
      -- ^ Constructor pattern @Con(p1, p2)@
    | PObject !ann !(ObjectPat ann)
      -- ^ Object pattern @{a = p1, b = p2, ...rest}@
    | PTuple  !ann !(SpreadPat ann)
      -- ^ Tuple pattern @(p1, ...rest, p2)@
    | PArray  !ann !(SpreadPat ann)
      -- ^ Array pattern @[p1, ...rest, p2]@
    deriving (Eq, Show, Functor, Foldable, Traversable)

-- | Object pattern: named fields + optional rest spread (at end only).
data ObjectPat ann = ObjectPat
    { opFields :: ![(Name, Pat ann)]
    , opRest   :: !(Maybe (ann, Name))
    }
    deriving (Eq, Show, Functor, Foldable, Traversable)

-- | Spread pattern for tuples/arrays: at most one spread at any position.
data SpreadPat ann = SpreadPat
    { spBefore :: ![Pat ann]
    , spSpread :: !(Maybe (ann, Pat ann))
    , spAfter  :: ![Pat ann]
    }
    deriving (Eq, Show, Functor, Foldable, Traversable)

-- ---------------------------------------------------------------------------
-- Type expressions (source syntax)

-- | A type expression as written in source code.
data TyExpr ann
    = TyVar       !ann !Name
      -- ^ Type variable @a@
    | TyCon       !ann !QualifiedName
      -- ^ Type constructor @List@, @String@
    | TyApp       !ann !(TyExpr ann) ![TyExpr ann]
      -- ^ Type application @F\<A, B\>@
    | TyFun       !ann ![(Name, TyExpr ann)] !(TyExpr ann) !(Maybe (TyExpr ann))
      -- ^ Function type @(x: A, y: B) => C with Effect@
    | TyObject    !ann ![(Name, TyExpr ann)]
      -- ^ Object type @{a: T, b: U}@
    | TyTuple     !ann ![TyExpr ann]
      -- ^ Tuple type @(A, B, C)@
    | TyArray     !ann !(TyExpr ann)
      -- ^ Array type @Array\<T\>@
    | TyUnion     !ann !(TyExpr ann) !(TyExpr ann)
      -- ^ Union type @A | B@
    | TyIntersect !ann !(TyExpr ann) !(TyExpr ann)
      -- ^ Intersection type @A & B@
    | TyLit       !ann !Literal
      -- ^ Literal type @1@, @"hello"@, @true@
    deriving (Eq, Show, Functor, Foldable, Traversable)
