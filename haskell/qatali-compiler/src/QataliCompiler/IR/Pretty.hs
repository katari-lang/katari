-- | Pretty printing for Qatali IR.
module QataliCompiler.IR.Pretty (
    prettyModule,
    prettyDef,
    prettyExpr,
) where

import           Data.List.NonEmpty   (toList)
import           Prettyprinter
import           QataliCompiler.IR.IR
import           QataliCompiler.Name  (ModuleName (..), Name (..))

prettyModule :: IRModule -> Doc ann
prettyModule m =
    vsep
        [ "module" <+> prettyModName m.irModName
        , mempty
        , vsep (map prettyDef m.irDefs)
        ]

prettyModName :: ModuleName -> Doc ann
prettyModName (ModuleName segs) = hcat (punctuate "." (map pretty (toList segs)))

prettyDef :: IRDef -> Doc ann
prettyDef = \case
    IRDefVal n ty body ->
        pretty (unName n)
            <+> ":"
            <+> prettyTy ty
            <+> "="
            <> hardline
            <> indent 2 (prettyExpr body)
    IRDefExtern n ty ->
        "extern" <+> pretty (unName n) <+> ":" <+> prettyTy ty

prettyExpr :: IRExpr -> Doc ann
prettyExpr = \case
    IRLet n val rest ->
        "let"
            <+> pretty (unName n)
            <+> "="
            <+> prettyValue val
            <> hardline
            <> prettyExpr rest
    IRTail atom ->
        prettyAtom atom
    IRCase scrut branches mDefault ->
        "case"
            <+> prettyAtom scrut
            <+> "of"
            <> hardline
            <> indent 2 (vsep (map prettyBranch branches))
            <> maybe mempty (\d -> hardline <> indent 2 ("_ ->" <+> prettyExpr d)) mDefault

prettyValue :: IRValue -> Doc ann
prettyValue = \case
    IRAtomV a -> prettyAtom a
    IROp op args -> pretty (show op) <+> hsep (map prettyAtom args)
    IRCall f args -> prettyAtom f <> tupled (map prettyAtom args)
    IRClosure n caps -> "closure" <+> pretty (unName n) <+> list (map prettyAtom caps)
    IRAlloc ty -> "alloc" <+> prettyTy ty

prettyAtom :: IRAtom -> Doc ann
prettyAtom = \case
    IRVar n -> pretty (unName n)
    IRInt i -> pretty i
    IRFlt f -> pretty f
    IRStr s -> dquotes (pretty s)
    IRBool b -> if b then "true" else "false"
    IRUnit -> "()"

prettyBranch :: IRBranch -> Doc ann
prettyBranch br =
    pretty br.branchTag
        <+> hsep (map (pretty . unName) br.branchVars)
        <+> "->"
        <+> prettyExpr br.branchBody

prettyTy :: IRType -> Doc ann
prettyTy = \case
    IRTInt -> "Int"
    IRTFloat -> "Float"
    IRTString -> "String"
    IRTBool -> "Bool"
    IRTUnit -> "()"
    IRTFun as r -> tupled (map prettyTy as) <+> "->" <+> prettyTy r
    IRTRef n -> pretty n
    IRTAny -> "Any"
