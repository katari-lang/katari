module QataliCompiler.SrcLoc (
    SrcPos (..),
    SrcSpan (..),
    Located (..),
    noSpan,
    spanFrom,
    (<->),
) where

-- | 1-indexed line and column position in a source file.
data SrcPos = SrcPos
    { line :: {-# UNPACK #-} !Int
    , col  :: {-# UNPACK #-} !Int
    }
    deriving (Eq, Ord, Show)

-- | A range in a source file, used for error reporting.
data SrcSpan
    = SrcSpan
        { file  :: !FilePath
        , start :: !SrcPos
        , end   :: !SrcPos
        }
    | NoSpan
    deriving (Eq, Ord, Show)

-- | A value paired with its source location.
data Located a = Located
    { loc   :: !SrcSpan
    , unLoc :: a
    }
    deriving (Eq, Ord, Show, Functor, Foldable, Traversable)

noSpan :: SrcSpan
noSpan = NoSpan

-- | Span covering from the start of one span to the end of another.
spanFrom :: SrcSpan -> SrcSpan -> SrcSpan
spanFrom left right =
    case (left, right) of
        (SrcSpan f s _, SrcSpan _ _ e) -> SrcSpan f s e
        (l, _)                         -> l

-- | Infix alias for 'spanFrom'.
(<->) :: SrcSpan -> SrcSpan -> SrcSpan
(<->) = spanFrom

infixl 6 <->
