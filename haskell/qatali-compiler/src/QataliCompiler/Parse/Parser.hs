{- | Parser: source text → parsed AST.

Uses megaparsec directly (parser-combinator style, no separate lexing pass).
Source positions from megaparsec are converted to our 'SrcSpan' type.

Syntax overview:
  * Comments: @\/\/@ (line), @\/* *\/@ (block, nestable)
  * Statement separator: semicolon or newline
  * Trailing commas allowed
  * Record construction uses @=@, type annotation uses @:@
  * Block: @{ stmt; stmt; }@
  * Record construction: @Name { field = expr }@
  * Function declaration: @[pub] fn name\<T\>[Trait\<T\>](params) -> RetTy with E { body }@
  * Handle: @handle { body } with { [var x = e;] [case Eff(p) =>] [return x =>] }@
-}
module QataliCompiler.Parse.Parser (
    QParseError,
    parseModule,
    parseExpr,
) where

import           Control.Monad                  (void)
import           Data.List.NonEmpty             (NonEmpty (..))
import           Control.Monad.Combinators.Expr (Operator (..), makeExprParser)
import           Data.Maybe                     (fromMaybe)
import           Data.Text                      (Text)
import qualified Data.Text                      as T
import           Data.Void                      (Void)
import           Text.Megaparsec                hiding (ParseError)
import           Text.Megaparsec.Char
import qualified Text.Megaparsec.Char.Lexer     as L

import           QataliCompiler.Name            (ModuleName (..), Name (..),
                                                 QualifiedName (..), qualify,
                                                 unqualify)
import           QataliCompiler.SrcLoc          (SrcPos (..), SrcSpan (..),
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
-- Uses 'try' so it never partially consumes input on failure.
keyword :: Text -> Parser Text
keyword kw = try $ lexeme (string kw <* notFollowedBy identContChar)

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
    , "handle", "continue", "break", "effect", "data", "type"
    , "import", "export", "from", "as", "module"
    , "sub", "sup", "is", "in", "out", "with"
    , "null", "true", "false", "pure", "impure"
    , "pub", "foreign", "trait", "impl", "derive", "var"
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
-- Qualified name helpers
-- =========================================================================

-- | Parse a (possibly qualified) name: @name@, @module.name@, @a.b.name@.
-- All segments are joined, last is the identifier, rest form the module path.
pQualName :: Parser QualifiedName
pQualName = do
    first <- pIdent
    rest  <- many (try (symbol "." *> pIdent))
    let parts   = first : rest
        nameN   = last parts
        modSegs = init parts
    case modSegs of
        []     -> pure (unqualify nameN)
        (x:xs) -> pure (qualify (ModuleName (unName x :| map unName xs)) nameN)

-- | Parse a qualified uppercase (constructor) name: @Con@, @module.Con@.
pQualConName :: Parser QualifiedName
pQualConName = try $ do
    qn <- pQualName
    case T.uncons (unName (qnName qn)) of
        Just (c, _) | c >= 'A' && c <= 'Z' -> pure qn
        _ -> fail "expected uppercase constructor name"

-- | Parse a module path from a string literal: @\"prim.json\"@.
pModuleNameStr :: Parser ModuleName
pModuleNameStr = do
    str <- pStringLit
    case T.splitOn "." str of
        []     -> fail "empty module name"
        (x:xs) -> pure (ModuleName (x :| xs))

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
    , pTyParens
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

-- | Function type: @(x: A, y: B) -> C@ or @(x: A, y: B) -> C with E@
-- Also supports legacy @=>@ arrow.
pTyFun :: Parser (TyExpr SrcSpan)
pTyFun = try $ do
    (sp0, _) <- withSpan (symbol "(")
    params <- commaSep pTyFunParam
    _ <- symbol ")"
    _ <- symbol "->" <|> symbol "=>"
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
    , pTyNamed  -- qualified effect names (e.g. Log, Throw, prim.Task)
    ]

pTyFunParam :: Parser (Name, TyExpr SrcSpan)
pTyFunParam = do
    name <- pIdent
    _ <- symbol ":"
    ty <- pTyExpr
    pure (name, ty)

-- | Parenthesized type: @(A)@.
pTyParens :: Parser (TyExpr SrcSpan)
pTyParens = do
    _ <- symbol "("
    ty <- pTyExpr
    _ <- symbol ")"
    pure ty

-- | Named type: any identifier, possibly qualified (e.g. @T@, @List@, @prim.Json@).
pTyNamed :: Parser (TyExpr SrcSpan)
pTyNamed = do
    sp0 <- curSpan
    qn  <- pQualName
    sp1 <- curSpan
    pure (TyCon (sp0 <-> sp1) qn)

-- | Extract span from a type expression.
tySpan :: TyExpr SrcSpan -> SrcSpan
tySpan = \case
    TyVar sp _         -> sp
    TyCon sp _         -> sp
    TyApp sp _ _       -> sp
    TyFun sp _ _ _     -> sp
    TyArray sp _       -> sp
    TyUnion sp _ _     -> sp
    TyIntersect sp _ _ -> sp
    TyLit sp _         -> sp

-- =========================================================================
-- Patterns
-- =========================================================================

pPat :: Parser (Pat SrcSpan)
pPat = choice
    [ pPatRecord
    , pPatCon
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

-- | Constructor (tuple-data) pattern: @Con\<T\>(p1, p2)@ or @mod.Con\<T\>(p)@
pPatCon :: Parser (Pat SrcSpan)
pPatCon = try $ do
    sp0   <- curSpan
    qname <- pQualConName
    tyVars <- option [] (try (symbol "<" *> commaSep1 pIdent <* symbol ">"))
    _ <- symbol "("
    pats <- commaSep pPat
    (sp1, _) <- withSpan (symbol ")")
    pure (PCon (sp0 <-> sp1) qname tyVars pats)

-- | Record-data pattern: @Name\<T\> { field1 = pat1 }@ or @mod.Name { ... }@
pPatRecord :: Parser (Pat SrcSpan)
pPatRecord = try $ do
    sp0   <- curSpan
    qname <- pQualConName
    tyVars <- option [] (try (symbol "<" *> commaSep1 pIdent <* symbol ">"))
    _ <- symbol "{"
    fields <- commaSep pRecordPatField
    (sp1, _) <- withSpan (symbol "}")
    pure (PRecord (sp0 <-> sp1) qname tyVars fields)

pRecordPatField :: Parser (Name, Pat SrcSpan)
pRecordPatField = do
    name <- pIdent
    _ <- symbol "="
    pat <- pPat
    pure (name, pat)

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

-- | Postfix: indexing, function call.
pExprPostfix :: Parser (Expr SrcSpan)
pExprPostfix = do
    base <- pExprAtom
    postfixes base
  where
    postfixes e = (postfix e >>= postfixes) <|> pure e

    postfix e = choice
        [ -- [index]
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
    , pExprContinue
    , pExprBreak
    , pExprFn
    , pExprTemplateLit
    , pExprArray
    , pExprConstruct
    , pExprBlock
    , pExprParens
    , pExprReturn
    , pExprVar
    ]

pExprLit :: Parser (Expr SrcSpan)
pExprLit = do
    (sp, lit) <- withSpan pLiteral
    pure (ELit sp lit)

-- | Variable reference, possibly qualified: @name@, @module.name@.
pExprVar :: Parser (Expr SrcSpan)
pExprVar = do
    sp0 <- curSpan
    qn  <- pQualName
    sp1 <- curSpan
    pure (EVar (sp0 <-> sp1) qn)

-- | @if cond { stmts } [else { stmts } | else if ...]@
pExprIf :: Parser (Expr SrcSpan)
pExprIf = do
    (sp0, _) <- withSpan (keyword "if")
    cond <- pExpr
    thn <- pBlock
    els <- optional (keyword "else" *> (pExprIf <|> pBlock))
    sp1 <- curSpan
    pure (EIf (sp0 <-> sp1) cond thn els)

-- | @match expr { case pat [if guard] => expr, ... }@
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
    pat <- pMatchPat
    guard' <- optional (keyword "if" *> pExpr)
    _ <- symbol "=>"
    body <- pExpr
    pOptSep
    pure (MatchArm sp pat guard' body)

-- | Parse a pattern in a match arm.
pMatchPat :: Parser (Pat SrcSpan)
pMatchPat = pParenthesizedPat <|> pPat

-- | Parenthesized pattern: @(pat)@
pParenthesizedPat :: Parser (Pat SrcSpan)
pParenthesizedPat = try $ do
    _ <- symbol "("
    pat <- pPat
    _ <- symbol ")"
    pure pat

-- | @handle { body } with { [var x: T = e;] [case Eff\<T\>(p) => expr;] [return x => expr] }@
pExprHandle :: Parser (Expr SrcSpan)
pExprHandle = do
    (sp0, _) <- withSpan (keyword "handle")
    body  <- pBlock
    _ <- keyword "with"
    _ <- symbol "{"
    hvars <- many (try pHandleVar)
    cases <- many (try pHandleCase)
    ret   <- optional pHandleReturn
    (sp1, _) <- withSpan (symbol "}")
    pure (EHandle (sp0 <-> sp1) body hvars cases ret)

-- | Handler variable declaration: @var name[: Type] = expr;@
pHandleVar :: Parser (HandleVar SrcSpan)
pHandleVar = do
    (sp, _) <- withSpan (keyword "var")
    name <- pIdent
    ty   <- optional (symbol ":" *> pTyExpr)
    _ <- symbol "="
    val <- pExpr
    pSep
    pure (HandleVar sp name ty val)

-- | Handler case: @case Eff[\<T\>](p1, p2) => expr@
pHandleCase :: Parser (HandleCase SrcSpan)
pHandleCase = do
    (sp, _) <- withSpan (keyword "case")
    effName <- pQualConName
    tyVars  <- option [] (try (symbol "<" *> commaSep1 pIdent <* symbol ">"))
    _ <- symbol "("
    params <- commaSep pPat
    _ <- symbol ")"
    _ <- symbol "=>"
    body <- pExpr
    pOptSep
    pure (HandleCase sp effName tyVars params body)

pHandleReturn :: Parser (HandleReturn SrcSpan)
pHandleReturn = do
    (sp, _) <- withSpan (keyword "return")
    name <- pLowerIdent
    _ <- symbol "=>"
    body <- pExpr
    pOptSep
    pure (HandleReturn sp name body)

-- | @continue expr [with { name = expr; ... }]@
pExprContinue :: Parser (Expr SrcSpan)
pExprContinue = do
    (sp0, _) <- withSpan (keyword "continue")
    arg <- pExpr
    mUpdates <- optional $ do
        _ <- keyword "with"
        _ <- symbol "{"
        updates <- many pHandleVarUpdate
        _ <- symbol "}"
        pure updates
    sp1 <- curSpan
    pure (EContinue (sp0 <-> sp1) arg mUpdates)

-- | A single handler variable update: @name = expr;@
pHandleVarUpdate :: Parser (Name, Expr SrcSpan)
pHandleVarUpdate = do
    name <- pIdent
    _ <- symbol "="
    val <- pExpr
    pSep
    pure (name, val)

-- | @break expr@
pExprBreak :: Parser (Expr SrcSpan)
pExprBreak = do
    (sp0, _) <- withSpan (keyword "break")
    arg <- pExpr
    sp1 <- curSpan
    pure (EBreak (sp0 <-> sp1) arg)

-- | Anonymous function: @fn \<T\>(x: A) -> B with E { body }@
pExprFn :: Parser (Expr SrcSpan)
pExprFn = do
    (sp0, _) <- withSpan (keyword "fn")
    tyParams <- fromMaybe [] <$> optional pTypeParams
    _ <- symbol "("
    params <- commaSep pParam
    _ <- symbol ")"
    retTy <- optional (symbol "->" *> pTyExpr)
    effTy <- optional (keyword "with" *> pEffectExpr)
    body  <- pFnBody
    sp1   <- curSpan
    pure (EFn (sp0 <-> sp1) tyParams params retTy effTy body)

-- | Function body: always a block @{ stmts }@.
pFnBody :: Parser (FnBody SrcSpan)
pFnBody = do
    (sp, _) <- withSpan (symbol "{")
    stmts <- pStmts
    _ <- symbol "}"
    pure (FnBlock sp stmts)

-- | Parse a block: @{ stmt; stmt; ... }@ — always interpreted as a block.
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

-- | Record construction: @Name { field1 = expr1 }@ or @mod.Name { ... }@
pExprConstruct :: Parser (Expr SrcSpan)
pExprConstruct = try $ do
    sp0   <- curSpan
    qname <- pQualConName
    _ <- symbol "{"
    fields <- commaSep pConstructField
    (sp1, _) <- withSpan (symbol "}")
    pure (EConstruct (sp0 <-> sp1) qname fields)

pConstructField :: Parser (Name, Expr SrcSpan)
pConstructField = do
    name <- pIdent
    _ <- symbol "="
    val <- pExpr
    pure (name, val)

-- | Block expression: @{ stmt; stmt; ... }@
pExprBlock :: Parser (Expr SrcSpan)
pExprBlock = do
    (sp0, _) <- withSpan (symbol "{")
    stmts <- pStmts
    (sp1, _) <- withSpan (symbol "}")
    pure (EBlock (sp0 <-> sp1) stmts)

-- | Parenthesized expression: @(expr)@.
pExprParens :: Parser (Expr SrcSpan)
pExprParens = do
    _ <- symbol "("
    e <- pExpr
    _ <- symbol ")"
    pure e

-- | @return [expr]@
pExprReturn :: Parser (Expr SrcSpan)
pExprReturn = do
    (sp0, _) <- withSpan (keyword "return")
    val <- optional (try pExpr)
    sp1 <- curSpan
    pure (EReturn (sp0 <-> sp1) val)

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
    [ try pDeclFn
    , try pDeclLet
    , pDeclType
    , try pDeclData
    , try pDeclEffect
    , try pDeclImport
    , try pDeclExport
    , try pDeclForeignFn
    , try pDeclTrait
    , try pDeclImpl
    , pDeclDerive
    ]

-- | @[pub] let name\<T\>: Type = expr@
pDeclLet :: Parser (Decl SrcSpan)
pDeclLet = do
    sp0    <- curSpan
    isPub  <- option False (True <$ keyword "pub")
    _      <- keyword "let"
    target <- pLetTarget
    tyParams <- fromMaybe [] <$> optional pTypeParams
    tyAnn  <- optional (symbol ":" *> pTyExpr)
    _ <- symbol "="
    val <- pExpr
    pure (DeclLet sp0 isPub target tyParams tyAnn val)

pLetTarget :: Parser (LetTarget SrcSpan)
pLetTarget = (LetPat <$> try pPatDestructure) <|> (LetName <$> pIdent)

-- | Destructuring patterns that are unambiguous (record/array).
pPatDestructure :: Parser (Pat SrcSpan)
pPatDestructure = pPatRecord <|> pPatArray

-- | @[pub] fn name\<T\>[Trait\<T\>](params) -> RetTy with E { body }@
pDeclFn :: Parser (Decl SrcSpan)
pDeclFn = do
    sp0         <- curSpan
    isPub       <- option False (True <$ keyword "pub")
    _           <- keyword "fn"
    name        <- pIdent
    tyParams    <- fromMaybe [] <$> optional pTypeParams
    traitAnnots <- pTraitAnnots
    _           <- symbol "("
    params      <- commaSep pParam
    _           <- symbol ")"
    retTy       <- optional (symbol "->" *> pTyExpr)
    effTy       <- optional (keyword "with" *> pEffectExpr)
    body        <- pFnBody
    pure (DeclFn sp0 isPub name tyParams traitAnnots params retTy effTy body)

-- | @type Name\<T\> = TyExpr@
pDeclType :: Parser (Decl SrcSpan)
pDeclType = do
    (sp, _) <- withSpan (keyword "type")
    name <- pIdent
    tyParams <- fromMaybe [] <$> optional pTypeParams
    _ <- symbol "="
    ty <- pTyExpr
    pure (DeclType sp name tyParams ty)

-- | @[pub] data Name\<out T\> { field: T, ... }@  (record syntax)
-- or @[pub] data Name\<out T\>(field: T, ...)@     (tuple syntax)
pDeclData :: Parser (Decl SrcSpan)
pDeclData = do
    sp0     <- curSpan
    isPub   <- option False (True <$ keyword "pub")
    _       <- keyword "data"
    name    <- pConName
    dtParams <- fromMaybe [] <$> optional pDataTypeParams
    (kind, fields) <- pDataBody
    pure (DeclData sp0 isPub name dtParams kind fields)

-- | Parse the body of a data declaration.
pDataBody :: Parser (DataDeclKind, [(Name, TyExpr SrcSpan)])
pDataBody = pDataBodyRecord <|> pDataBodyTuple

pDataBodyRecord :: Parser (DataDeclKind, [(Name, TyExpr SrcSpan)])
pDataBodyRecord = do
    _ <- symbol "{"
    fields <- commaSep pFieldDecl
    _ <- symbol "}"
    pure (DeclRecord, fields)

pDataBodyTuple :: Parser (DataDeclKind, [(Name, TyExpr SrcSpan)])
pDataBodyTuple = do
    _ <- symbol "("
    fields <- commaSep pFieldDecl
    _ <- symbol ")"
    pure (DeclTuple, fields)

-- | @[pub] effect Name\<out T\>(field: T) -> RetTy@
pDeclEffect :: Parser (Decl SrcSpan)
pDeclEffect = do
    sp0     <- curSpan
    isPub   <- option False (True <$ keyword "pub")
    _       <- keyword "effect"
    name    <- pConName
    dtParams <- fromMaybe [] <$> optional pDataTypeParams
    _ <- symbol "("
    fields <- commaSep pFieldDecl
    _ <- symbol ")"
    _ <- symbol "->"
    retTy <- pTyExpr
    pure (DeclEffect sp0 isPub name dtParams fields retTy)

-- | @import "path.to.module" [as alias]@
-- or @import { name1, name2 } from "path.to.module"@
pDeclImport :: Parser (Decl SrcSpan)
pDeclImport = do
    (sp, _) <- withSpan (keyword "import")
    choice
        [ -- import { names } from "path"
          try $ do
            _ <- symbol "{"
            items <- commaSep pIdent
            _ <- symbol "}"
            _ <- keyword "from"
            mname <- pModuleNameStr
            pure (DeclImport sp mname Nothing (Just items))
        , -- import "path" [as alias]
          do
            mname <- pModuleNameStr
            alias <- optional (keyword "as" *> pIdent)
            pure (DeclImport sp mname alias Nothing)
        ]

-- | @export "path.to.module"@
-- or @export { name1, name2 } from "path.to.module"@
pDeclExport :: Parser (Decl SrcSpan)
pDeclExport = do
    (sp, _) <- withSpan (keyword "export")
    choice
        [ -- export { names } from "path"
          try $ do
            _ <- symbol "{"
            items <- commaSep pIdent
            _ <- symbol "}"
            _ <- keyword "from"
            mname <- pModuleNameStr
            pure (DeclExport sp mname (Just items))
        , -- export "path"
          do
            mname <- pModuleNameStr
            pure (DeclExport sp mname Nothing)
        ]

-- | @foreign fn name(params) -> RetTy [with Effect]@
pDeclForeignFn :: Parser (Decl SrcSpan)
pDeclForeignFn = do
    (sp, _) <- withSpan (keyword "foreign")
    _ <- keyword "fn"
    name   <- pIdent
    _ <- symbol "("
    params <- commaSep pParam
    _ <- symbol ")"
    _ <- symbol "->"
    retTy  <- pTyExpr
    effTy  <- optional (keyword "with" *> pEffectExpr)
    pure (DeclForeignFn sp name params retTy effTy)

-- | @trait Name\<out T\>(params) -> RetTy@
pDeclTrait :: Parser (Decl SrcSpan)
pDeclTrait = do
    (sp, _) <- withSpan (keyword "trait")
    name    <- pConName
    dtParams <- fromMaybe [] <$> optional pDataTypeParams
    _ <- symbol "("
    params <- commaSep pParam
    _ <- symbol ")"
    _ <- symbol "->"
    retTy  <- pTyExpr
    pure (DeclTrait sp name dtParams params retTy)

-- | @impl fn_name as TraitName[\<TypeA, TypeB\>]@
pDeclImpl :: Parser (Decl SrcSpan)
pDeclImpl = do
    (sp, _) <- withSpan (keyword "impl")
    fnName    <- pIdent
    _ <- keyword "as"
    traitName <- pQualConName
    tyArgs    <- option [] (symbol "<" *> commaSep1 pTyExpr <* symbol ">")
    pure (DeclImpl sp fnName traitName tyArgs)

-- | @derive TraitName[\<Type\>]@
pDeclDerive :: Parser (Decl SrcSpan)
pDeclDerive = do
    (sp, _) <- withSpan (keyword "derive")
    traitName <- pQualConName
    tyArgs    <- option [] (symbol "<" *> commaSep1 pTyExpr <* symbol ">")
    pure (DeclDerive sp traitName tyArgs)

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

-- | Trait annotations for function declarations: @[Trait1\<T\>, Trait2\<T\>]@
pTraitAnnots :: Parser [(QualifiedName, [TyExpr SrcSpan])]
pTraitAnnots = option [] (symbol "[" *> commaSep1 pTraitAnnot <* symbol "]")

pTraitAnnot :: Parser (QualifiedName, [TyExpr SrcSpan])
pTraitAnnot = do
    qname  <- pQualConName
    tyArgs <- option [] (symbol "<" *> commaSep1 pTyExpr <* symbol ">")
    pure (qname, tyArgs)

-- | Extract span from an expression.
exprSpan :: Expr SrcSpan -> SrcSpan
exprSpan = \case
    EVar sp _           -> sp
    ELit sp _           -> sp
    EApp sp _ _ _       -> sp
    EFn sp _ _ _ _ _    -> sp
    EMatch sp _ _       -> sp
    EIf sp _ _ _        -> sp
    EBlock sp _         -> sp
    EHandle sp _ _ _ _  -> sp
    EConstruct sp _ _   -> sp
    EArray sp _         -> sp
    EIndex sp _ _       -> sp
    EReturn sp _        -> sp
    ETemplateLit sp _   -> sp
    EBinOp sp _ _ _     -> sp
    EUnaryOp sp _ _     -> sp
    EContinue sp _ _    -> sp
    EBreak sp _         -> sp
