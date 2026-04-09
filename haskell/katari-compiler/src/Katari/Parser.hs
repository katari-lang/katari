{-# LANGUAGE TypeFamilies #-}

module Katari.Parser
  ( ParseError,
    parseModule,
  )
where

import Control.Monad.Combinators.Expr
import Data.List.NonEmpty qualified as NE
import Data.Maybe (catMaybes, fromMaybe, isJust)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Void (Void)
import Katari.Lexer (FStrPart (..), TokKind (..), Token (..))
import Katari.Syntax
import Text.Megaparsec hiding (ParseError, Token)
import Text.Megaparsec qualified as MP
import Text.Megaparsec.Pos (SourcePos (..), mkPos)

-- ---------------------------------------------------------------------------
-- Token stream for megaparsec
-- ---------------------------------------------------------------------------

newtype TokenStream = TS {unTS :: [Token]}
  deriving (Show, Eq)

instance Stream TokenStream where
  type Token TokenStream = Token
  type Tokens TokenStream = [Token]
  tokenToChunk _ x = [x]
  tokensToChunk _ xs = xs
  chunkToTokens _ = id
  chunkLength _ xs = length xs
  chunkEmpty _ xs = null xs
  take1_ (TS []) = Nothing
  take1_ (TS (x : xs)) = Just (x, TS xs)
  takeN_ n (TS s)
    | n <= 0 = Just ([], TS s)
    | null s = Nothing
    | otherwise = let (pre, post) = splitAt n s in Just (pre, TS post)
  takeWhile_ f (TS s) = let (pre, post) = span f s in (pre, TS post)

instance VisualStream TokenStream where
  showTokens _ ts = unwords (map showTok (NE.toList ts))
    where
      showTok t = show (tokKind t)

instance TraversableStream TokenStream where
  reachOffset o pstate@PosState {..} =
    let n = max 0 (o - pstateOffset)
        toks = unTS pstateInput
        toks' = drop n toks
        newSP = case toks' of
          [] -> pstateSourcePos
          (t : _) ->
            pstateSourcePos
              { sourceLine = mkPos (tokLine t),
                sourceColumn = mkPos (tokCol t)
              }
     in ( Nothing,
          PosState
            { pstateInput = TS toks',
              pstateOffset = o,
              pstateSourcePos = newSP,
              pstateTabWidth = pstateTabWidth,
              pstateLinePrefix = pstateLinePrefix
            }
        )

-- ---------------------------------------------------------------------------
-- Parser type and helpers
-- ---------------------------------------------------------------------------

type ParseError = MP.ParseErrorBundle TokenStream Void

type Parser = Parsec Void TokenStream

-- Context for break disambiguation
data BreakCtx = BreakForCtx | BreakHandleCtx deriving (Eq)

tok :: TokKind -> Parser Token
tok k = satisfy (\t -> tokKind t == k) <?> show k

tok_ :: TokKind -> Parser ()
tok_ k = () <$ tok k

semi :: Parser ()
semi = tok_ TKSemi

optSemi :: Parser ()
optSemi = optional (tok_ TKSemi) >> pure ()

ident :: Parser Text
ident = do
  t <- satisfy isIdent <?> "identifier"
  case tokKind t of
    TKIdent n -> return n
    _ -> fail "expected identifier"
  where
    isIdent t = case tokKind t of TKIdent _ -> True; _ -> False

-- "uniq" is a contextual keyword (just an identifier)
uniqKw :: Parser ()
uniqKw = () <$ satisfy (\t -> tokKind t == TKIdent "uniq") <?> "uniq"

annot :: Parser (Maybe Text)
annot = optional $ do
  tok_ TKAt
  t <- satisfy isStr <?> "string"
  case tokKind t of
    TKStr s -> return s
    _ -> fail "expected string annotation"
  where
    isStr t = case tokKind t of TKStr _ -> True; _ -> False

spanOf :: Token -> SrcSpan
spanOf t = SrcSpan "<source>" (tokLine t) (tokCol t)

currentSpan :: Parser SrcSpan
currentSpan = do
  mt <- optional (lookAhead (satisfy (const True)))
  return $ case mt of
    Just t -> spanOf t
    Nothing -> noSpan

-- Comma-separated list (trailing comma allowed)
commaSep :: Parser a -> Parser [a]
commaSep p = do
  first <- optional p
  case first of
    Nothing -> return []
    Just x -> do
      rest <- many (tok_ TKComma *> p)
      optional (tok_ TKComma)
      return (x : rest)

-- Comma or semicolon separated list
commaOrSemiSep :: Parser a -> Parser [a]
commaOrSemiSep p = do
  first <- optional p
  case first of
    Nothing -> return []
    Just x -> do
      rest <- many (sep *> p)
      optional sep
      return (x : rest)
  where
    sep = tok_ TKComma <|> tok_ TKSemi

-- ---------------------------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------------------------

parseModule :: FilePath -> [Token] -> Either ParseError Module
parseModule fp toks =
  let initPos = SourcePos fp (mkPos 1) (mkPos 1)
      initState =
        PosState
          { pstateInput = TS toks,
            pstateOffset = 0,
            pstateSourcePos = initPos,
            pstateTabWidth = mkPos 8,
            pstateLinePrefix = ""
          }
   in MP.runParser pModule fp (TS toks)

pModule :: Parser Module
pModule = do
  ds <- many pDecl
  _ <- tok_ TKEof
  return (Module "<source>" ds)

-- ---------------------------------------------------------------------------
-- Declarations
-- ---------------------------------------------------------------------------

pDecl :: Parser Decl
pDecl = do
  sp <- currentSpan
  choice
    [ pImportDecl sp,
      pValDecl sp,
      pTaskDecl sp,
      pRequestDecl sp,
      pExternalDecl sp,
      pTypeDecl sp
    ]

pImportDecl :: SrcSpan -> Parser Decl
pImportDecl sp = do
  tok_ TKImport
  path <- pModulePath
  alias <- optional (tok_ TKAs *> ident)
  names <- optional (between (tok_ TKLBrace) (tok_ TKRBrace) (commaSep ident))
  optSemi
  return $ DeclImport sp (ImportDecl path alias names)

pModulePath :: Parser [Text]
pModulePath = do
  first <- ident
  rest <- many (tok_ TKDot *> ident)
  return (first : rest)

pValDecl :: SrcSpan -> Parser Decl
pValDecl sp = do
  a <- annot
  tok_ TKVal
  name <- ident
  ty <- optional (tok_ TKColon *> pType)
  tok_ TKEq
  e <- pExpr BreakHandleCtx
  optSemi
  let vty = fromMaybe TUnknown ty
  return $ DeclVal sp (ValDecl a name vty e)

pTaskDecl :: SrcSpan -> Parser Decl
pTaskDecl sp = do
  a <- annot
  tok_ TKTask
  name <- ident
  ps <- between (tok_ TKLParen) (tok_ TKRParen) pParams
  ret <- optional (tok_ TKArrow *> pType)
  eff <- optional (tok_ TKWith *> pRequestEffect)
  body <- pBlock BreakHandleCtx
  optSemi
  return $ DeclTask sp (TaskDecl a name ps ret eff body)

pRequestDecl :: SrcSpan -> Parser Decl
pRequestDecl sp = do
  a <- annot
  tok_ TKRequest
  name <- ident
  ps <- between (tok_ TKLParen) (tok_ TKRParen) pParams
  tok_ TKArrow
  ret <- pType
  optSemi
  return $ DeclRequest sp (RequestDecl a name ps ret)

pExternalDecl :: SrcSpan -> Parser Decl
pExternalDecl sp = do
  a <- annot
  tok_ TKExternal
  choice
    [ pExtTaskDecl sp a,
      pExtReqDecl sp a
    ]

pExtTaskDecl :: SrcSpan -> Maybe Text -> Parser Decl
pExtTaskDecl sp a = do
  tok_ TKTask
  name <- ident
  ps <- between (tok_ TKLParen) (tok_ TKRParen) pParams
  tok_ TKArrow
  ret <- pType
  eff <- optional (tok_ TKWith *> pRequestEffect)
  tok_ TKFrom
  src <- pStrLit
  optSemi
  return $ DeclExtTask sp (ExternalTaskDecl a name ps (Just ret) eff src)

pExtReqDecl :: SrcSpan -> Maybe Text -> Parser Decl
pExtReqDecl sp a = do
  tok_ TKRequest
  name <- ident
  ps <- between (tok_ TKLParen) (tok_ TKRParen) pParams
  tok_ TKArrow
  ret <- pType
  tok_ TKFrom
  src <- pStrLit
  optSemi
  return $ DeclExtReq sp (ExternalReqDecl a name ps ret src)

pTypeDecl :: SrcSpan -> Parser Decl
pTypeDecl sp = do
  tok_ TKType
  name <- ident
  tok_ TKEq
  ty <- pType
  optSemi
  return $ DeclType sp (TypeAliasDecl name ty)

pParams :: Parser [(Text, Type)]
pParams = commaSep pParam
  where
    pParam = do
      n <- ident
      tok_ TKColon
      ty <- pType
      _ <- annot -- optional annotation on param
      return (n, ty)

pRequestEffect :: Parser RequestEffect
pRequestEffect =
  (tok_ TKTask >> return RETask) <|> do
    first <- ident
    rest <- many (tok_ TKPipe *> ident)
    return (RENames (first : rest))

pStrLit :: Parser Text
pStrLit = do
  t <- satisfy isStr <?> "string literal"
  case tokKind t of
    TKStr s -> return s
    _ -> fail "expected string"
  where
    isStr t = case tokKind t of TKStr _ -> True; _ -> False

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

pType :: Parser Type
pType = pUnionType

pUnionType :: Parser Type
pUnionType = do
  first <- pIntersectType
  rest <- many (tok_ TKPipe *> pIntersectType)
  return $ case rest of
    [] -> first
    _ -> TUnion (first : rest)

pIntersectType :: Parser Type
pIntersectType = do
  first <- pPrimaryType
  rest <- many (tok_ TKAmp *> pPrimaryType)
  return $ case rest of
    [] -> first
    _ -> TInter (first : rest)

pPrimaryType :: Parser Type
pPrimaryType =
  choice
    [ tok_ TKNull *> pure TNull,
      tok_ (TKIdent "unknown") *> pure TUnknown,
      tok_ (TKIdent "never") *> pure TNever,
      satisfy isBool >>= \t -> case tokKind t of
        TKBool b -> return (TLitBool b)
        _ -> fail "bool",
      tok_ (TKIdent "integer") *> pure TInteger,
      tok_ (TKIdent "number") *> pure TNumber,
      tok_ (TKIdent "boolean") *> pure TBoolean,
      tok_ (TKIdent "string") *> pure TString,
      pNumLit,
      pStrLitType,
      pArrayType,
      pObjectType,
      between (tok_ TKLParen) (tok_ TKRParen) pType,
      TAlias <$> ident
    ]
  where
    isBool t = case tokKind t of TKBool _ -> True; _ -> False

pNumLit :: Parser Type
pNumLit = do
  t <- satisfy isNum <?> "number literal"
  case tokKind t of
    TKInt i -> return (TLitInt i)
    TKNum n -> return (TLitNum n)
    _ -> fail "number"
  where
    isNum t = case tokKind t of TKInt _ -> True; TKNum _ -> True; _ -> False

pStrLitType :: Parser Type
pStrLitType = TLitStr <$> pStrLit

pArrayType :: Parser Type
pArrayType = do
  tok_ (TKIdent "array")
  t <- between (tok_ TKLBracket) (tok_ TKRBracket) pType
  return (TArray t)

pObjectType :: Parser Type
pObjectType = do
  tok_ TKLBrace
  -- Empty object
  mbEmpty <- optional (tok_ TKRBrace)
  case mbEmpty of
    Just _ -> return (TObj [])
    Nothing -> do
      fields <- commaOrSemiSep pObjTypeField
      tok_ TKRBrace
      return (TObj fields)

pObjTypeField :: Parser ObjField
pObjTypeField = do
  isUniq <- isJust <$> optional uniqKw
  name <- ident
  isOpt <- isJust <$> optional (tok_ TKQuestion)
  tok_ TKColon
  ty <- pType
  _ <- annot -- optional annotation
  return (ObjField name isOpt isUniq ty)

-- ---------------------------------------------------------------------------
-- Blocks and statements
-- ---------------------------------------------------------------------------

pBlock :: BreakCtx -> Parser Block
pBlock ctx = do
  tok_ TKLBrace
  (stmts, mExpr) <- pBlockContents ctx
  tok_ TKRBrace
  let stmts' = case mExpr of
        Nothing -> stmts
        Just e -> stmts ++ [SExpr noSpan e]
  return (Block stmts')

-- Parse block contents: statements then optional final expression
pBlockContents :: BreakCtx -> Parser ([Stmt], Maybe Expr)
pBlockContents ctx = do
  -- Try to parse statements and track the last expr
  go []
  where
    go acc = do
      -- Check for closing brace
      mb <- optional (lookAhead (tok TKRBrace))
      case mb of
        Just _ -> return (acc, Nothing)
        Nothing -> do
          -- Try to parse a statement or expression
          ms <- optional (pStmtOrExpr ctx)
          case ms of
            Nothing -> return (acc, Nothing)
            Just (Left stmt) -> go (acc ++ [stmt])
            Just (Right expr) -> do
              -- If followed by semi or closing brace, this is a statement expr
              mSemi <- optional (tok_ TKSemi)
              mClose <- optional (lookAhead (tok TKRBrace))
              case mClose of
                Just _ -> return (acc, Just expr) -- final expression
                Nothing ->
                  case mSemi of
                    Just _ -> go (acc ++ [SExpr noSpan expr])
                    Nothing -> return (acc, Just expr)

pStmtOrExpr :: BreakCtx -> Parser (Either Stmt Expr)
pStmtOrExpr ctx =
  choice
    [ Left <$> pLetStmt,
      Left <$> pHandleStmt,
      Left <$> pReturnStmt,
      Left <$> pReplyStmt,
      Left <$> pNextStmt,
      Left <$> pBreakStmt ctx,
      Right <$> pExpr ctx
    ]

pLetStmt :: Parser Stmt
pLetStmt = do
  sp <- currentSpan
  tok_ TKLet
  pat <- pPat
  tok_ TKEq
  e <- pExpr BreakHandleCtx
  optSemi
  return (SLet sp pat e)

pHandleStmt :: Parser Stmt
pHandleStmt = do
  sp <- currentSpan
  tok_ TKHandle
  params <-
    option [] $
      between (tok_ TKLParen) (tok_ TKRParen) (commaSep pHandleParam)
  tok_ TKLBrace
  items <- many pHandleItem
  tok_ TKRBrace
  optSemi
  let reqs = [(n, args, body) | HReq n args body <- items]
      retCase = case [(var, body) | HRet var body <- items] of
        [] -> Nothing
        (x : _) -> Just x
  return (SHandle sp (HandleStmt params reqs retCase))

data HandleItem = HReq Text [Pat] Block | HRet Text Block

pHandleParam :: Parser (Text, Type, Expr)
pHandleParam = do
  _ <- annot
  n <- ident
  tok_ TKColon
  ty <- pType
  _ <- annot
  tok_ TKEq
  e <- pExpr BreakHandleCtx
  return (n, ty, e)

pHandleItem :: Parser HandleItem
pHandleItem =
  choice
    [ pHandleReqItem,
      pHandleRetItem
    ]

pHandleReqItem :: Parser HandleItem
pHandleReqItem = do
  tok_ TKRequest
  name <- ident
  args <- between (tok_ TKLParen) (tok_ TKRParen) (commaSep pPat)
  tok_ TKFatArrow
  body <- pBlock BreakHandleCtx
  optSemi
  return (HReq name args body)

pHandleRetItem :: Parser HandleItem
pHandleRetItem = do
  tok_ TKReturn
  var <- ident
  tok_ TKFatArrow
  body <- pBlock BreakHandleCtx
  optSemi
  return (HRet var body)

pReturnStmt :: Parser Stmt
pReturnStmt = do
  sp <- currentSpan
  tok_ TKReturn
  e <- pExpr BreakHandleCtx
  optSemi
  return (SReturn sp e)

pReplyStmt :: Parser Stmt
pReplyStmt = do
  sp <- currentSpan
  tok_ TKReply
  e <- pExpr BreakHandleCtx
  upd <- optional (tok_ TKWith *> pStateUpdate)
  optSemi
  return (SReply sp e upd)

pNextStmt :: Parser Stmt
pNextStmt = do
  sp <- currentSpan
  tok_ TKNext
  upd <- optional (tok_ TKWith *> pStateUpdate)
  optSemi
  return (SNext sp upd)

pBreakStmt :: BreakCtx -> Parser Stmt
pBreakStmt ctx = do
  sp <- currentSpan
  tok_ TKBreak
  e <- pExpr BreakHandleCtx
  optSemi
  return $ case ctx of
    BreakForCtx -> SForBreak sp e
    BreakHandleCtx -> SBreak sp e

pStateUpdate :: Parser [(Text, Expr)]
pStateUpdate = between (tok_ TKLBrace) (tok_ TKRBrace) (commaSep pUpdateField)
  where
    pUpdateField = do
      n <- ident
      tok_ TKEq
      e <- pExpr BreakHandleCtx
      return (n, e)

-- ---------------------------------------------------------------------------
-- Expressions
-- ---------------------------------------------------------------------------

pExpr :: BreakCtx -> Parser Expr
pExpr ctx =
  choice
    [ pIfExpr ctx,
      pMatchExpr ctx,
      pForExpr ctx,
      pParExpr ctx,
      pBinExpr ctx
    ]

pIfExpr :: BreakCtx -> Parser Expr
pIfExpr ctx = do
  sp <- currentSpan
  tok_ TKIf
  cond <- pBinExpr ctx
  thn <- pBlock ctx
  mEls <- optional (tok_ TKElse *> pElseBranch ctx)
  return $ EIf sp cond thn (fromMaybe (Block []) mEls)

pElseBranch :: BreakCtx -> Parser Block
pElseBranch ctx =
  choice
    [ do e <- pIfExpr ctx; return (Block [SExpr noSpan e]),
      pBlock ctx
    ]

pMatchExpr :: BreakCtx -> Parser Expr
pMatchExpr ctx = do
  sp <- currentSpan
  tok_ TKMatch
  e <- pBinExpr ctx
  tok_ TKLBrace
  arms <- many (pCaseArm ctx)
  tok_ TKRBrace
  return (EMatch sp e arms)

pCaseArm :: BreakCtx -> Parser CaseArm
pCaseArm ctx = do
  tok_ TKCase
  pat <- pPat
  tok_ TKFatArrow
  body <- pBlock ctx
  optSemi
  return (CaseArm pat body)

pForExpr :: BreakCtx -> Parser Expr
pForExpr _ctx = do
  sp <- currentSpan
  tok_ TKFor
  (lets, vars) <- between (tok_ TKLParen) (tok_ TKRParen) pForBindings
  body <- pBlock BreakForCtx
  finally <- optional (tok_ TKFinally *> pBlock BreakForCtx)
  return (EFor sp (ForExpr lets vars body finally))

pForBindings :: Parser ([(Text, Expr)], [(Text, Type, Expr)])
pForBindings = do
  -- let bindings first, then var bindings
  lets <- many pForLet
  vars <- many pForVar
  return (lets, vars)

pForLet :: Parser (Text, Expr)
pForLet = do
  tok_ TKLet
  -- simplified: just a variable name (not full pattern)
  name <- ident
  tok_ TKOf
  e <- pExpr BreakHandleCtx
  optional (tok_ TKComma)
  return (name, e)

pForVar :: Parser (Text, Type, Expr)
pForVar = do
  tok_ TKVar
  name <- ident
  ty <- option TUnknown (tok_ TKColon *> pType)
  _ <- annot
  tok_ TKEq
  e <- pExpr BreakHandleCtx
  optional (tok_ TKComma)
  return (name, ty, e)

pParExpr :: BreakCtx -> Parser Expr
pParExpr ctx = do
  sp <- currentSpan
  tok_ TKPar
  tok_ TKLBracket
  -- Empty par
  mbEmpty <- optional (tok_ TKRBracket)
  case mbEmpty of
    Just _ -> return (EPar sp [])
    Nothing -> do
      blocks <- commaSep (pParBlock ctx)
      tok_ TKRBracket
      return (EPar sp blocks)

pParBlock :: BreakCtx -> Parser Block
pParBlock ctx = do
  tok_ TKLBrace
  (stmts, mExpr) <- pBlockContents ctx
  tok_ TKRBrace
  let stmts' = case mExpr of
        Nothing -> stmts
        Just e -> stmts ++ [SExpr noSpan e]
  return (Block stmts')

-- Binary expression with operator precedence
pBinExpr :: BreakCtx -> Parser Expr
pBinExpr ctx = makeExprParser (pUnaryExpr ctx) operatorTable

operatorTable :: [[Operator Parser Expr]]
operatorTable =
  [ [ prefix TKMinus (\sp e -> EUnOp sp UnNeg e),
      prefix TKBang (\sp e -> EUnOp sp UnNot e)
    ],
    [ binL TKStar OpMul,
      binL TKSlash OpDiv
    ],
    [ binL TKPlus OpAdd,
      binL TKMinus OpSub
    ],
    [binL TKPlusPlus OpConcat],
    [ binN TKLt OpLt,
      binN TKGt OpGt,
      binN TKLe OpLe,
      binN TKGe OpGe
    ],
    [ binN TKEqEq OpEq,
      binN TKNeq OpNe
    ],
    [binL TKAmpAmp OpAnd],
    [binL TKPipePipe OpOr]
  ]
  where
    binL tk op = InfixL (do sp <- currentSpan; tok_ tk; return (\l r -> EBinOp sp op l r))
    binN tk op = InfixN (do sp <- currentSpan; tok_ tk; return (\l r -> EBinOp sp op l r))
    prefix tk f = Prefix (do sp <- currentSpan; tok_ tk; return (f sp))

pUnaryExpr :: BreakCtx -> Parser Expr
pUnaryExpr ctx = pPostfixExpr ctx

pPostfixExpr :: BreakCtx -> Parser Expr
pPostfixExpr ctx = do
  e <- pPrimaryExpr ctx
  applyPostfixes ctx e

applyPostfixes :: BreakCtx -> Expr -> Parser Expr
applyPostfixes ctx e = do
  mpost <- optional (pPostfix ctx e)
  case mpost of
    Nothing -> return e
    Just e' -> applyPostfixes ctx e'

pPostfix :: BreakCtx -> Expr -> Parser Expr
pPostfix ctx e =
  choice
    [ do
        sp <- currentSpan
        tok_ TKLParen
        args <- commaSep (pExpr ctx)
        tok_ TKRParen
        return (ECall sp e args),
      do
        sp <- currentSpan
        tok_ TKDot
        field <- ident
        return (EField sp e field),
      do
        sp <- currentSpan
        tok_ TKLBracket
        idx <- pExpr ctx
        tok_ TKRBracket
        -- Array indexing: ECall (EField e "get") [idx]? Or use EBinOp?
        -- We'll represent it as a special call
        return (ECall sp (EField sp e "__index__") [idx])
    ]

pPrimaryExpr :: BreakCtx -> Parser Expr
pPrimaryExpr ctx = do
  sp <- currentSpan
  choice
    [ pBlockExpr ctx,
      pLitExpr sp,
      pTemplExpr sp,
      pObjOrQual sp ctx,
      pArrExpr sp ctx,
      between (tok_ TKLParen) (tok_ TKRParen) (pExpr ctx)
    ]

pBlockExpr :: BreakCtx -> Parser Expr
pBlockExpr ctx = do
  sp <- currentSpan
  -- Only accept as block if it's not an object literal
  -- Look ahead to distinguish: if '{' ident '=' → object, '{}' → empty obj
  t <- lookAhead (tok TKLBrace)
  isObj <- isObjectLiteral
  if isObj
    then pObjLitExpr sp ctx
    else EBlock sp <$> pBlock ctx

isObjectLiteral :: Parser Bool
isObjectLiteral = do
  -- Look ahead: { } → obj, { ident '=' → obj, else → block
  mTokens <- optional $ lookAhead $ do
    tok_ TKLBrace
    mt <- optional (satisfy (const True))
    case mt of
      Nothing -> return True -- empty {} → could be either, but spec says empty object
      Just t2 ->
        case tokKind t2 of
          TKRBrace -> return True -- {} → empty object
          TKIdent _ -> do
            mt3 <- optional (satisfy (const True))
            case mt3 of
              Just t3 -> return (tokKind t3 == TKEq)
              Nothing -> return False
          _ -> return False
  return (fromMaybe False mTokens)

pObjLitExpr :: SrcSpan -> BreakCtx -> Parser Expr
pObjLitExpr sp ctx = do
  tok_ TKLBrace
  mbEmpty <- optional (tok_ TKRBrace)
  case mbEmpty of
    Just _ -> return (EObj sp [])
    Nothing -> do
      fields <- commaOrSemiSep (pObjField ctx)
      tok_ TKRBrace
      return (EObj sp fields)

pObjField :: BreakCtx -> Parser (Text, Expr)
pObjField ctx = do
  name <- ident
  tok_ TKEq
  e <- pExpr ctx
  return (name, e)

pLitExpr :: SrcSpan -> Parser Expr
pLitExpr sp = do
  t <- satisfy isLit <?> "literal"
  case tokKind t of
    TKNull -> return (ELit sp LNull)
    TKBool b -> return (ELit sp (LBool b))
    TKInt i -> return (ELit sp (LInt i))
    TKNum n -> return (ELit sp (LNum n))
    TKStr s -> return (ELit sp (LStr s))
    _ -> fail "literal"
  where
    isLit t = case tokKind t of
      TKNull -> True
      TKBool _ -> True
      TKInt _ -> True
      TKNum _ -> True
      TKStr _ -> True
      _ -> False

pTemplExpr :: SrcSpan -> Parser Expr
pTemplExpr sp = do
  t <- satisfy isFStr <?> "template literal"
  case tokKind t of
    TKFStr parts -> do
      elems <- mapM convertPart parts
      return (ETempl sp elems)
    _ -> fail "template"
  where
    isFStr t = case tokKind t of TKFStr _ -> True; _ -> False
    convertPart = \case
      FStrLit s -> return (TemplStr s)
      FStrExpr ts ->
        case runParser (pExpr BreakHandleCtx <* tok_ TKEof) "<template>" (TS (ts ++ [Token TKEof 1 0])) of
          Left err -> fail ("Template expression error: " ++ show err)
          Right e -> return (TemplExpr e)

pObjOrQual :: SrcSpan -> BreakCtx -> Parser Expr
pObjOrQual sp ctx = do
  name <- ident
  -- Check if this is a qualified name (a.b.c)
  rest <- many (tok_ TKDot *> ident)
  case rest of
    [] -> return (EVar sp name)
    _ -> return $ foldl (\e n -> EField sp e n) (EVar sp name) rest

pArrExpr :: SrcSpan -> BreakCtx -> Parser Expr
pArrExpr sp ctx = do
  tok_ TKLBracket
  elems <- commaSep (pExpr ctx)
  tok_ TKRBracket
  return (EArr sp elems)

-- ---------------------------------------------------------------------------
-- Patterns
-- ---------------------------------------------------------------------------

pPat :: Parser Pat
pPat =
  choice
    [ pPrimTagPat,
      pObjPat,
      pArrPat,
      pLitPat,
      pVarPat
    ]

pPrimTagPat :: Parser Pat
pPrimTagPat = do
  tag <- satisfy isTag <?> "type tag"
  let primTag = case tokKind tag of
        TKIdent "boolean" -> TagBoolean
        TKIdent "integer" -> TagInteger
        TKIdent "number" -> TagNumber
        TKIdent "string" -> TagString
        _ -> TagBoolean -- unreachable
  tok_ TKLParen
  var <- ident
  _ <- optional (tok_ TKColon *> pType)
  _ <- annot
  tok_ TKRParen
  return (PTag primTag var)
  where
    isTag t = case tokKind t of
      TKIdent s -> s `elem` ["boolean", "integer", "number", "string"]
      _ -> False

pObjPat :: Parser Pat
pObjPat = do
  tok_ TKLBrace
  mbEmpty <- optional (tok_ TKRBrace)
  case mbEmpty of
    Just _ -> return (PObj [])
    Nothing -> do
      fields <- commaOrSemiSep pObjFieldPat
      tok_ TKRBrace
      return (PObj fields)

pObjFieldPat :: Parser (Text, Bool, Pat)
pObjFieldPat = do
  isUniq_ <- isJust <$> optional uniqKw
  name <- ident
  tok_ TKEq
  pat <- pPat
  return (name, isUniq_, pat)

pArrPat :: Parser Pat
pArrPat = do
  tok_ TKLBracket
  pats <- commaSep pPat
  tok_ TKRBracket
  return (PArr pats)

pLitPat :: Parser Pat
pLitPat = do
  t <- satisfy isLitPat <?> "literal pattern"
  return $ case tokKind t of
    TKNull -> PLit LNull
    TKBool b -> PLit (LBool b)
    TKInt i -> PLit (LInt i)
    TKNum n -> PLit (LNum n)
    TKStr s -> PLit (LStr s)
    _ -> PLit LNull -- unreachable
  where
    isLitPat t = case tokKind t of
      TKNull -> True
      TKBool _ -> True
      TKInt _ -> True
      TKNum _ -> True
      TKStr _ -> True
      _ -> False

pVarPat :: Parser Pat
pVarPat = do
  name <- ident
  mty <- optional (tok_ TKColon *> pType)
  _ <- annot
  return $ case mty of
    Nothing -> PVar name
    Just ty -> PTyped name ty
