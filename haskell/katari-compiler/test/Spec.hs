import Katari.ConstraintGeneratorSpec qualified as ConstraintGeneratorSpec
import Katari.IdentifierSpec qualified as IdentifierSpec
import Katari.ParserSpec qualified as ParserSpec
import Test.Hspec

main :: IO ()
main = hspec $ do
  ParserSpec.spec
  IdentifierSpec.spec
  ConstraintGeneratorSpec.spec
