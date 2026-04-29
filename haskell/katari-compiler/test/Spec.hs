import Katari.ConstraintGeneratorSpec qualified as ConstraintGeneratorSpec
import Katari.DiagnosticSpec qualified as DiagnosticSpec
import Katari.IRSpec qualified as IRSpec
import Katari.IdentifierSpec qualified as IdentifierSpec
import Katari.LoweringSpec qualified as LoweringSpec
import Katari.ParserSpec qualified as ParserSpec
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
