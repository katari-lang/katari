module Katari.Typechecker.ThrowSpec (spec) where

import Data.Foldable (toList)
import Data.Map qualified as Map
import Data.Text (Text)
import Katari.Data.ModuleName (ModuleName (..))
import Katari.Data.SourceSpan (Located (..))
import Katari.Diagnostics (Diagnostics)
import Katari.Error (CompilerError (..), typeErrorCode)
import Katari.Identifier (identifyModule, scanExports)
import Katari.Identifier.Monad (IdentifiedModule (..), ImportContext (..))
import Katari.Parser (parseModule)
import Katari.Typechecker (checkProgram)
import Katari.Typechecker.Environment (buildEnvironment)
import Katari.Typechecker.ValueGraph (valueSCCs)
import Test.Hspec

-- | The typed-error model rests on a single generic request (@throw[T]@): the payload type
-- instantiates per raise site, instantiations of one scope join to the payload union (request
-- parameters are covariant in the effect row), and a handler discharges exactly the instantiation
-- its parameter annotation names. These specs pin that machinery on a locally-declared @throw@.
spec :: Spec
spec = describe "generic request (throw[T]) typing" $ do
  it "accepts a raise whose instantiation is inferred from the argument" $
    typeErrorCodes
      [ ( "test",
          "data oops(message: string)\n\
          \request throw[T](error: T) -> never\n\
          \agent f() -> integer with throw[oops] { throw(error = oops(message = \"x\")) }"
        )
      ]
      `shouldBe` []

  it "accepts a raise at an explicit instantiation" $
    typeErrorCodes
      [ ( "test",
          "data oops(message: string)\n\
          \request throw[T](error: T) -> never\n\
          \agent f() -> integer with throw[oops] { throw[oops](error = oops(message = \"x\")) }"
        )
      ]
      `shouldBe` []

  it "accepts a raise with no effect annotation (the agent's effect is inferred)" $
    typeErrorCodes
      [ ( "test",
          "data oops(message: string)\n\
          \request throw[T](error: T) -> never\n\
          \agent f() -> integer { throw(error = oops(message = \"x\")) }"
        )
      ]
      `shouldBe` []

  it "rejects a raise whose payload does not fit the declared instantiation (K3001)" $
    typeErrorCodes
      [ ( "test",
          "data oops(message: string)\n\
          \data other(code: integer)\n\
          \request throw[T](error: T) -> never\n\
          \agent f() -> integer with throw[oops] { throw(error = other(code = 1)) }"
        )
      ]
      `shouldContain` ["K3001"]

  it "discharges the raised instantiation with a handler at that payload type" $
    typeErrorCodes
      [ ( "test",
          "data oops(message: string)\n\
          \request throw[T](error: T) -> never\n\
          \agent f() -> integer {\n\
          \  use handler { request throw(error: oops) -> never { break 0 } }\n\
          \  throw(error = oops(message = \"x\"))\n\
          \}"
        )
      ]
      `shouldBe` []

  it "joins two raise sites to the payload union (both discharged by one union handler)" $
    typeErrorCodes
      [ ( "test",
          "data oops(message: string)\n\
          \data other(code: integer)\n\
          \request throw[T](error: T) -> never\n\
          \agent f(flag: boolean) -> integer {\n\
          \  use handler { request throw(error: oops | other) -> never { break 0 } }\n\
          \  if (flag) { throw(error = oops(message = \"x\")) } else { throw(error = other(code = 1)) }\n\
          \}"
        )
      ]
      `shouldBe` []

  it "rejects a handler narrower than the joined payload (K3001)" $
    typeErrorCodes
      [ ( "test",
          "data oops(message: string)\n\
          \data other(code: integer)\n\
          \request throw[T](error: T) -> never\n\
          \agent f(flag: boolean) -> integer {\n\
          \  use handler { request throw(error: oops) -> never { break 0 } }\n\
          \  if (flag) { throw(error = oops(message = \"x\")) } else { throw(error = other(code = 1)) }\n\
          \}"
        )
      ]
      `shouldContain` ["K3001"]

  it "lets a handler rethrow: the handler body's raise escapes to the enclosing scope" $
    typeErrorCodes
      [ ( "test",
          "data oops(message: string)\n\
          \data other(code: integer)\n\
          \request throw[T](error: T) -> never\n\
          \agent f() -> integer with throw[other] {\n\
          \  use handler { request throw(error: oops) -> never { throw(error = other(code = 1)) } }\n\
          \  throw(error = oops(message = \"x\"))\n\
          \}"
        )
      ]
      `shouldBe` []

  -- Row subsumption compares each request parameter at its occurrence-inferred variance: covariant
  -- when it appears only in parameter (handler-receives) positions, contravariant only in the result,
  -- invariant in both, and phantom (used nowhere) compared covariantly. These pin all three fates.
  it "accepts a narrower row where a wider one is expected (input-only parameter: covariant)" $
    typeErrorCodes
      [ ( "test",
          "data oops(message: string)\n\
          \data other(code: integer)\n\
          \request throw[T](error: T) -> never\n\
          \agent raiser() -> integer with throw[oops] { throw(error = oops(message = \"x\")) }\n\
          \agent call(f: agent () -> integer with throw[oops | other]) -> integer with throw[oops | other] { f() }\n\
          \agent main() -> integer with throw[oops | other] { call(f = raiser) }"
        )
      ]
      `shouldBe` []

  it "requires equal instantiations for a parameter used in both polarities (invariant, K3001)" $
    typeErrorCodes
      [ ( "test",
          "data oops(message: string)\n\
          \data other(code: integer)\n\
          \request swap[T](value: T) -> T\n\
          \agent narrow() -> integer with swap[oops] { 0 }\n\
          \agent call(f: agent () -> integer with swap[oops | other]) -> integer with swap[oops | other] { f() }\n\
          \agent main() -> integer with swap[oops | other] { call(f = narrow) }"
        )
      ]
      `shouldContain` ["K3001"]

  it "accepts an invariant parameter at exactly the same instantiation" $
    typeErrorCodes
      [ ( "test",
          "data oops(message: string)\n\
          \request swap[T](value: T) -> T\n\
          \agent narrow() -> integer with swap[oops] { 0 }\n\
          \agent call(f: agent () -> integer with swap[oops]) -> integer with swap[oops] { f() }\n\
          \agent main() -> integer with swap[oops] { call(f = narrow) }"
        )
      ]
      `shouldBe` []

  it "compares a phantom parameter covariantly: a narrower tag fits a wider one" $
    typeErrorCodes
      [ ( "test",
          "data oops(message: string)\n\
          \data other(code: integer)\n\
          \request ping[T]() -> null\n\
          \agent tagged() -> integer with ping[oops] { 0 }\n\
          \agent call(f: agent () -> integer with ping[oops | other]) -> integer with ping[oops | other] { f() }\n\
          \agent main() -> integer with ping[oops | other] { call(f = tagged) }"
        )
      ]
      `shouldBe` []

  it "compares a phantom parameter covariantly: an unrelated tag is rejected (K3001)" $
    typeErrorCodes
      [ ( "test",
          "data oops(message: string)\n\
          \data other(code: integer)\n\
          \request ping[T]() -> null\n\
          \agent tagged() -> integer with ping[oops] { 0 }\n\
          \agent call(f: agent () -> integer with ping[other]) -> integer with ping[other] { f() }\n\
          \agent main() -> integer with ping[other] { call(f = tagged) }"
        )
      ]
      `shouldContain` ["K3001"]

  -- No operators here: this driver seeds only the test module, so a desugared `prelude.*` call
  -- would trip the missing-stdlib backstop rather than exercise the raise.
  it "a raise typechecks in any expression position (its type is never)" $
    typeErrorCodes
      [ ( "test",
          "data oops(message: string)\n\
          \request throw[T](error: T) -> never\n\
          \agent f(flag: boolean) -> string {\n\
          \  if (flag) { \"ok\" } else { throw(error = oops(message = \"neg\")) }\n\
          \}"
        )
      ]
      `shouldBe` []

typeErrorCodes :: [(Text, Text)] -> [Text]
typeErrorCodes sources =
  [typeErrorCode typeError | located <- toList (runProgramDiagnostics sources), CompilerErrorType typeError <- [located.value]]

-- | Parse, identify, build the type environment, and run 'checkProgram'; the combined diagnostics of
-- the identify, env-build, and check phases (same driver as 'ProgramSpec').
runProgramDiagnostics :: [(Text, Text)] -> Diagnostics
runProgramDiagnostics sources =
  identifyDiagnostics <> envDiagnostics <> checkDiagnostics
  where
    parsedModules = [(ModuleName name, fst (parseModule (ModuleName name) source)) | (name, source) <- sources]
    importContext =
      ImportContext
        { moduleInterfaces = Map.fromList [(moduleName, scanExports moduleName parsedModule) | (moduleName, parsedModule) <- parsedModules],
          defaultImports = []
        }
    identifiedResults = [(moduleName, identifyModule importContext moduleName parsedModule) | (moduleName, parsedModule) <- parsedModules]
    modules = Map.fromList [(moduleName, (fst result).identifiedAst) | (moduleName, result) <- identifiedResults]
    identifyDiagnostics = foldMap (snd . snd) identifiedResults
    (typeEnvironment, envDiagnostics) = buildEnvironment modules
    (_, _, checkDiagnostics) = checkProgram typeEnvironment (valueSCCs modules) modules
