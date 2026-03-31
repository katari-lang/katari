{- | Hardcoded prim module type definitions.

The @prim@ module is always implicitly imported.
Submodules (@prim.json@, @prim.task@, etc.) are importable.
-}
module QataliCompiler.Typecheck.Prim (
    primTypeDefs,
    primInterfaces,
) where

import           Data.List.NonEmpty        (NonEmpty (..))
import qualified Data.Map.Strict           as Map
import qualified Data.Text                 as T

import           QataliCompiler.Name       (ModuleName (..), Name (..))
import           QataliCompiler.Type.Defs
import           QataliCompiler.Type.Type  -- OverloadedStrings handles this

-- =========================================================================
-- Shared type references
-- =========================================================================

-- | @Json = JsonObject | JsonArray | JsonString | JsonNumber | JsonBoolean | JsonNull@
jsonTy :: Type
jsonTy = foldr1 TUnion
    [ TData (Name "JsonObject")  []
    , TData (Name "JsonArray")   []
    , TData (Name "JsonString")  []
    , TData (Name "JsonNumber")  []
    , TData (Name "JsonBoolean") []
    , TData (Name "JsonNull")    []
    ]

-- =========================================================================
-- prim module (always imported)
-- =========================================================================

-- | @effect Throw<out T>(message: T) -> null@
throwEffDef :: EffectDef
throwEffDef = EffectDef
    { edParamNames = [Name "T"]
    , edParams     = [DataTypeParam Covariant]
    , edBounds     = [BoundNone]
    , edFields     = [(Name "message", TVar (Name "T"))]
    , edReturnTy   = TPrim PrimNull
    }

-- | @type Json = JsonObject | JsonArray | JsonString | JsonNumber | JsonBoolean | JsonNull@
jsonTypeSyn :: TypeSynDef
jsonTypeSyn = TypeSynDef
    { tsParams = []
    , tsBody   = jsonTy
    }

primTypeDefs :: TypeDefs
primTypeDefs = emptyTypeDefs
    { tdEffects = Map.fromList
        [ (Name "Throw", throwEffDef)
        ]
    , tdTypes = Map.fromList
        [ (Name "Json", jsonTypeSyn)
        ]
    }

-- =========================================================================
-- prim.json module
-- =========================================================================

jsonDataDefs :: Map.Map Name DataDef
jsonDataDefs = Map.fromList
    [ (Name "JsonObject", DataDef DataTuple [] [] [] [])
    , (Name "JsonArray",  DataDef DataTuple [] [] []
        [(Name "elems", TArray jsonTy)])
    , (Name "JsonString", DataDef DataTuple [] [] []
        [(Name "value", TPrim PrimString)])
    , (Name "JsonNumber", DataDef DataTuple [] [] []
        [(Name "value", TPrim PrimNumber)])
    , (Name "JsonBoolean", DataDef DataTuple [] [] []
        [(Name "value", TPrim PrimBoolean)])
    , (Name "JsonNull",   DataDef DataTuple [] [] [] [])
    , (Name "JsonParseError", DataDef DataTuple [] [] []
        [(Name "message", TPrim PrimString)])
    , (Name "JsonFieldNotFoundError", DataDef DataTuple [] [] []
        [(Name "field", TPrim PrimString)])
    , (Name "JsonDeserializationError", DataDef DataTuple [] [] []
        [(Name "message", TPrim PrimString)])
    ]

jsonEffectDefs :: Map.Map Name EffectDef
jsonEffectDefs = Map.fromList
    [ (Name "JsonDeserializationError", EffectDef
        { edParamNames = []
        , edParams     = []
        , edBounds     = []
        , edFields     = [(Name "message", TPrim PrimString)]
        , edReturnTy   = TNever
        })
    ]

jsonTraitDefs :: Map.Map Name TraitDef
jsonTraitDefs = Map.fromList
    [ (Name "Serialize", TraitDef
        { trParamNames = [Name "T"]
        , trParams     = [DataTypeParam Covariant]
        , trBounds     = [BoundNone]
        , trFields     = [(Name "value", TVar (Name "T"))]
        , trReturnTy   = jsonTy
        })
    , (Name "Deserialize", TraitDef
        { trParamNames = [Name "T"]
        , trParams     = [DataTypeParam Covariant]
        , trBounds     = [BoundNone]
        , trFields     = [(Name "json", jsonTy)]
        , trReturnTy   = TVar (Name "T")
        })
    ]

jsonValues :: Map.Map Name Type
jsonValues = Map.fromList
    [ (Name "to_string", TFun
        [FunParam (Name "json") jsonTy]
        (TPrim PrimString)
        EffPure)
    , (Name "from_string", TFun
        [FunParam (Name "s") (TPrim PrimString)]
        jsonTy
        (EffSingle (Name "Throw") [TData (Name "JsonParseError") []]))
    , (Name "get", TFun
        [ FunParam (Name "obj") (TData (Name "JsonObject") [])
        , FunParam (Name "key") (TPrim PrimString)
        ]
        jsonTy
        (EffSingle (Name "Throw") [TData (Name "JsonFieldNotFoundError") []]))
    , (Name "make_object", TFun
        [FunParam (Name "fields") (TArray (TData (Name "JsonPair") []))]
        (TData (Name "JsonObject") [])
        EffPure)
    ]

primJsonTypeDefs :: TypeDefs
primJsonTypeDefs = emptyTypeDefs
    { tdData    = jsonDataDefs
    , tdEffects = jsonEffectDefs
    , tdTypes   = Map.fromList [(Name "Json", jsonTypeSyn)]
    , tdTraits  = jsonTraitDefs
    }

-- =========================================================================
-- prim.task module
-- =========================================================================

-- Task is a primitive effect (not user-defined), no fields
taskEffDef :: EffectDef
taskEffDef = EffectDef
    { edParamNames = []
    , edParams     = []
    , edBounds     = []
    , edFields     = []
    , edReturnTy   = TPrim PrimNull
    }

primTaskTypeDefs :: TypeDefs
primTaskTypeDefs = emptyTypeDefs
    { tdEffects = Map.singleton (Name "Task") taskEffDef
    }

taskValues :: Map.Map Name Type
taskValues = Map.fromList
    [ (Name "panic", TFun
        [FunParam (Name "message") (TPrim PrimString)]
        TNever
        (EffSingle (Name "Task") []))
    ]

-- =========================================================================
-- prim.log module
-- =========================================================================

logValues :: Map.Map Name Type
logValues = Map.fromList
    [ (Name "info", logFn)
    , (Name "warn", logFn)
    , (Name "error", logFn)
    ]
  where
    logFn = TFun
        [FunParam (Name "message") (TPrim PrimString)]
        (TPrim PrimNull)
        (EffSingle (Name "Task") [])

-- =========================================================================
-- prim.ffi module
-- =========================================================================

ffiDataDefs :: Map.Map Name DataDef
ffiDataDefs = Map.fromList
    [ (Name "FFIFunctionNotFoundError", DataDef DataTuple [] [] []
        [(Name "name", TPrim PrimString)])
    ]

primFfiTypeDefs :: TypeDefs
primFfiTypeDefs = emptyTypeDefs
    { tdData  = ffiDataDefs
    , tdTypes = Map.fromList
        [ (Name "FFIError", TypeSynDef
            { tsParams = []
            , tsBody = foldr1 TUnion
                [ TData (Name "FFIFunctionNotFoundError") []
                , TData (Name "JsonParseError")           []
                , TData (Name "JsonFieldNotFoundError")    []
                , TData (Name "JsonDeserializationError") []
                ]
            })
        ]
    }

-- =========================================================================
-- prim.parallel module
-- =========================================================================

parallelValues :: Map.Map Name Type
parallelValues = Map.fromList
    [ (Name "all", TFun
        [FunParam (Name "tasks")
            (TArray (TFun []
                (TVar (Name "T"))
                (EffUnion [ EffVar (Name "E")
                          , EffSingle (Name "Task") []
                          ])))]
        (TArray (TVar (Name "T")))
        (EffUnion [ EffVar (Name "E")
                  , EffSingle (Name "Task") []
                  ]))
    ]

-- =========================================================================
-- Module interface assembly
-- =========================================================================

mkModName :: [String] -> ModuleName
mkModName []     = error "mkModName: empty"
mkModName (x:xs) = ModuleName (T.pack x :| map T.pack xs)

-- | All prim sub-module interfaces.
primInterfaces :: [ModuleInterface]
primInterfaces =
    [ ModuleInterface
        { miModuleName = mkModName ["prim"]
        , miTypeDefs   = primTypeDefs
        , miValues     = Map.empty
        }
    , ModuleInterface
        { miModuleName = mkModName ["prim", "json"]
        , miTypeDefs   = primJsonTypeDefs
        , miValues     = jsonValues
        }
    , ModuleInterface
        { miModuleName = mkModName ["prim", "task"]
        , miTypeDefs   = primTaskTypeDefs
        , miValues     = taskValues
        }
    , ModuleInterface
        { miModuleName = mkModName ["prim", "log"]
        , miTypeDefs   = emptyTypeDefs
        , miValues     = logValues
        }
    , ModuleInterface
        { miModuleName = mkModName ["prim", "ffi"]
        , miTypeDefs   = primFfiTypeDefs
        , miValues     = Map.empty
        }
    , ModuleInterface
        { miModuleName = mkModName ["prim", "parallel"]
        , miTypeDefs   = emptyTypeDefs
        , miValues     = parallelValues
        }
    ]
