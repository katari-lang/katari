{- | Literal values in the Qatali source language. -}
module QataliCompiler.Syntax.Literal (
    Literal (..),
) where

import           Data.Text (Text)

-- | Literal values.
data Literal
    = LitInteger !Integer     -- ^ e.g. @42@, @0xFF@
    | LitNumber  !Double      -- ^ e.g. @3.14@
    | LitString  !Text        -- ^ e.g. @"hello"@
    | LitBoolean !Bool        -- ^ @true@ / @false@
    | LitNull                 -- ^ @null@
    deriving (Eq, Ord, Show)
