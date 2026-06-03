import Katari.CompileSpec qualified as CompileSpec
import Katari.DiagnosticSpec qualified as DiagnosticSpec
import Katari.ExhaustiveSpec qualified as ExhaustiveSpec
import Katari.GoldenSpec qualified as GoldenSpec
import Katari.IRSpec qualified as IRSpec
import Katari.IdentifierSpec qualified as IdentifierSpec
import Katari.LoweringSpec qualified as LoweringSpec
import Katari.ParserSpec qualified as ParserSpec
import Katari.PropertySpec qualified as PropertySpec
import Katari.Query.CompletionSpec qualified as CompletionSpec
import Katari.QuerySpec qualified as QuerySpec
import Katari.SchemaSpec qualified as SchemaSpec
import Katari.ScopeIndexSpec qualified as ScopeIndexSpec
import Test.Hspec

main :: IO ()
main = hspec $ do
  ParserSpec.spec
  IdentifierSpec.spec
  ExhaustiveSpec.spec
  IRSpec.spec
  LoweringSpec.spec
  DiagnosticSpec.spec
  SchemaSpec.spec
  CompileSpec.spec
  GoldenSpec.spec
  PropertySpec.spec
  ScopeIndexSpec.spec
  CompletionSpec.spec
  QuerySpec.spec
