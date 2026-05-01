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
  blockKindSpec
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
            { kind = BlockAgentEntry,
              captures = [],
              parameters = [Param {label = "x", var = VarId 0}],
              stateVars = [],
              statements = [],
              trailing = Just (VarId 1),
              thenBlock = Nothing,
              handlers = []
            }
    BlockUser {body = userBlock}
      `shouldEncodeAs` object
        [ "kind" .= ("blockUser" :: String),
          "body"
            .= object
              [ "kind" .= ("blockAgentEntry" :: String),
                "captures" .= ([] :: [Value]),
                "parameters" .= [object ["label" .= ("x" :: String), "var" .= (0 :: Int)]],
                "stateVars" .= ([] :: [Value]),
                "statements" .= ([] :: [Value]),
                "trailing" .= (1 :: Int),
                "handlers" .= ([] :: [Value])
              ]
        ]

  it "BlockPrim has only kind + name" $ do
    BlockPrim {name = "add"}
      `shouldEncodeAs` object ["kind" .= ("blockPrim" :: String), "name" .= ("add" :: String)]

  it "BlockRequest carries kind + reqId" $ do
    BlockRequest {reqId = ReqId 7}
      `shouldEncodeAs` object ["kind" .= ("blockRequest" :: String), "reqId" .= (7 :: Int)]

  it "BlockExternal carries kind + externalName" $ do
    BlockExternal {externalName = ExternalName (QualifiedName "discord" "send_message")}
      `shouldEncodeAs` object
        [ "kind" .= ("blockExternal" :: String),
          "externalName" .= object ["module_" .= ("discord" :: String), "name" .= ("send_message" :: String)]
        ]

  it "BlockCtor carries kind + ctorId" $ do
    BlockCtor {ctorId = CtorId 3}
      `shouldEncodeAs` object ["kind" .= ("blockCtor" :: String), "ctorId" .= (3 :: Int)]

  it "round-trips all variants" $ do
    let userBody =
          UserBlock
            { kind = BlockInline,
              captures = [],
              parameters = [],
              stateVars = [],
              statements = [],
              trailing = Nothing,
              thenBlock = Nothing,
              handlers = []
            }
    roundTrip BlockUser {body = userBody}
    roundTrip BlockPrim {name = "add"}
    roundTrip BlockRequest {reqId = ReqId 7}
    roundTrip (BlockExternal (ExternalName (QualifiedName "discord" "send")))
    roundTrip BlockCtor {ctorId = CtorId 3}

blockKindSpec :: Spec
blockKindSpec = describe "BlockKind" $ do
  it "serializes each variant as a bare camelCase string" $ do
    Aeson.toJSON BlockAgentEntry `shouldBe` Aeson.String "blockAgentEntry"
    Aeson.toJSON BlockAgentEntryWithHandlers `shouldBe` Aeson.String "blockAgentEntryWithHandlers"
    Aeson.toJSON BlockHandleScope `shouldBe` Aeson.String "blockHandleScope"
    Aeson.toJSON BlockInline `shouldBe` Aeson.String "blockInline"
    Aeson.toJSON BlockHandlerBody `shouldBe` Aeson.String "blockHandlerBody"

  it "round-trips all variants" $ do
    mapM_
      roundTrip
      [ BlockAgentEntry,
        BlockAgentEntryWithHandlers,
        BlockHandleScope,
        BlockInline,
        BlockHandlerBody
      ]

statementSpec :: Spec
statementSpec = describe "Statement (sum)" $ do
  it "StatementCall nests CallData under 'contents'" $ do
    StatementCall
      CallData
        { target = CallTargetBlock {block = BlockId 7},
          arguments = [Arg {label = "x", var = VarId 1}],
          output = Just (VarId 2)
        }
      `shouldEncodeAs` object
        [ "kind" .= ("statementCall" :: String),
          "contents"
            .= object
              [ "target" .= object ["kind" .= ("callTargetBlock" :: String), "block" .= (7 :: Int)],
                "arguments" .= [object ["label" .= ("x" :: String), "var" .= (1 :: Int)]],
                "output" .= (2 :: Int)
              ]
        ]

  it "StatementMakeClosure nests MakeClosureData under 'contents'" $ do
    StatementMakeClosure MakeClosureData {output = VarId 3, block = BlockId 12, captures = []}
      `shouldEncodeAs` object
        [ "kind" .= ("statementMakeClosure" :: String),
          "contents"
            .= object
              [ "output" .= (3 :: Int),
                "block" .= (12 :: Int),
                "captures" .= ([] :: [()])
              ]
        ]

  it "StatementExit nests ExitData under 'contents' (with exitKind enum)" $ do
    StatementExit ExitData {exitKind = ExitKindReturn, value = VarId 4}
      `shouldEncodeAs` object
        [ "kind" .= ("statementExit" :: String),
          "contents"
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
          modifiers = [("acc", VarId 5)]
        }
      `shouldEncodeAs` object
        [ "kind" .= ("statementCont" :: String),
          "contents"
            .= object
              [ "contKind" .= ("contKindForNext" :: String),
                "modifiers" .= [["acc" :: Aeson.Value, Aeson.Number 5]]
              ]
        ]

  it "StatementMatch round-trips" $ do
    roundTrip $
      StatementMatch
        MatchData
          { subject = VarId 1,
            arms =
              [ MatchArm
                  { pattern = MatchPatternConstructor (CtorId 7) [("x", MatchPatternVariable (VarId 2))],
                    body = BlockId 3
                  }
              ],
            defaultArm = Just (BlockId 4),
            output = Just (VarId 5)
          }

  it "StatementFor round-trips" $ do
    roundTrip $
      StatementFor
        ForData
          { iters = [(VarId 1, VarId 2)],
            stateInits = [("acc", VarId 3)],
            bodyBlock = BlockId 4,
            thenBlock = Just (BlockId 5),
            output = Just (VarId 6)
          }

  it "StatementLoadLiteral nests an inner literal value object" $ do
    StatementLoadLiteral LoadLiteralData {output = VarId 5, value = LiteralValueInteger 42}
      `shouldEncodeAs` object
        [ "kind" .= ("statementLoadLiteral" :: String),
          "contents"
            .= object
              [ "output" .= (5 :: Int),
                "value" .= object ["kind" .= ("literalValueInteger" :: String), "integer" .= (42 :: Int)]
              ]
        ]

  it "round-trips all 7 statement variants" $ do
    roundTrip $
      StatementCall
        CallData
          { target = CallTargetValue (VarId 0),
            arguments = [],
            output = Nothing
          }
    roundTrip $ StatementMakeClosure MakeClosureData {output = VarId 0, block = BlockId 0, captures = []}
    roundTrip $
      StatementLoadLiteral LoadLiteralData {output = VarId 0, value = LiteralValueInteger 0}
    roundTrip $
      StatementMatch MatchData {subject = VarId 0, arms = [], defaultArm = Nothing, output = Nothing}
    roundTrip $
      StatementFor
        ForData
          { iters = [],
            stateInits = [],
            bodyBlock = BlockId 0,
            thenBlock = Nothing,
            output = Nothing
          }
    roundTrip $ StatementExit ExitData {exitKind = ExitKindBreak, value = VarId 0}
    roundTrip $ StatementCont ContData {contKind = ContKindNext, value = Just (VarId 0), modifiers = []}

  it "round-trips all LiteralValue variants" $ do
    roundTrip (LiteralValueInteger 42)
    roundTrip (LiteralValueNumber 3.14)
    roundTrip (LiteralValueString "hello")
    roundTrip (LiteralValueBoolean True)
    roundTrip LiteralValueNull

callTargetSpec :: Spec
callTargetSpec = describe "CallTarget" $ do
  it "CallTargetBlock encodes as kind=block" $ do
    CallTargetBlock (BlockId 5)
      `shouldEncodeAs` object ["kind" .= ("callTargetBlock" :: String), "block" .= (5 :: Int)]

  it "CallTargetValue encodes as kind=value" $ do
    CallTargetValue (VarId 7)
      `shouldEncodeAs` object ["kind" .= ("callTargetValue" :: String), "var" .= (7 :: Int)]

  it "round-trips both variants" $ do
    roundTrip (CallTargetBlock (BlockId 0))
    roundTrip (CallTargetValue (VarId 0))

exitContSpec :: Spec
exitContSpec = describe "ExitKind / ContKind" $ do
  it "ExitKind serializes as bare strings" $ do
    Aeson.toJSON ExitKindReturn `shouldBe` Aeson.String "exitKindReturn"
    Aeson.toJSON ExitKindBreak `shouldBe` Aeson.String "exitKindBreak"
    Aeson.toJSON ExitKindForBreak `shouldBe` Aeson.String "exitKindForBreak"

  it "ContKind serializes as bare strings" $ do
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
              (CtorId 5)
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
            { body =
                UserBlock
                  { kind = BlockAgentEntry,
                    captures = [],
                    parameters = [],
                    stateVars = [],
                    statements = [StatementExit ExitData {exitKind = ExitKindReturn, value = VarId 0}],
                    trailing = Nothing,
                    thenBlock = Nothing,
                    handlers = []
                  }
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
