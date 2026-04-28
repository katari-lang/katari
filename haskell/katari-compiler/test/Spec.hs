import Katari.ConstraintGeneratorSpec qualified as ConstraintGeneratorSpec
import Katari.IdentifierSpec qualified as IdentifierSpec
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
