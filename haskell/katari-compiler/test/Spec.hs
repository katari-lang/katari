import Katari.CompileSpec qualified as CompileSpec
import Katari.ConstraintGeneratorSpec qualified as ConstraintGeneratorSpec
import Katari.DiagnosticSpec qualified as DiagnosticSpec
import Katari.GoldenSpec qualified as GoldenSpec
import Katari.PropertySpec qualified as PropertySpec
import Katari.IRSpec qualified as IRSpec
import Katari.IdentifierSpec qualified as IdentifierSpec
import Katari.LoweringSpec qualified as LoweringSpec
import Katari.ParserSpec qualified as ParserSpec
import Katari.Query.CompletionSpec qualified as CompletionSpec
import Katari.QuerySpec qualified as QuerySpec
import Katari.SchemaSpec qualified as SchemaSpec
import Katari.ScopeIndexSpec qualified as ScopeIndexSpec
import Katari.SolverSpec qualified as SolverSpec
import Katari.ZonkerSpec qualified as ZonkerSpec
import Test.Hspec

main :: IO ()
main = hspec $ do
  ParserSpec.spec
  IdentifierSpec.spec
  ConstraintGeneratorSpec.spec
  ZonkerSpec.spec
  SolverSpec.spec
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
