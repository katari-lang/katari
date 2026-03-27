{- | Token definitions for the Qatali lexer.

TODO: Phase 3 — full rewrite for new syntax.
-}
module QataliCompiler.Parse.Lexer (
    Token (..),
    TokKeyword (..),
    TokPunct (..),
    tokenize,
) where

import           Data.Text                     (Text)
import qualified Data.Text                     as T
import           Data.Void                     (Void)
import           Text.Megaparsec               hiding (Token)
import           Text.Megaparsec.Char
import qualified Text.Megaparsec.Char.Lexer    as L

import           QataliCompiler.Syntax.Literal (Literal (..))

type Lexer = Parsec Void Text

-- | Keywords of the Qatali language.
data TokKeyword
    = KwLet
    | KwFn
    | KwIf
    | KwElse
    | KwMatch
    | KwCase
    | KwReturn
    | KwHandle
    | KwContinue
    | KwEffect
    | KwData
    | KwType
    | KwImport
    | KwAs
    | KwModule
    | KwSub
    | KwSup
    | KwIs
    | KwIn
    | KwOut
    | KwWith
    | KwNull
    | KwTrue
    | KwFalse
    | KwPure
    | KwImpure
    deriving (Eq, Ord, Show)

-- | Punctuation / operator tokens.
data TokPunct
    = PtLParen
    | PtRParen
    | PtLBrace
    | PtRBrace
    | PtLBracket
    | PtRBracket
    | PtComma
    | PtSemicolon
    | PtColon
    | PtDot
    | PtEllipsis      -- ...
    | PtFatArrow      -- =>
    | PtEquals         -- =
    | PtPipe           -- |
    | PtAmpersand      -- &
    | PtLAngle         -- <
    | PtRAngle         -- >
    | PtUnderscore     -- _
    | PtPlus
    | PtMinus
    | PtStar
    | PtSlash
    | PtPercent
    | PtPlusPlus       -- ++
    | PtEqEq           -- ==
    | PtNeq            -- !=
    | PtLe             -- <=
    | PtGe             -- >=
    | PtAmpAmp         -- &&
    | PtPipePipe       -- ||
    | PtBang           -- !
    | PtDollarBrace    -- ${
    | PtBacktick       -- `
    deriving (Eq, Ord, Show)

-- | A single lexeme.
data Token
    = TokKw !TokKeyword
    | TokPunct !TokPunct
    | TokIdent !Text
    | TokCon !Text
    | TokLit !Literal
    | TokEOF
    deriving (Eq, Ord, Show)

{- | Tokenize a source file into a list of tokens.
TODO: Phase 3 — implement fully.
-}
tokenize :: FilePath -> Text -> Either (ParseErrorBundle Text Void) [Token]
tokenize fp src = parse (many lexToken <* eof) fp src

-- ---------------------------------------------------------------------------
-- Internals (stub — Phase 3 will rewrite)

sc :: Lexer ()
sc = L.space space1 (L.skipLineComment "//") (L.skipBlockComment "/*" "*/")

lexeme :: Lexer a -> Lexer a
lexeme = L.lexeme sc

symbol :: Text -> Lexer Text
symbol = L.symbol sc

lexToken :: Lexer Token
lexToken =
    sc
        *> choice
            [ TokPunct PtLParen <$ symbol "("
            , TokPunct PtRParen <$ symbol ")"
            , TokPunct PtLBrace <$ symbol "{"
            , TokPunct PtRBrace <$ symbol "}"
            , TokPunct PtLBracket <$ symbol "["
            , TokPunct PtRBracket <$ symbol "]"
            , TokPunct PtComma <$ symbol ","
            , TokPunct PtSemicolon <$ symbol ";"
            , TokPunct PtFatArrow <$ symbol "=>"
            , TokPunct PtColon <$ symbol ":"
            , TokPunct PtEllipsis <$ symbol "..."
            , TokPunct PtDot <$ symbol "."
            , TokPunct PtEquals <$ symbol "="
            , TokPunct PtPipe <$ symbol "|"
            , TokPunct PtAmpersand <$ symbol "&"
            , TokPunct PtUnderscore <$ symbol "_"
            , TokLit . LitNumber <$> lexeme (try L.float)
            , TokLit . LitInteger <$> lexeme L.decimal
            , TokLit . LitString <$> lexString
            , lexIdent
            ]

lexIdent :: Lexer Token
lexIdent = lexeme $ do
    first <- letterChar <|> char '_'
    rest <- many (alphaNumChar <|> char '_' <|> char '\'')
    let word = T.pack (first : rest)
    pure $ case word of
        "let"      -> TokKw KwLet
        "fn"       -> TokKw KwFn
        "if"       -> TokKw KwIf
        "else"     -> TokKw KwElse
        "match"    -> TokKw KwMatch
        "case"     -> TokKw KwCase
        "return"   -> TokKw KwReturn
        "handle"   -> TokKw KwHandle
        "continue" -> TokKw KwContinue
        "effect"   -> TokKw KwEffect
        "data"     -> TokKw KwData
        "type"     -> TokKw KwType
        "import"   -> TokKw KwImport
        "as"       -> TokKw KwAs
        "module"   -> TokKw KwModule
        "sub"      -> TokKw KwSub
        "sup"      -> TokKw KwSup
        "is"       -> TokKw KwIs
        "in"       -> TokKw KwIn
        "out"      -> TokKw KwOut
        "with"     -> TokKw KwWith
        "null"     -> TokLit LitNull
        "true"     -> TokLit (LitBoolean True)
        "false"    -> TokLit (LitBoolean False)
        "pure"     -> TokKw KwPure
        "impure"   -> TokKw KwImpure
        _
            | isUpper' (T.head word) -> TokCon word
            | otherwise -> TokIdent word
  where
    isUpper' c = c >= 'A' && c <= 'Z'

lexString :: Lexer Text
lexString = lexeme $ do
    _ <- char '"'
    T.pack <$> manyTill L.charLiteral (char '"')
