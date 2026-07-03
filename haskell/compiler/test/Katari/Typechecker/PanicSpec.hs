module Katari.Typechecker.PanicSpec (spec) where

import Data.Foldable (toList)
import Data.Map qualified as Map
import Data.Text (Text)
import Katari.Data.ModuleName (ModuleName (..))
import Katari.Data.SourceSpan (Located (..))
import Katari.Diagnostics (Diagnostics)
import Katari.Error (compilerErrorCode)
import Katari.Identifier (identifyModule, scanExports)
import Katari.Identifier.Monad (IdentifiedModule (..), ImportContext (..))
import Katari.Parser (parseModule)
import Katari.Typechecker (checkProgram)
import Katari.Typechecker.Environment (buildEnvironment)
import Katari.Typechecker.ValueGraph (valueSCCs)
import Test.Hspec

-- | @panic@ is the runtime's uncatchable failure — undeclared in prelude source, so a program can neither
-- raise it nor name it in an effect row. A handler may nonetheless catch one with a special ambient clause
-- @request panic(msg: string) { ... }@: the checker recognizes the bare name structurally, types it as
-- @panic(msg: string) -> never@, and keeps it OUT of the continuation's effect row so it is addable to any
-- handler. These specs pin that recognition and its ambient (row-invisible) typing.
spec :: Spec
spec = describe "the ambient panic handler" $ do
  it "accepts a bare `request panic(msg: string)` clause (panic is catchable via the special handler)" $
    diagnosticCodes
      [ ( "test",
          "agent f() -> integer {\n\
          \  use handler { request panic(msg: string) { break 0 } }\n\
          \  42\n\
          \}"
        )
      ]
      `shouldBe` []

  it "binds the panic message as a string (usable in the handler body)" $
    diagnosticCodes
      [ ( "test",
          "agent f() -> string {\n\
          \  use handler { request panic(msg: string) { break msg } }\n\
          \  \"ok\"\n\
          \}"
        )
      ]
      `shouldBe` []

  it "is ambient: the wrapped continuation need not list panic in its effect row" $
    diagnosticCodes
      [ ( "test",
          "request ask(question: string) -> string\n\
          \agent f() -> string with ask {\n\
          \  use handler { request panic(msg: string) { break \"caught\" } }\n\
          \  ask(question = \"hi\")\n\
          \}"
        )
      ]
      `shouldBe` []

  it "coexists with a real request handler in the same handler value" $
    diagnosticCodes
      [ ( "test",
          "data oops(message: string)\n\
          \request throw[T](error: T) -> never\n\
          \agent f() -> integer {\n\
          \  use handler {\n\
          \    request throw(error: oops) -> never { break 1 }\n\
          \    request panic(msg: string) { break 2 }\n\
          \  }\n\
          \  throw(error = oops(message = \"x\"))\n\
          \}"
        )
      ]
      `shouldBe` []

  it "still rejects a handler for a genuinely undeclared request (only panic is ambient)" $
    diagnosticCodes
      [ ( "test",
          "agent f() -> integer {\n\
          \  use handler { request nonexistent(x) { break 0 } }\n\
          \  42\n\
          \}"
        )
      ]
      `shouldContain` ["K3017"]

-- | Every diagnostic code the pipeline emits (identify + env + check), so a positive spec asserting @[]@
-- catches an identifier-level error (e.g. an undefined-name K2001) too, not only type errors.
diagnosticCodes :: [(Text, Text)] -> [Text]
diagnosticCodes sources =
  [compilerErrorCode located.value | located <- toList (runProgramDiagnostics sources)]

-- | Parse, identify, build the type environment, and run 'checkProgram'; the combined diagnostics of the
-- identify, env-build, and check phases (the same driver as 'ThrowSpec').
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
