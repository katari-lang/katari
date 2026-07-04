module Katari.Typechecker.ValueGraphSpec (spec) where

import Data.Graph (SCC (..), flattenSCC)
import Data.List (sort)
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Text (Text)
import Katari.Data.AST (Module, Phase (Identified))
import Katari.Data.ModuleName (ModuleName (..))
import Katari.Data.QualifiedName (QualifiedName (..))
import Katari.Identifier (identifyModule, scanExports)
import Katari.Identifier.Monad (IdentifiedModule (..), ImportContext (..))
import Katari.Parser (parseModule)
import Katari.Typechecker.ValueGraph (ValueNode (..), valueSCCs)
import Test.Hspec

spec :: Spec
spec = do
  describe "valueSCCs (ordering)" $ do
    it "lists a callee before its caller (dependency-first)" $
      sccNames (sccsOf [("test", "agent caller() -> integer { callee() }\nagent callee() -> integer { 1 }")])
        `shouldBe` [["callee"], ["caller"]]
    it "lists a three-stage chain dependency-first" $
      sccNames (sccsOf [("test", "agent a() -> integer { b() }\nagent b() -> integer { c() }\nagent c() -> integer { 1 }")])
        `shouldBe` [["c"], ["b"], ["a"]]
    it "keeps two independent agents as separate acyclic components" $
      sort (sccNames (sccsOf [("test", "agent a() -> integer { 1 }\nagent b() -> integer { 2 }")]))
        `shouldBe` [["a"], ["b"]]

  describe "valueSCCs (recursion)" $ do
    it "groups a self-recursive agent into one cyclic component" $ do
      let sccs = sccsOf [("test", "agent loop() -> integer { loop() }")]
      sccNames sccs `shouldBe` [["loop"]]
      map isCyclic sccs `shouldBe` [True]
    it "groups mutually recursive agents into one cyclic component" $ do
      let sccs = sccsOf [("test", "agent ping() -> integer { pong() }\nagent pong() -> integer { ping() }")]
      map (sort . componentNames) sccs `shouldBe` [["ping", "pong"]]
      map isCyclic sccs `shouldBe` [True]
    it "marks an acyclic agent as not cyclic" $
      map isCyclic (sccsOf [("test", "agent a() -> integer { 1 }")]) `shouldBe` [False]

  describe "valueSCCs (every top-level value is a node)" $ do
    it "orders a referenced data constructor before the agent (an acyclic source)" $ do
      let sccs = sccsOf [("test", "data point(x: integer)\nagent a() -> integer { let p = point(x = 1)\np.x }")]
      sccNames sccs `shouldBe` [["point"], ["a"]]
      map isCyclic sccs `shouldBe` [False, False]
    it "orders a referenced request before the agent" $
      sccNames (sccsOf [("test", "request tick() -> integer\nagent a() -> integer { tick() }")])
        `shouldBe` [["tick"], ["a"]]

  describe "valueSCCs (cross-module)" $
    it "links an agent to an agent it calls in another module" $ do
      let sccs =
            sccsOf
              [ ("caller", "import callee\nagent run() -> integer { callee.base() }"),
                ("callee", "agent base() -> integer { 1 }")
              ]
      map componentNames sccs `shouldBe` [["base"], ["run"]]

------------------------------------------------------------------------------------------------
-- Driver
------------------------------------------------------------------------------------------------

-- | Parse and identify a set of modules together (every module's interface visible to the others),
-- then compute the value SCCs.
sccsOf :: [(Text, Text)] -> [SCC ValueNode]
sccsOf sources = valueSCCs (identifyModules sources)

identifyModules :: [(Text, Text)] -> Map ModuleName (Module Identified)
identifyModules sources =
  Map.fromList [(moduleName, (fst (identifyModule importContext moduleName parsedModule)).identifiedAst) | (moduleName, parsedModule) <- parsedModules]
  where
    parsedModules = [(ModuleName name, fst (parseModule (ModuleName name) source)) | (name, source) <- sources]
    importContext =
      ImportContext
        { moduleInterfaces = Map.fromList [(moduleName, scanExports moduleName parsedModule) | (moduleName, parsedModule) <- parsedModules],
          defaultImports = []
        }

-- | The simple (unqualified) names in each component, components in their listed order.
sccNames :: [SCC ValueNode] -> [[Text]]
sccNames = map componentNames

componentNames :: SCC ValueNode -> [Text]
componentNames component = [simpleName node | node <- flattenSCC component]
  where
    simpleName node = case node.qualifiedName of QualifiedName {name = simple} -> simple

isCyclic :: SCC ValueNode -> Bool
isCyclic = \case
  CyclicSCC _ -> True
  AcyclicSCC _ -> False
