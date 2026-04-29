-- | Stage 0: JSON round-trip tests for the IR data types.
--
-- 目的: 全 sum variant が ToJSON → FromJSON で安定し、JSON shape が想定通りである
-- ことを確認する。Lowering の出力品質は別 spec で検証する。
module Katari.IRSpec (spec) where

import Data.Aeson (Value, decode, encode, object, (.=))
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
  it "BlockUser flattens UserBlock fields next to kind" $ do
    let userBlock =
          UserBlock
            { params = [Param {label = "x", var = VarId 0}],
              stateVars = [],
              statements = [],
              trailing = Just (VarId 1),
              thenBlock = Nothing,
              handlers = [],
              props = BlockProps {catchesReturn = True, catchesBreak = False, inheritScope = False}
            }
    BlockUser {body = userBlock}
      `shouldEncodeAs` object
        [ "kind" .= ("user" :: String),
          "params" .= [object ["label" .= ("x" :: String), "var" .= (0 :: Int)]],
          "stateVars" .= ([] :: [Value]),
          "statements" .= ([] :: [Value]),
          "trailing" .= (1 :: Int),
          "handlers" .= ([] :: [Value]),
          "props" .= object ["catchesReturn" .= True, "catchesBreak" .= False, "inheritScope" .= False]
        ]

  it "BlockPrim has only kind + name" $ do
    BlockPrim {name = "add"}
      `shouldEncodeAs` object ["kind" .= ("prim" :: String), "name" .= ("add" :: String)]

  it "BlockRequest has only kind + name" $ do
    BlockRequest {name = "Ask"}
      `shouldEncodeAs` object ["kind" .= ("request" :: String), "name" .= ("Ask" :: String)]

  it "BlockExternal has kind + moduleName + name" $ do
    BlockExternal "discord" "send_message"
      `shouldEncodeAs` object
        [ "kind" .= ("external" :: String),
          "moduleName" .= ("discord" :: String),
          "name" .= ("send_message" :: String)
        ]

  it "BlockCtor has only kind + name" $ do
    BlockCtor {name = "Foo"}
      `shouldEncodeAs` object ["kind" .= ("ctor" :: String), "name" .= ("Foo" :: String)]

  it "round-trips all variants" $ do
    let userBody =
          UserBlock
            { params = [],
              stateVars = [],
              statements = [],
              trailing = Nothing,
              thenBlock = Nothing,
              handlers = [],
              props = BlockProps {catchesReturn = False, catchesBreak = False, inheritScope = True}
            }
    roundTrip BlockUser {body = userBody}
    roundTrip BlockPrim {name = "add"}
    roundTrip BlockRequest {name = "Ask"}
    roundTrip (BlockExternal "discord" "send")
    roundTrip BlockCtor {name = "Foo"}

statementSpec :: Spec
statementSpec = describe "Statement (sum)" $ do
  it "SCall encodes with kind=call" $ do
    SCall
      CallData
        { target = CTBlock {block = BlockId 7},
          args = [Arg {label = "x", var = VarId 1}],
          output = Just (VarId 2)
        }
      `shouldEncodeAs` object
        [ "kind" .= ("call" :: String),
          "target" .= object ["kind" .= ("block" :: String), "block" .= (7 :: Int)],
          "args" .= [object ["label" .= ("x" :: String), "var" .= (1 :: Int)]],
          "output" .= (2 :: Int)
        ]

  it "SMakeClosure encodes with kind=makeClosure" $ do
    SMakeClosure MakeClosureData {output = VarId 3, block = BlockId 12}
      `shouldEncodeAs` object
        [ "kind" .= ("makeClosure" :: String),
          "output" .= (3 :: Int),
          "block" .= (12 :: Int)
        ]

  it "SExit encodes with kind=exit and exitKind enum" $ do
    SExit ExitData {exitKind = ExitReturn, value = VarId 4}
      `shouldEncodeAs` object
        [ "kind" .= ("exit" :: String),
          "exitKind" .= ("return" :: String),
          "value" .= (4 :: Int)
        ]

  it "SCont (forNext) omits value when Nothing" $ do
    SCont
      ContData
        { contKind = ContForNext,
          value = Nothing,
          mods = [("acc", VarId 5)]
        }
      `shouldEncodeAs` object
        [ "kind" .= ("cont" :: String),
          "contKind" .= ("forNext" :: String),
          "mods" .= [["acc" :: Aeson.Value, Aeson.Number 5]]
        ]

  it "SMatch round-trips" $ do
    roundTrip $
      SMatch
        MatchData
          { subject = VarId 1,
            arms =
              [ MatchArm
                  { tag = Just "Foo",
                    bindings = [("x", VarId 2)],
                    body = BlockId 3
                  }
              ],
            defaultArm = Just (BlockId 4),
            output = Just (VarId 5)
          }

  it "SFor round-trips" $ do
    roundTrip $
      SFor
        ForData
          { iters = [(VarId 1, VarId 2)],
            stateInits = [("acc", VarId 3)],
            bodyBlock = BlockId 4,
            thenBlock = Just (BlockId 5),
            output = Just (VarId 6)
          }

  it "SLoadLiteral encodes with kind=loadLiteral and an inner value object" $ do
    SLoadLiteral LoadLiteralData {output = VarId 5, value = LVInteger 42}
      `shouldEncodeAs` object
        [ "kind" .= ("loadLiteral" :: String),
          "output" .= (5 :: Int),
          "value" .= object ["kind" .= ("integer" :: String), "value" .= (42 :: Int)]
        ]

  it "round-trips all 7 statement variants" $ do
    roundTrip $
      SCall
        CallData
          { target = CTValue (VarId 0),
            args = [],
            output = Nothing
          }
    roundTrip $ SMakeClosure MakeClosureData {output = VarId 0, block = BlockId 0}
    roundTrip $
      SLoadLiteral LoadLiteralData {output = VarId 0, value = LVInteger 0}
    roundTrip $
      SMatch MatchData {subject = VarId 0, arms = [], defaultArm = Nothing, output = Nothing}
    roundTrip $
      SFor
        ForData
          { iters = [],
            stateInits = [],
            bodyBlock = BlockId 0,
            thenBlock = Nothing,
            output = Nothing
          }
    roundTrip $ SExit ExitData {exitKind = ExitBreak, value = VarId 0}
    roundTrip $ SCont ContData {contKind = ContNext, value = Just (VarId 0), mods = []}

  it "round-trips all LiteralValue variants" $ do
    roundTrip (LVInteger 42)
    roundTrip (LVNumber 3.14)
    roundTrip (LVString "hello")
    roundTrip (LVBoolean True)
    roundTrip LVNull

callTargetSpec :: Spec
callTargetSpec = describe "CallTarget" $ do
  it "CTBlock encodes as kind=block" $ do
    CTBlock (BlockId 5)
      `shouldEncodeAs` object ["kind" .= ("block" :: String), "block" .= (5 :: Int)]

  it "CTValue encodes as kind=value" $ do
    CTValue (VarId 7)
      `shouldEncodeAs` object ["kind" .= ("value" :: String), "var" .= (7 :: Int)]

  it "round-trips both variants" $ do
    roundTrip (CTBlock (BlockId 0))
    roundTrip (CTValue (VarId 0))

exitContSpec :: Spec
exitContSpec = describe "ExitKind / ContKind" $ do
  it "ExitKind serializes as bare strings" $ do
    Aeson.toJSON ExitReturn `shouldBe` Aeson.String "return"
    Aeson.toJSON ExitBreak `shouldBe` Aeson.String "break"
    Aeson.toJSON ExitForBreak `shouldBe` Aeson.String "forBreak"

  it "ContKind serializes as bare strings" $ do
    Aeson.toJSON ContNext `shouldBe` Aeson.String "next"
    Aeson.toJSON ContForNext `shouldBe` Aeson.String "forNext"

  it "round-trips all enum values" $ do
    mapM_ roundTrip [ExitReturn, ExitBreak, ExitForBreak]
    mapM_ roundTrip [ContNext, ContForNext]

matchArmSpec :: Spec
matchArmSpec = describe "MatchArm" $ do
  it "omits null tag" $ do
    MatchArm {tag = Nothing, bindings = [], body = BlockId 0}
      `shouldEncodeAs` object
        [ "bindings" .= ([] :: [Value]),
          "body" .= (0 :: Int)
        ]

  it "round-trips with bindings" $ do
    roundTrip
      MatchArm
        { tag = Just "Cons",
          bindings = [("head", VarId 1), ("tail", VarId 2)],
          body = BlockId 3
        }

moduleSpec :: Spec
moduleSpec = describe "IRModule" $ do
  it "round-trips an empty module" $ do
    roundTrip
      IRModule
        { name = "main",
          blocks = Map.empty,
          entries = Map.empty,
          nameTable = emptyNameTable
        }

  it "round-trips a small module with one block" $ do
    let block =
          BlockUser
            { body =
                UserBlock
                  { params = [],
                    stateVars = [],
                    statements = [SExit ExitData {exitKind = ExitReturn, value = VarId 0}],
                    trailing = Nothing,
                    thenBlock = Nothing,
                    handlers = [],
                    props =
                      BlockProps
                        { catchesReturn = True,
                          catchesBreak = False,
                          inheritScope = False
                        }
                  }
            }
    roundTrip
      IRModule
        { name = "main",
          blocks = Map.singleton (BlockId 0) block,
          entries = Map.singleton "main" (BlockId 0),
          nameTable =
            NameTable
              { varNames = Map.singleton (VarId 0) "x",
                blockNames = Map.singleton (BlockId 0) "main"
              }
        }
