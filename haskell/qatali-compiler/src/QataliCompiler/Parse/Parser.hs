{- | Parser: source text → parsed AST.

Uses megaparsec directly (parser-combinator style, no separate lexing pass).
Source positions from megaparsec are converted to our 'SrcSpan' type.

Syntax overview:
  * Comments: @\/\/@ (line), @\/* *\/@ (block, nestable)
  * Statement separator: semicolon or newline
  * Trailing commas allowed
  * Object construction uses @=@, type annotation uses @:@
-}
module QataliCompiler.Parse.Parser (
    QParseError,
    parseModule,
    parseExpr,
) where

import           Control.Monad                (void)
import           Data.List.NonEmpty           (NonEmpty (..))
import           Control.Monad.Combinators.Expr (Operator (..), makeExprParser)
import           Data.Maybe                   (fromMaybe)
import           Data.Text                    (Text)
import qualified Data.Text                    as T
import           Data.Void                    (Void)
import           Text.Megaparsec              hiding (ParseError)
import           Text.Megaparsec.Char
import qualified Text.Megaparsec.Char.Lexer   as L

import           QataliCompiler.Name          (ModuleName (..), Name (..),
                                               QualifiedName (..))
import           QataliCompiler.SrcLoc        (SrcPos (..), SrcSpan (..),
                                               (<->))
import           QataliCompiler.Syntax.AST
import           QataliCompiler.Syntax.Literal

-- =========================================================================
-- Parser type & helpers
-- =========================================================================

type Parser = Parsec Void Text
type QParseError = ParseErrorBundle Text Void

-- | Convert megaparsec 'SourcePos' to our 'SrcPos'.
toSrcPos :: SourcePos -> SrcPos
toSrcPos sp = SrcPos (unPos (sourceLine sp)) (unPos (sourceColumn sp))

-- | Run a parser, capturing the span of the consumed input.
withSpan :: Parser a -> Parser (SrcSpan, a)
withSpan p = do
    s0 <- getSourcePos
    result <- p
    s1 <- getSourcePos
    let sp = SrcSpan (sourceName s0) (toSrcPos s0) (toSrcPos s1)
    pure (sp, result)

-- | Get current span (zero-width).
curSpan :: Parser SrcSpan
curSpan = do
    sp <- getSourcePos
    let pos = toSrcPos sp
    pure (SrcSpan (sourceName sp) pos pos)

-- =========================================================================
-- Whitespace & lexeme helpers
-- =========================================================================

-- | Skip whitespace and comments (// and /* */).
sc :: Parser ()
sc = L.space space1 (L.skipLineComment "//") (L.skipBlockCommentNested "/*" "*/")

lexeme :: Parser a -> Parser a
lexeme = L.lexeme sc

symbol :: Text -> Parser Text
symbol = L.symbol sc

-- | Parse a keyword (must not be followed by identifier chars).
keyword :: Text -> Parser Text
keyword kw = lexeme (string kw <* notFollowedBy identContChar)

-- | Characters that can appear after the first char of an identifier.
identContChar :: Parser Char
identContChar = alphaNumChar <|> char '_' <|> char '\''

-- | Parse an identifier or keyword as raw text.
identOrKeyword :: Parser Text
identOrKeyword = lexeme $ do
    first <- letterChar <|> char '_'
    rest <- many identContChar
    pure (T.pack (first : rest))

-- | Reserved keywords.
reservedWords :: [Text]
reservedWords =
    [ "let", "fn", "if", "else", "match", "case", "return"
    , "handle", "continue", "effect", "data", "type", "import"
    , "as", "module", "sub", "sup", "is", "in", "out", "with"
    , "null", "true", "false", "pure", "impure"
    ]

-- | Parse a non-reserved identifier.
pIdent :: Parser Name
pIdent = try $ do
    w <- identOrKeyword
    if w `elem` reservedWords
        then fail ("reserved word: " ++ T.unpack w)
        else pure (Name w)

-- | Parse an uppercase identifier (constructor / type name).
pConName :: Parser Name
pConName = try $ do
    n <- pIdent
    let t = unName n
    case T.uncons t of
        Just (c, _) | c >= 'A' && c <= 'Z' -> pure n
        _ -> fail "expected uppercase identifier"

-- | Parse a lowercase identifier.
pLowerIdent :: Parser Name
pLowerIdent = try $ do
    n <- pIdent
    let t = unName n
    case T.uncons t of
        Just (c, _) | c >= 'a' && c <= 'z' || c == '_' -> pure n
        _ -> fail "expected lowercase identifier"

-- | Statement separator: semicolon or newline.
pSep :: Parser ()
pSep = void (symbol ";") <|> void (satisfy (== '\n') *> sc)

-- | Optional statement separator.
pOptSep :: Parser ()
pOptSep = optional pSep *> pure ()

-- | Comma-separated list with optional trailing comma.
commaSep :: Parser a -> Parser [a]
commaSep p = sepEndBy p (symbol ",")

-- | Comma-separated list with at least one element, optional trailing comma.
commaSep1 :: Parser a -> Parser [a]
commaSep1 p = sepEndBy1 p (symbol ",")

-- =========================================================================
-- Entry points
-- =========================================================================

-- | Parse an entire module from source text.
parseModule :: FilePath -> Text -> Either QParseError (Module SrcSpan)
parseModule fp src = parse (sc *> pModule <* eof) fp src

-- | Parse a single expression (useful for REPL / tests).
parseExpr :: FilePath -> Text -> Either QParseError (Expr SrcSpan)
parseExpr fp src = parse (sc *> pExpr <* eof) fp src

-- =========================================================================
-- Literals
-- =========================================================================

pLiteral :: Parser Literal
pLiteral = choice
    [ LitNull <$ keyword "null"
    , LitBoolean True <$ keyword "true"
    , LitBoolean False <$ keyword "false"
    , try (LitNumber <$> lexeme L.float)
    , LitInteger <$> lexeme L.decimal
    , LitString <$> pStringLit
    ]

pStringLit :: Parser Text
pStringLit = lexeme (char '"' *> (T.pack <$> manyTill L.charLiteral (char '"')))

-- =========================================================================
-- Type expressions
-- =========================================================================

-- | Parse a type expression.
pTyExpr :: Parser (TyExpr SrcSpan)
pTyExpr = makeExprParser pTyAtom tyOperators

tyOperators :: [[Operator Parser (TyExpr SrcSpan)]]
tyOperators =
    [ [ InfixR $ do
            _ <- symbol "&"
            pure (\a b -> TyIntersect (tySpan a <-> tySpan b) a b)
      ]
    , [ InfixR $ do
            _ <- symbol "|"
            pure (\a b -> TyUnion (tySpan a <-> tySpan b) a b)
      ]
    ]

pTyAtom :: Parser (TyExpr SrcSpan)
pTyAtom = do
    base <- pTyPrimary
    -- Check for <...> type application
    mArgs <- optional (try (symbol "<" *> commaSep1 pTyExpr <* symbol ">"))
    case mArgs of
        Nothing -> pure base
        Just args -> pure (TyApp (tySpan base) base args)

pTyPrimary :: Parser (TyExpr SrcSpan)
pTyPrimary = choice
    [ pTyFun
    , pTyObject
    , pTyTupleOrParens
    , pTyLit
    , pTyKeywordType
    , pTyNamed
    ]

-- | Literal type: @1@, @3.14@, @\"hello\"@, @true@, @false@.
pTyLit :: Parser (TyExpr SrcSpan)
pTyLit = try $ do
    (sp, lit) <- withSpan pTyLiteral
    pure (TyLit sp lit)
  where
    pTyLiteral = choice
        [ LitBoolean True <$ keyword "true"
        , LitBoolean False <$ keyword "false"
        , try (LitNumber <$> lexeme L.float)
        , LitInteger <$> lexeme L.decimal
        , LitString <$> pStringLit
        ]

-- | Reserved words that are valid as types: @null@.
pTyKeywordType :: Parser (TyExpr SrcSpan)
pTyKeywordType = do
    (sp, _) <- withSpan (keyword "null")
    pure (TyCon sp (QualifiedName Nothing (Name "null")))

-- | Function type: @(x: A, y: B) => C@ or @(x: A, y: B) => C with E@
pTyFun :: Parser (TyExpr SrcSpan)
pTyFun = try $ do
    (sp0, _) <- withSpan (symbol "(")
    params <- commaSep pTyFunParam
    _ <- symbol ")"
    _ <- symbol "=>"
    ret <- pTyExpr
    eff <- optional (keyword "with" *> pEffectExpr)
    sp1 <- curSpan
    pure (TyFun (sp0 <-> sp1) params ret eff)

-- | Parse an effect expression (after @with@ keyword).
-- Supports: @pure@, @impure@, @EffName@, @EffName\<T\>@, @E1 | E2@.
pEffectExpr :: Parser (TyExpr SrcSpan)
pEffectExpr = makeExprParser pEffectAtom effectOperators

effectOperators :: [[Operator Parser (TyExpr SrcSpan)]]
effectOperators =
    [ [ InfixR $ do
            _ <- symbol "|"
            pure (\a b -> TyUnion (tySpan a <-> tySpan b) a b)
      ]
    ]

pEffectAtom :: Parser (TyExpr SrcSpan)
pEffectAtom = do
    base <- pEffectPrimary
    mArgs <- optional (try (symbol "<" *> commaSep1 pTyExpr <* symbol ">"))
    case mArgs of
        Nothing   -> pure base
        Just args -> pure (TyApp (tySpan base) base args)

pEffectPrimary :: Parser (TyExpr SrcSpan)
pEffectPrimary = choice
    [ do (sp, _) <- withSpan (keyword "pure")
         pure (TyCon sp (QualifiedName Nothing (Name "pure")))
    , do (sp, _) <- withSpan (keyword "impure")
         pure (TyCon sp (QualifiedName Nothing (Name "impure")))
    , pTyNamed  -- effect names (e.g. Log, Ask)
    ]

pTyFunParam :: Parser (Name, TyExpr SrcSpan)
pTyFunParam = do
    name <- pIdent
    _ <- symbol ":"
    ty <- pTyExpr
    pure (name, ty)

-- | Object type: @{a: T, b: U}@
pTyObject :: Parser (TyExpr SrcSpan)
pTyObject = do
    (sp0, _) <- withSpan (symbol "{")
    fields <- commaSep pTyObjField
    (sp1, _) <- withSpan (symbol "}")
    pure (TyObject (sp0 <-> sp1) fields)

pTyObjField :: Parser (Name, TyExpr SrcSpan)
pTyObjField = do
    name <- pIdent
    _ <- symbol ":"
    ty <- pTyExpr
    pure (name, ty)

-- | Tuple type @(A, B)@ or parenthesized type @(A)@.
pTyTupleOrParens :: Parser (TyExpr SrcSpan)
pTyTupleOrParens = do
    (sp0, _) <- withSpan (symbol "(")
    elems <- commaSep pTyExpr
    (sp1, _) <- withSpan (symbol ")")
    case elems of
        [one] -> pure one  -- parenthesized
        _        -> pure (TyTuple (sp0 <-> sp1) elems)

-- | Named type (any identifier — variable or constructor).
-- Whether it's a type variable is determined at resolution time via the type env.
pTyNamed :: Parser (TyExpr SrcSpan)
pTyNamed = do
    (sp, name) <- withSpan pIdent
    pure (TyCon sp (QualifiedName Nothing name))

-- | Extract span from a type expression.
tySpan :: TyExpr SrcSpan -> SrcSpan
tySpan = \case
    TyVar sp _       -> sp
    TyCon sp _       -> sp
    TyApp sp _ _     -> sp
    TyFun sp _ _ _   -> sp
    TyObject sp _    -> sp
    TyTuple sp _     -> sp
    TyArray sp _     -> sp
    TyUnion sp _ _   -> sp
    TyIntersect sp _ _ -> sp
    TyLit sp _       -> sp

-- =========================================================================
-- Patterns
-- =========================================================================

pPat :: Parser (Pat SrcSpan)
pPat = choice
    [ pPatCon
    , pPatObject
    , pPatTuple
    , pPatArray
    , pPatLit
    , pPatWild
    , pPatVar
    ]

pPatVar :: Parser (Pat SrcSpan)
pPatVar = do
    (sp, name) <- withSpan pLowerIdent
    pure (PVar sp name)

pPatLit :: Parser (Pat SrcSpan)
pPatLit = do
    (sp, lit) <- withSpan pLiteral
    pure (PLit sp lit)

pPatWild :: Parser (Pat SrcSpan)
pPatWild = do
    (sp, _) <- withSpan (symbol "_")
    pure (PWild sp)

-- | Constructor pattern: @Con(p1, p2)@
pPatCon :: Parser (Pat SrcSpan)
pPatCon = try $ do
    (sp0, name) <- withSpan pConName
    _ <- symbol "("
    pats <- commaSep pPat
    (sp1, _) <- withSpan (symbol ")")
    pure (PCon (sp0 <-> sp1) (QualifiedName Nothing name) pats)

-- | Object pattern: @{a = p1, b = p2, ...rest}@
pPatObject :: Parser (Pat SrcSpan)
pPatObject = do
    (sp0, _) <- withSpan (symbol "{")
    (fields, rest) <- pObjPatFields
    (sp1, _) <- withSpan (symbol "}")
    pure (PObject (sp0 <-> sp1) (ObjectPat fields rest))

pObjPatFields :: Parser ([(Name, Pat SrcSpan)], Maybe (SrcSpan, Name))
pObjPatFields = do
    items <- commaSep pObjPatItem
    let fields = [f | Left f <- items]
    let rests  = [r | Right r <- items]
    case rests of
        []  -> pure (fields, Nothing)
        [r] -> pure (fields, Just r)
        _   -> fail "at most one ...rest in object pattern"

pObjPatItem :: Parser (Either (Name, Pat SrcSpan) (SrcSpan, Name))
pObjPatItem = (Right <$> try pObjPatSpread) <|> (Left <$> pObjPatField)

pObjPatSpread :: Parser (SrcSpan, Name)
pObjPatSpread = do
    (sp, _) <- withSpan (symbol "...")
    name <- pLowerIdent
    pure (sp, name)

pObjPatField :: Parser (Name, Pat SrcSpan)
pObjPatField = do
    name <- pIdent
    _ <- symbol "="
    pat <- pPat
    pure (name, pat)

-- | Tuple pattern: @(p1, ...rest, p2)@
pPatTuple :: Parser (Pat SrcSpan)
pPatTuple = try $ do
    (sp0, _) <- withSpan (symbol "(")
    spread <- pSpreadPat
    (sp1, _) <- withSpan (symbol ")")
    pure (PTuple (sp0 <-> sp1) spread)

-- | Array pattern: @[p1, ...rest, p2]@
pPatArray :: Parser (Pat SrcSpan)
pPatArray = do
    (sp0, _) <- withSpan (symbol "[")
    spread <- pSpreadPat
    (sp1, _) <- withSpan (symbol "]")
    pure (PArray (sp0 <-> sp1) spread)

-- | Parse spread pattern elements, collecting before/spread/after.
pSpreadPat :: Parser (SpreadPat SrcSpan)
pSpreadPat = do
    items <- commaSep pSpreadPatItem
    let (before, spreadAndAfter) = break isSpread items
    case spreadAndAfter of
        [] -> pure (SpreadPat (map fromElem before) Nothing [])
        (SpreadItem sp p : rest) ->
            if any isSpread rest
            then fail "at most one ...spread in pattern"
            else pure (SpreadPat (map fromElem before) (Just (sp, p)) (map fromElem rest))
        _ -> error "impossible"
  where
    isSpread (SpreadItem _ _) = True
    isSpread _                = False
    fromElem (ElemItem p) = p
    fromElem _            = error "impossible"

data SpreadPatItem
    = ElemItem (Pat SrcSpan)
    | SpreadItem SrcSpan (Pat SrcSpan)

pSpreadPatItem :: Parser SpreadPatItem
pSpreadPatItem =
    (try $ do
        (sp, _) <- withSpan (symbol "...")
        p <- pPat
        pure (SpreadItem sp p))
    <|> (ElemItem <$> pPat)

-- =========================================================================
-- Expressions
-- =========================================================================

-- | Parse an expression with binary operators.
pExpr :: Parser (Expr SrcSpan)
pExpr = makeExprParser pExprUnary exprOperators

exprOperators :: [[Operator Parser (Expr SrcSpan)]]
exprOperators =
    [ [ InfixL (binOp "++" OpConcat) ]
    , [ InfixL (binOp "*" OpMul)
      , InfixL (binOp "/" OpDiv)
      , InfixL (binOp "%" OpMod)
      ]
    , [ InfixL (binOp "+" OpAdd)
      , InfixL (binOp "-" OpSub)
      ]
    , [ InfixN (binOp "==" OpEq)
      , InfixN (binOp "!=" OpNeq)
      , InfixN (binOp "<=" OpLe)
      , InfixN (binOp ">=" OpGe)
      , InfixN (binOp "<" OpLt)
      , InfixN (binOp ">" OpGt)
      ]
    , [ InfixR (binOp "&&" OpAnd) ]
    , [ InfixR (binOp "||" OpOr) ]
    ]

binOp :: Text -> BinOp -> Parser (Expr SrcSpan -> Expr SrcSpan -> Expr SrcSpan)
binOp sym op = do
    _ <- try (symbol sym <* notFollowedBy (char '='))  -- avoid matching += etc.
    pure (\a b -> EBinOp (exprSpan a <-> exprSpan b) op a b)

pExprUnary :: Parser (Expr SrcSpan)
pExprUnary = choice
    [ do (sp, _) <- withSpan (symbol "!")
         e <- pExprUnary
         pure (EUnaryOp (sp <-> exprSpan e) OpNot e)
    , do (sp, _) <- withSpan (symbol "-")
         e <- pExprUnary
         pure (EUnaryOp (sp <-> exprSpan e) OpNeg e)
    , pExprPostfix
    ]

-- | Postfix: field access, indexing, function call.
pExprPostfix :: Parser (Expr SrcSpan)
pExprPostfix = do
    base <- pExprAtom
    postfixes base
  where
    postfixes e = (postfix e >>= postfixes) <|> pure e

    postfix e = choice
        [ -- .field
          do _ <- symbol "."
             (sp, name) <- withSpan pIdent
             pure (EField (exprSpan e <-> sp) e name)
        , -- [index]
          do _ <- symbol "["
             idx <- pExpr
             (sp, _) <- withSpan (symbol "]")
             pure (EIndex (exprSpan e <-> sp) e idx)
        , -- <T>(args) or (args)
          try $ do
             tyArgs <- fromMaybe [] <$> optional (try (symbol "<" *> commaSep1 pTyExpr <* symbol ">"))
             _ <- symbol "("
             args <- commaSep pExpr
             (sp, _) <- withSpan (symbol ")")
             pure (EApp (exprSpan e <-> sp) e tyArgs args)
        ]

-- | Atomic expressions (no left-recursion).
pExprAtom :: Parser (Expr SrcSpan)
pExprAtom = choice
    [ pExprLit
    , pExprIf
    , pExprMatch
    , pExprHandle
    , pExprFn
    , pExprTemplateLit
    , pExprArray
    , pExprObjectOrBlock
    , pExprTupleOrParens
    , pExprVar
    ]

pExprLit :: Parser (Expr SrcSpan)
pExprLit = do
    (sp, lit) <- withSpan pLiteral
    pure (ELit sp lit)

pExprVar :: Parser (Expr SrcSpan)
pExprVar = do
    (sp, name) <- withSpan pIdent
    pure (EVar sp (QualifiedName Nothing name))

-- | @if cond { stmts } else { stmts }@  (else is optional)
pExprIf :: Parser (Expr SrcSpan)
pExprIf = do
    (sp0, _) <- withSpan (keyword "if")
    cond <- pExpr
    thn <- pBlock
    els <- optional (keyword "else" *> pBlock)
    sp1 <- curSpan
    pure (EIf (sp0 <-> sp1) cond thn els)

-- | @match expr { case (pat) => expr, ... }@
pExprMatch :: Parser (Expr SrcSpan)
pExprMatch = do
    (sp0, _) <- withSpan (keyword "match")
    scrut <- pExpr
    _ <- symbol "{"
    arms <- many pMatchArm
    (sp1, _) <- withSpan (symbol "}")
    pure (EMatch (sp0 <-> sp1) scrut arms)

pMatchArm :: Parser (MatchArm SrcSpan)
pMatchArm = do
    (sp, _) <- withSpan (keyword "case")
    _ <- symbol "("
    pat <- pPat
    _ <- symbol ")"
    _ <- symbol "=>"
    body <- pExpr
    pOptSep
    pure (MatchArm sp pat body)

-- | @handle expr { case Eff(x) => ..., return x => ... }@
pExprHandle :: Parser (Expr SrcSpan)
pExprHandle = do
    (sp0, _) <- withSpan (keyword "handle")
    expr <- pExpr
    _ <- symbol "{"
    cases <- many (try pHandleCase)
    ret <- optional pHandleReturn
    (sp1, _) <- withSpan (symbol "}")
    pure (EHandle (sp0 <-> sp1) expr cases ret)

pHandleCase :: Parser (HandleCase SrcSpan)
pHandleCase = do
    (sp, _) <- withSpan (keyword "case")
    effName <- pConName
    _ <- symbol "("
    params <- commaSep pPat
    _ <- symbol ")"
    _ <- symbol "=>"
    body <- pExpr
    pOptSep
    pure (HandleCase sp effName params body)

pHandleReturn :: Parser (HandleReturn SrcSpan)
pHandleReturn = do
    (sp, _) <- withSpan (keyword "return")
    name <- pLowerIdent
    _ <- symbol "=>"
    body <- pExpr
    pOptSep
    pure (HandleReturn sp name body)

-- | Anonymous function: @fn \<T\>(x: A): B => expr | { block }@
pExprFn :: Parser (Expr SrcSpan)
pExprFn = do
    (sp0, _) <- withSpan (keyword "fn")
    tyParams <- fromMaybe [] <$> optional pTypeParams
    _ <- symbol "("
    params <- commaSep pParam
    _ <- symbol ")"
    retTy <- optional (symbol ":" *> pTyExpr)
    _ <- symbol "=>"
    body <- pFnBody
    sp1 <- curSpan
    pure (EFn (sp0 <-> sp1) tyParams params retTy body)

pFnBody :: Parser (FnBody SrcSpan)
pFnBody = do
    (sp, _) <- withSpan (symbol "{")
    stmts <- pStmts
    _ <- symbol "}"
    pure (FnBlock sp stmts)

-- | Parse a block: @{ stmt; stmt; ... }@ — always interpreted as a block, never an object.
pBlock :: Parser (Expr SrcSpan)
pBlock = do
    (sp0, _) <- withSpan (symbol "{")
    stmts <- pStmts
    (sp1, _) <- withSpan (symbol "}")
    pure (EBlock (sp0 <-> sp1) stmts)

-- | Template literal: @`text ${expr} text`@
pExprTemplateLit :: Parser (Expr SrcSpan)
pExprTemplateLit = do
    (sp0, _) <- withSpan (lexeme (char '`'))
    segs <- manyTill pTemplateSegment (char '`')
    sc
    sp1 <- curSpan
    pure (ETemplateLit (sp0 <-> sp1) segs)

pTemplateSegment :: Parser (TemplateSegment SrcSpan)
pTemplateSegment = pTemplateExpr <|> pTemplateStr

pTemplateExpr :: Parser (TemplateSegment SrcSpan)
pTemplateExpr = do
    _ <- string "${"
    sc
    e <- pExpr
    _ <- char '}'
    pure (TmplExpr e)

pTemplateStr :: Parser (TemplateSegment SrcSpan)
pTemplateStr = do
    (sp, txt) <- withSpan $ do
        cs <- some (noneOf ['`', '$'] <|> try (char '$' <* notFollowedBy (char '{')))
        pure (T.pack cs)
    pure (TmplStr sp (Name txt))

-- | Array literal: @[a, ...arr, b]@
pExprArray :: Parser (Expr SrcSpan)
pExprArray = do
    (sp0, _) <- withSpan (symbol "[")
    elems <- commaSep pArrayElem
    (sp1, _) <- withSpan (symbol "]")
    pure (EArray (sp0 <-> sp1) elems)

pArrayElem :: Parser (ArrayElem SrcSpan)
pArrayElem = (ASpread <$> (symbol "..." *> pExpr)) <|> (AElem <$> pExpr)

-- | Object literal @{ ...spread, a = 1, b = 2 }@ or block @{ stmt; stmt }@.
-- Disambiguation: if starts with @...@ or @ident =@ it's an object, otherwise block.
pExprObjectOrBlock :: Parser (Expr SrcSpan)
pExprObjectOrBlock = do
    (sp0, _) <- withSpan (symbol "{")
    -- Try to detect object vs block
    choice
        [ -- Empty braces → empty object
          do (sp1, _) <- withSpan (symbol "}")
             pure (EObject (sp0 <-> sp1) Nothing [])
        , -- Spread → definitely object
          do spread <- Just <$> (symbol "..." *> pExpr)
             fields <- many (symbol "," *> pObjField)
             _ <- optional (symbol ",")
             (sp1, _) <- withSpan (symbol "}")
             pure (EObject (sp0 <-> sp1) spread fields)
        , -- name = → object field
          try $ do
             fields <- commaSep1 pObjField
             (sp1, _) <- withSpan (symbol "}")
             pure (EObject (sp0 <-> sp1) Nothing fields)
        , -- Otherwise → block
          do stmts <- pStmts
             (sp1, _) <- withSpan (symbol "}")
             pure (EBlock (sp0 <-> sp1) stmts)
        ]

pObjField :: Parser (Name, Expr SrcSpan)
pObjField = do
    name <- pIdent
    _ <- symbol "="
    val <- pExpr
    pure (name, val)

-- | Tuple @(a, b)@ or parenthesized expression @(expr)@.
-- Also handles spread: @(a, ...t, b)@
pExprTupleOrParens :: Parser (Expr SrcSpan)
pExprTupleOrParens = do
    (sp0, _) <- withSpan (symbol "(")
    -- Check empty tuple
    mClose <- optional (symbol ")")
    case mClose of
        Just _ -> pure (ETuple sp0 [])
        Nothing -> do
            elems <- commaSep1 pTupleElem
            (sp1, _) <- withSpan (symbol ")")
            case elems of
                [TElem e] -> pure e  -- parenthesized expression
                _         -> pure (ETuple (sp0 <-> sp1) elems)

pTupleElem :: Parser (TupleElem SrcSpan)
pTupleElem = (TSpread <$> (symbol "..." *> pExpr)) <|> (TElem <$> pExpr)

-- =========================================================================
-- Statements
-- =========================================================================

pStmts :: Parser [Stmt SrcSpan]
pStmts = many (pStmt <* pOptSep)

pStmt :: Parser (Stmt SrcSpan)
pStmt = choice
    [ pStmtLet
    , pStmtReturn
    , StmtExpr <$> pExpr
    ]

pStmtLet :: Parser (Stmt SrcSpan)
pStmtLet = do
    (sp, _) <- withSpan (keyword "let")
    target <- pLetTarget
    tyAnn <- optional (symbol ":" *> pTyExpr)
    _ <- symbol "="
    val <- pExpr
    pure (StmtLet sp target tyAnn val)

pStmtReturn :: Parser (Stmt SrcSpan)
pStmtReturn = do
    (sp, _) <- withSpan (keyword "return")
    val <- optional (try pExpr)
    pure (StmtReturn sp val)

-- =========================================================================
-- Declarations
-- =========================================================================

pModule :: Parser (Module SrcSpan)
pModule = do
    (sp, _) <- withSpan (keyword "module")
    mname <- pModuleName
    pOptSep
    decls <- many (pDecl <* pOptSep)
    pure (Module sp mname decls)

pModuleName :: Parser ModuleName
pModuleName = do
    seg1 <- pIdent
    segs <- many (symbol "." *> pIdent)
    pure (ModuleName (unName seg1 :| map unName segs))

pDecl :: Parser (Decl SrcSpan)
pDecl = choice
    [ pDeclFn
    , pDeclLet
    , pDeclType
    , pDeclData
    , pDeclEffect
    , pDeclImport
    ]

-- | @let name\<T\>: Type = expr@ or @let pattern: Type = expr@
pDeclLet :: Parser (Decl SrcSpan)
pDeclLet = do
    (sp, _) <- withSpan (keyword "let")
    target <- pLetTarget
    tyParams <- fromMaybe [] <$> optional pTypeParams
    tyAnn <- optional (symbol ":" *> pTyExpr)
    _ <- symbol "="
    val <- pExpr
    pure (DeclLet sp target tyParams tyAnn val)

pLetTarget :: Parser (LetTarget SrcSpan)
pLetTarget = (LetPat <$> try pPatDestructure) <|> (LetName <$> pIdent)

-- | Destructuring patterns that are unambiguous (object/tuple/array).
pPatDestructure :: Parser (Pat SrcSpan)
pPatDestructure = pPatObject <|> pPatTuple <|> pPatArray

-- | @fn name\<T\>(x: A, y: B): C => expr | { block }@
pDeclFn :: Parser (Decl SrcSpan)
pDeclFn = do
    (sp, _) <- withSpan (keyword "fn")
    name <- pIdent
    tyParams <- fromMaybe [] <$> optional pTypeParams
    _ <- symbol "("
    params <- commaSep pParam
    _ <- symbol ")"
    retTy <- optional (symbol ":" *> pTyExpr)
    _ <- symbol "=>"
    body <- pFnBody
    pure (DeclFn sp name tyParams params retTy body)

-- | @type Name\<T\> = TyExpr@
pDeclType :: Parser (Decl SrcSpan)
pDeclType = do
    (sp, _) <- withSpan (keyword "type")
    name <- pIdent
    tyParams <- fromMaybe [] <$> optional pTypeParams
    _ <- symbol "="
    ty <- pTyExpr
    pure (DeclType sp name tyParams ty)

-- | @data Name\<out T sub U\>(field1: T1, field2: T2)@
pDeclData :: Parser (Decl SrcSpan)
pDeclData = do
    (sp, _) <- withSpan (keyword "data")
    name <- pConName
    dtParams <- fromMaybe [] <$> optional pDataTypeParams
    _ <- symbol "("
    fields <- commaSep pFieldDecl
    _ <- symbol ")"
    pure (DeclData sp name dtParams fields)

-- | @effect Name\<out T\>(field: T) => RetTy@
pDeclEffect :: Parser (Decl SrcSpan)
pDeclEffect = do
    (sp, _) <- withSpan (keyword "effect")
    name <- pConName
    dtParams <- fromMaybe [] <$> optional pDataTypeParams
    _ <- symbol "("
    fields <- commaSep pFieldDecl
    _ <- symbol ")"
    _ <- symbol "=>"
    retTy <- pTyExpr
    pure (DeclEffect sp name dtParams fields retTy)

-- | @import Foo.Bar as F (item1, item2)@
pDeclImport :: Parser (Decl SrcSpan)
pDeclImport = do
    (sp, _) <- withSpan (keyword "import")
    mname <- pModuleName
    alias <- optional (keyword "as" *> pIdent)
    items <- optional (symbol "(" *> commaSep pIdent <* symbol ")")
    pure (DeclImport sp mname alias items)

-- =========================================================================
-- Shared helpers
-- =========================================================================

-- | Function parameter: @name: Type@
pParam :: Parser (Param SrcSpan)
pParam = do
    (sp, name) <- withSpan pIdent
    _ <- symbol ":"
    ty <- pTyExpr
    pure (Param sp name ty)

-- | Data field: @name: Type@
pFieldDecl :: Parser (Name, TyExpr SrcSpan)
pFieldDecl = do
    name <- pIdent
    _ <- symbol ":"
    ty <- pTyExpr
    pure (name, ty)

-- | Generic type parameters: @\<T sub U, S\>@
pTypeParams :: Parser [SrcTypeParam SrcSpan]
pTypeParams = symbol "<" *> commaSep1 pSrcTypeParam <* symbol ">"

pSrcTypeParam :: Parser (SrcTypeParam SrcSpan)
pSrcTypeParam = do
    (sp, name) <- withSpan pIdent
    bound <- optional pSrcBound
    pure (SrcTypeParam sp name bound)

pSrcBound :: Parser (SrcBound SrcSpan)
pSrcBound = choice
    [ do (sp, _) <- withSpan (keyword "sub"); ty <- pTyExpr; pure (SrcBoundSub sp ty)
    , do (sp, _) <- withSpan (keyword "sup"); ty <- pTyExpr; pure (SrcBoundSup sp ty)
    , do (sp, _) <- withSpan (keyword "is");  ty <- pTyExpr; pure (SrcBoundIs sp ty)
    ]

-- | Data type parameters: @\<out T sub U, in S\>@
pDataTypeParams :: Parser [SrcDataTypeParam SrcSpan]
pDataTypeParams = symbol "<" *> commaSep1 pSrcDataTypeParam <* symbol ">"

pSrcDataTypeParam :: Parser (SrcDataTypeParam SrcSpan)
pSrcDataTypeParam = do
    (sp, _) <- withSpan (pure ())
    variance <- pSrcVariance
    name <- pIdent
    bound <- optional pSrcBound
    pure (SrcDataTypeParam sp variance name bound)

pSrcVariance :: Parser SrcVariance
pSrcVariance = choice
    [ SrcInOut <$ try (keyword "in" *> keyword "out")
    , SrcIn    <$ keyword "in"
    , SrcOut   <$ keyword "out"
    , pure SrcNone
    ]

-- | Extract span from an expression.
exprSpan :: Expr SrcSpan -> SrcSpan
exprSpan = \case
    EVar sp _           -> sp
    ELit sp _           -> sp
    EApp sp _ _ _       -> sp
    EFn sp _ _ _ _      -> sp
    EMatch sp _ _       -> sp
    EIf sp _ _ _        -> sp
    EBlock sp _         -> sp
    EHandle sp _ _ _    -> sp
    EObject sp _ _      -> sp
    ETuple sp _         -> sp
    EArray sp _         -> sp
    EField sp _ _       -> sp
    EIndex sp _ _       -> sp
    EReturn sp _        -> sp
    ETemplateLit sp _   -> sp
    EBinOp sp _ _ _     -> sp
    EUnaryOp sp _ _     -> sp
