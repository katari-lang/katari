import Katari.IdentifierSpec qualified as IdentifierSpec
import Katari.ParserSpec qualified as ParserSpec
import Test.Hspec
import Katari.Prelude

main :: IO ()
main = hspec $ do
  ParserSpec.spec
  IdentifierSpec.spec
