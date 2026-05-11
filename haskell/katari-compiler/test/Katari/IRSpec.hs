-- | Stage 0: JSON round-trip tests for the IR data types.
--
-- 目的: 全 sum variant が ToJSON → FromJSON で安定し、JSON shape が想定通りである
-- ことを確認する。Lowering の出力品質は別 spec で検証する。
module Katari.IRSpec (spec) where

import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Map.Strict qualified as Map
import Katari.IR
import Test.Hspec

-- ===========================================================================
-- Helpers
-- ===========================================================================

-- | Encode → decode → re-encode round-trip; assert idempotence at the JSON
-- 'Value' level (so we don't depend on Aeson's encoded byte-string form).
roundTrip :: (Aeson.ToJSON a, Aeson.FromJSON a, Eq a, Show a) => a -> Expectation
roundTrip value = do
  let encoded = Aeson.toJSON value
  case Aeson.fromJSON encoded of
    Aeson.Success decoded -> decoded `shouldBe` value
    Aeson.Error msg -> expectationFailure ("decode failed: " <> msg)

-- | Assert the encoded JSON has a specific shape (subset match via equality
-- on the 'Value' tree).
shouldEncodeAs :: (Aeson.ToJSON a) => a -> Value -> Expectation
shouldEncodeAs value expected = Aeson.toJSON value `shouldBe` expected

-- ===========================================================================
-- Spec
-- ===========================================================================

spec :: Spec
spec = describe "Katari.IR" $ do
  blockSpec
  statementSpec
  callTargetSpec
  exitContSpec
  matchArmSpec
  moduleSpec

blockSpec :: Spec
blockSpec = describe "Block (sum)" $ do
  it "BlockUser nests UserBlock under 'body'" $ do
    let userBlock =
          UserBlock
            { parameters = [Param {label = "x", var = VarId 0}],
              statements = [],
              trailing = Just (VarId 1)
            }
    BlockUser userBlock
      `shouldEncodeAs` object
        [ "kind" .= ("blockUser" :: String),
          "body"
            .= object
              [ "parameters" .= [object ["label" .= ("x" :: String), "var" .= (0 :: Int)]],
                "statements" .= ([] :: [Value]),
                "trailing" .= (1 :: Int)
              ]
        ]

  it "BlockPrim carries kind + body (the prim name)" $ do
    BlockPrim "add"
      `shouldEncodeAs` object ["kind" .= ("blockPrim" :: String), "body" .= ("add" :: String)]

  it "BlockRequest carries kind + body (QualifiedName as flat string)" $ do
    BlockRequest (QualifiedName "main" "log")
      `shouldEncodeAs` object
        [ "kind" .= ("blockRequest" :: String),
          "body" .= ("main.log" :: String)
        ]

  it "BlockExternal carries kind + body (ExternalName as flat string)" $ do
    BlockExternal (ExternalName (QualifiedName "discord" "send_message"))
      `shouldEncodeAs` object
        [ "kind" .= ("blockExternal" :: String),
          "body" .= ("discord.send_message" :: String)
        ]

  it "BlockConstructor carries kind + body (QualifiedName as flat string)" $ do
    BlockConstructor (QualifiedName "main" "point")
      `shouldEncodeAs` object
        [ "kind" .= ("blockConstructor" :: String),
          "body" .= ("main.point" :: String)
        ]

  it "BlockTuple carries kind + body (TupleBlock)" $ do
    BlockTuple TupleBlock {parallel = False, elements = [BlockId 1, BlockId 2]}
      `shouldEncodeAs` object
        [ "kind" .= ("blockTuple" :: String),
          "body" .= object ["parallel" .= False, "elements" .= [1 :: Int, 2]]
        ]

  it "BlockArray carries kind + body (ArrayBlock)" $ do
    BlockArray ArrayBlock {parallel = True, elements = [BlockId 5]}
      `shouldEncodeAs` object
        [ "kind" .= ("blockArray" :: String),
          "body" .= object ["parallel" .= True, "elements" .= [5 :: Int]]
        ]

  it "round-trips all variants" $ do
    let userBody =
          UserBlock
            { parameters = [],
              statements = [],
              trailing = Nothing
            }
    roundTrip (BlockUser userBody)
    roundTrip (BlockPrim "add")
    roundTrip (BlockRequest (QualifiedName "main" "log"))
    roundTrip (BlockExternal (ExternalName (QualifiedName "discord" "send")))
    roundTrip (BlockConstructor (QualifiedName "main" "point"))
    roundTrip (BlockMatch MatchBlock {subject = VarId 0, arms = [], defaultArm = Nothing})
    roundTrip (BlockFor ForBlock {parallel = False, iters = [], stateInits = [], bodyBlock = BlockId 0, thenBlock = Nothing})
    roundTrip (BlockHandle HandleBlock {parallel = False, stateInits = [], body = BlockId 0, handlers = [], thenBlock = Nothing})
    roundTrip (BlockTuple TupleBlock {parallel = False, elements = []})
    roundTrip (BlockArray ArrayBlock {parallel = True, elements = [BlockId 1]})

statementSpec :: Spec
statementSpec = describe "Statement (sum)" $ do
  it "StatementCall nests CallData under 'body'" $ do
    StatementCall
      CallData
        { block = BlockId 7,
          arguments = [Arg {label = "x", var = VarId 1}],
          output = Just (VarId 2)
        }
      `shouldEncodeAs` object
        [ "kind" .= ("statementCall" :: String),
          "body"
            .= object
              [ "block" .= (7 :: Int),
                "arguments" .= [object ["label" .= ("x" :: String), "var" .= (1 :: Int)]],
                "output" .= (2 :: Int)
              ]
        ]

  it "StatementMakeClosure nests MakeClosureData under 'body'" $ do
    StatementMakeClosure MakeClosureData {output = VarId 3, block = BlockId 12}
      `shouldEncodeAs` object
        [ "kind" .= ("statementMakeClosure" :: String),
          "body"
            .= object
              [ "output" .= (3 :: Int),
                "block" .= (12 :: Int)
              ]
        ]

  it "StatementExit nests ExitData under 'body' (with exitKind enum)" $ do
    StatementExit ExitData {exitKind = ExitKindReturn, value = VarId 4}
      `shouldEncodeAs` object
        [ "kind" .= ("statementExit" :: String),
          "body"
            .= object
              [ "exitKind" .= ("exitKindReturn" :: String),
                "value" .= (4 :: Int)
              ]
        ]

  it "StatementCont (forNext) omits value when Nothing" $ do
    StatementCont
      ContData
        { contKind = ContKindForNext,
          value = Nothing,
          modifiers = [(VarId 5, VarId 6)]
        }
      `shouldEncodeAs` object
        [ "kind" .= ("statementCont" :: String),
          "body"
            .= object
              [ "contKind" .= ("contKindForNext" :: String),
                "modifiers" .= [[Aeson.Number 5, Aeson.Number 6]]
              ]
        ]

  it "StatementLoadLiteral nests an inner literal value object" $ do
    StatementLoadLiteral LoadLiteralData {output = VarId 5, value = LiteralValueInteger 42}
      `shouldEncodeAs` object
        [ "kind" .= ("statementLoadLiteral" :: String),
          "body"
            .= object
              [ "output" .= (5 :: Int),
                "value" .= object ["kind" .= ("literalValueInteger" :: String), "integer" .= (42 :: Int)]
              ]
        ]

  it "round-trips all statement variants" $ do
    roundTrip $
      StatementCall
        CallData
          { block = BlockId 0,
            arguments = [],
            output = Nothing
          }
    roundTrip $ StatementMakeClosure MakeClosureData {output = VarId 0, block = BlockId 0}
    roundTrip $
      StatementLoadLiteral LoadLiteralData {output = VarId 0, value = LiteralValueInteger 0}
    roundTrip $
      StatementAgentCall
        AgentCallData {target = VarId 0, arguments = [], output = Nothing}
    roundTrip $ StatementExit ExitData {exitKind = ExitKindBreak, value = VarId 0}
    roundTrip $ StatementCont ContData {contKind = ContKindNext, value = Just (VarId 0), modifiers = []}
    roundTrip $ StatementBindPattern BindPatternData {source = VarId 0, pattern = MatchPatternAny}

  it "round-trips all LiteralValue variants" $ do
    roundTrip (LiteralValueInteger 42)
    roundTrip (LiteralValueNumber 3.14)
    roundTrip (LiteralValueString "hello")
    roundTrip (LiteralValueBoolean True)
    roundTrip LiteralValueNull
    roundTrip (LiteralValueAgent (QualifiedName "main" "foo"))

callTargetSpec :: Spec
callTargetSpec = describe "CallData (inline block target)" $ do
  it "encodes block id directly under body" $ do
    StatementCall
      CallData {block = BlockId 5, arguments = [], output = Nothing}
      `shouldEncodeAs` object
        [ "kind" .= ("statementCall" :: String),
          "body"
            .= object
              [ "block" .= (5 :: Int),
                "arguments" .= ([] :: [Aeson.Value])
              ]
        ]

exitContSpec :: Spec
exitContSpec = describe "ExitKind / ContKind" $ do
  it "ExitKind serializes as bare camelCase strings" $ do
    Aeson.toJSON ExitKindReturn `shouldBe` Aeson.String "exitKindReturn"
    Aeson.toJSON ExitKindBreak `shouldBe` Aeson.String "exitKindBreak"
    Aeson.toJSON ExitKindForBreak `shouldBe` Aeson.String "exitKindForBreak"

  it "ContKind serializes as bare camelCase strings" $ do
    Aeson.toJSON ContKindNext `shouldBe` Aeson.String "contKindNext"
    Aeson.toJSON ContKindForNext `shouldBe` Aeson.String "contKindForNext"

  it "round-trips all enum values" $ do
    mapM_ roundTrip [ExitKindReturn, ExitKindBreak, ExitKindForBreak]
    mapM_ roundTrip [ContKindNext, ContKindForNext]

matchArmSpec :: Spec
matchArmSpec = describe "MatchArm" $ do
  it "encodes an MatchPatternAny pattern" $ do
    MatchArm {pattern = MatchPatternAny, body = BlockId 0}
      `shouldEncodeAs` object
        [ "pattern" .= object ["kind" .= ("matchPatternAny" :: String)],
          "body" .= (0 :: Int)
        ]

  it "round-trips a constructor pattern with bound fields" $ do
    roundTrip
      MatchArm
        { pattern =
            MatchPatternConstructor
              (QualifiedName "main" "cons")
              [("head", MatchPatternVariable (VarId 1)), ("tail", MatchPatternVariable (VarId 2))],
          body = BlockId 3
        }

moduleSpec :: Spec
moduleSpec = describe "IRModule" $ do
  it "round-trips an empty module" $ do
    roundTrip
      IRModule
        { metadata = currentIRMetadata,
          name = "main",
          blocks = Map.empty,
          entries = Map.empty,
          nameTable = emptyNameTable
        }

  it "round-trips a small module with one block" $ do
    let block =
          BlockUser
            UserBlock
              { parameters = [],
                statements = [StatementExit ExitData {exitKind = ExitKindReturn, value = VarId 0}],
                trailing = Nothing
              }
    roundTrip
      IRModule
        { metadata = currentIRMetadata,
          name = "main",
          blocks = Map.singleton (BlockId 0) block,
          entries = Map.singleton (QualifiedName "" "main") (BlockId 0),
          nameTable =
            NameTable
              { varNames = Map.singleton (VarId 0) "x",
                blockNames = Map.singleton (BlockId 0) "main"
              }
        }

  it "encodes IRModule.entries as a JSON object keyed by 'module.name'" $ do
    -- Pin the textual key format. The TS runtime indexes entries with the
    -- string returned by `renderQualifiedName`; the default Aeson encoding
    -- (array of [key,value] pairs) would not work.
    let entries =
          Map.fromList
            [ (QualifiedName "" "main", BlockId 0),
              (QualifiedName "foo" "bar", BlockId 1)
            ]
    Aeson.toJSON entries
      `shouldBe` object
        [ "main" .= (0 :: Int),
          "foo.bar" .= (1 :: Int)
        ]

  it "round-trips a QualifiedName key with an empty module" $
    roundTrip (Map.singleton (QualifiedName "" "main") (BlockId 0))

  it "round-trips a QualifiedName key with a module path" $
    roundTrip (Map.singleton (QualifiedName "foo.bar" "baz") (BlockId 1))
