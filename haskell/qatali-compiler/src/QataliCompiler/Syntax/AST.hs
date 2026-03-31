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
    DataDeclKind (..),

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
    HandleVar (..),
    TemplateSegment (..),
    BinOp (..),
    UnaryOp (..),

    -- * Array elements (with spread)
    ArrayElem (..),

    -- * Patterns
    Pat (..),
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

-- | Whether a data declaration uses record or tuple syntax.
data DataDeclKind = DeclRecord | DeclTuple
    deriving (Eq, Ord, Show)

-- | A source module.
data Module ann = Module
    { modAnn   :: !ann
    , modName  :: !ModuleName
    , modDecls :: ![Decl ann]
    }
    deriving (Eq, Show, Functor, Foldable, Traversable)

-- | A top-level declaration.
data Decl ann
    = DeclLet !ann !Bool !(LetTarget ann) ![SrcTypeParam ann] !(Maybe (TyExpr ann)) !(Expr ann)
      -- ^ @[pub] let name\<T\>: Type = expr@, Bool = isPub
    | DeclFn !ann !Bool !Name ![SrcTypeParam ann] ![(QualifiedName, [TyExpr ann])] ![Param ann] !(Maybe (TyExpr ann)) !(Maybe (TyExpr ann)) !(FnBody ann)
      -- ^ @[pub] fn name\<T\>[Trait\<T\>](x: A) -> B with E { body }@
      --   Fields: ann, isPub, name, typeParams, traitAnnots, params, retTy, effectTy, body
    | DeclType !ann !Name ![SrcTypeParam ann] !(TyExpr ann)
      -- ^ @type Name\<T\> = ...@
    | DeclData !ann !Bool !Name ![SrcDataTypeParam ann] !DataDeclKind ![(Name, TyExpr ann)]
      -- ^ @[pub] data Name\<out T\> { field: T }@ or tuple syntax, Bool = isPub (exports constructors)
    | DeclEffect !ann !Bool !Name ![SrcDataTypeParam ann] ![(Name, TyExpr ann)] !(TyExpr ann)
      -- ^ @[pub] effect Name\<out T\>(field: T) -> RetTy@, Bool = isPub
    | DeclImport !ann !ModuleName !(Maybe Name) !(Maybe [Name])
      -- ^ @import "path.to.module" [as alias] [{ item1, item2 }]@
    | DeclExport !ann !ModuleName !(Maybe [Name])
      -- ^ @export "path.to.module"@ or @export { name1 } from "path"@
    | DeclForeignFn !ann !Name ![Param ann] !(TyExpr ann) !(Maybe (TyExpr ann))
      -- ^ @foreign fn name(args) -> RetType [with Effect]@
    | DeclTrait !ann !Name ![SrcDataTypeParam ann] ![Param ann] !(TyExpr ann)
      -- ^ @trait Name\<out T\>(arg: T) -> RetTy@
    | DeclImpl !ann !Name !QualifiedName ![TyExpr ann]
      -- ^ @impl fn_name as TraitName\<TypeA, TypeB\>@
    | DeclDerive !ann !QualifiedName ![TyExpr ann]
      -- ^ @derive TraitName\<Type\>@
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
      -- ^ Function / tuple-constructor application @f\<T\>(arg1, arg2)@
    | EFn          !ann ![SrcTypeParam ann] ![Param ann] !(Maybe (TyExpr ann)) !(Maybe (TyExpr ann)) !(FnBody ann)
      -- ^ Anonymous function @fn \<T\>(x: A) -> B with E { body }@
      --   Fields: ann, typeParams, params, retTy, effectTy, body
    | EMatch       !ann !(Expr ann) ![MatchArm ann]
      -- ^ Pattern match @match expr { case pat [if cond] => expr, ... }@
    | EIf          !ann !(Expr ann) !(Expr ann) !(Maybe (Expr ann))
      -- ^ Conditional @if cond then else@
    | EBlock       !ann ![Stmt ann]
      -- ^ Block expression @{ stmt; stmt; expr }@
    | EHandle      !ann !(Expr ann) ![HandleVar ann] ![HandleCase ann] !(Maybe (HandleReturn ann))
      -- ^ Effect handler @handle { block } with { [var decls] case Eff(x) => ..., return x => ... }@
    | EConstruct   !ann !QualifiedName ![(Name, Expr ann)]
      -- ^ Record construction @User { id = 1, name = "Alice" }@
    | EArray       !ann ![ArrayElem ann]
      -- ^ Array literal @[a, ...arr, b]@
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
    | EContinue    !ann !(Expr ann) !(Maybe [(Name, Expr ann)])
      -- ^ Effect continuation @continue value [with { foo = ...; }]@
    | EBreak       !ann !(Expr ann)
      -- ^ Break from handler: @break value@
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

-- | A match arm: pattern + optional guard → body.
data MatchArm ann = MatchArm
    { maAnn   :: !ann
    , maPat   :: !(Pat ann)
    , maGuard :: !(Maybe (Expr ann))  -- ^ Optional guard: @if condition@
    , maBody  :: !(Expr ann)
    }
    deriving (Eq, Show, Functor, Foldable, Traversable)

-- | A handler variable declaration inside a handle's with-block.
data HandleVar ann = HandleVar
    { hvAnn  :: !ann
    , hvName :: !Name
    , hvType :: !(Maybe (TyExpr ann))
    , hvInit :: !(Expr ann)
    }
    deriving (Eq, Show, Functor, Foldable, Traversable)

-- | A handler case for an effect.
data HandleCase ann = HandleCase
    { hcAnn    :: !ann
    , hcEffect :: !QualifiedName   -- ^ Effect name (may be qualified, e.g. @cron.Triggered@)
    , hcTyVars :: ![Name]          -- ^ Type vars introduced (e.g. @T@ in @case Effect\<T\>(x)@)
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
-- Array elements (with spread support)

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
    | PCon    !ann !QualifiedName ![Name] ![Pat ann]
      -- ^ Tuple-data constructor pattern @Point\<T\>(x, y)@ where [Name] are introduced type vars
    | PRecord !ann !QualifiedName ![Name] ![(Name, Pat ann)]
      -- ^ Record-data pattern @User\<T\> { id = i, name = n }@ where [Name] are introduced type vars
    | PArray  !ann !(SpreadPat ann)
      -- ^ Array pattern @[p1, ...rest, p2]@
    deriving (Eq, Show, Functor, Foldable, Traversable)

-- | Spread pattern for arrays: at most one spread at any position.
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
    | TyArray     !ann !(TyExpr ann)
      -- ^ Array type @Array\<T\>@
    | TyUnion     !ann !(TyExpr ann) !(TyExpr ann)
      -- ^ Union type @A | B@
    | TyIntersect !ann !(TyExpr ann) !(TyExpr ann)
      -- ^ Intersection type @A & B@
    | TyLit       !ann !Literal
      -- ^ Literal type @1@, @"hello"@, @true@
    deriving (Eq, Show, Functor, Foldable, Traversable)
