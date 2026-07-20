module Katari.Cli.ApiSpec (spec) where

import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.Either (isLeft)
import Data.Text (Text)
import Katari.Cli.Api (EscalationPresentation (..), EscalationView (..))
import Test.Hspec

-- | Decode an escalation view from the runtime's wire shape (the @data@ payload, not the envelope).
decodeEscalation :: ByteString -> Either String EscalationView
decodeEscalation = Aeson.eitherDecodeStrict'

spec :: Spec
spec = do
  describe "EscalationView presentation" $ do
    it "decodes a form presentation, reading answerSchema out of the variant" $
      case decodeEscalation formPayload of
        Left message -> expectationFailure message
        Right escalation -> do
          escalation.request `shouldBe` "prelude.ask"
          escalation.presentation `shouldBe` PresentationForm (Just stringSchema)

    it "decodes a form presentation with no answerSchema as PresentationForm Nothing" $
      case decodeEscalation formNoSchemaPayload of
        Left message -> expectationFailure message
        Right escalation -> escalation.presentation `shouldBe` PresentationForm Nothing

    it "decodes an oauth presentation carrying the server url and credential name" $
      case decodeEscalation oauthPayload of
        Left message -> expectationFailure message
        Right escalation ->
          escalation.presentation `shouldBe` PresentationOauth {url = Just "https://mcp.example.test/mcp", name = "github"}

    it "decodes a configured oauth presentation whose url is null as Nothing" $
      case decodeEscalation oauthNoUrlPayload of
        Left message -> expectationFailure message
        Right escalation ->
          escalation.presentation `shouldBe` PresentationOauth {url = Nothing, name = "stripe"}

    it "rejects an unknown presentation kind rather than guessing" $
      decodeEscalation unknownKindPayload `shouldSatisfy` isLeft
  where
    stringSchema :: Value
    stringSchema = object ["type" .= ("string" :: Text)]

    formPayload :: ByteString
    formPayload =
      "{\"id\":\"esc-1\",\"request\":\"prelude.ask\",\"argument\":{\"q\":1},\"runId\":\"run-1\",\"createdAt\":\"2026-07-13T00:00:00.000Z\",\"presentation\":{\"kind\":\"form\",\"answerSchema\":{\"type\":\"string\"}}}"

    formNoSchemaPayload :: ByteString
    formNoSchemaPayload =
      "{\"id\":\"esc-2\",\"request\":\"prelude.ask\",\"runId\":\"run-1\",\"createdAt\":\"2026-07-13T00:00:00.000Z\",\"presentation\":{\"kind\":\"form\"}}"

    oauthPayload :: ByteString
    oauthPayload =
      "{\"id\":\"esc-3\",\"request\":\"prelude.oauth.authorize\",\"argument\":{\"url\":\"https://mcp.example.test/mcp\",\"name\":\"github\"},\"runId\":\"run-1\",\"createdAt\":\"2026-07-13T00:00:00.000Z\",\"presentation\":{\"kind\":\"oauth\",\"url\":\"https://mcp.example.test/mcp\",\"name\":\"github\"}}"

    -- A configured credential authorizes against an operator-registered endpoint, so its escalation
    -- carries no server url to show a human — the presentation url arrives as null and decodes to Nothing.
    oauthNoUrlPayload :: ByteString
    oauthNoUrlPayload =
      "{\"id\":\"esc-5\",\"request\":\"prelude.oauth.authorize\",\"argument\":{\"name\":\"stripe\"},\"runId\":\"run-1\",\"createdAt\":\"2026-07-13T00:00:00.000Z\",\"presentation\":{\"kind\":\"oauth\",\"url\":null,\"name\":\"stripe\"}}"

    unknownKindPayload :: ByteString
    unknownKindPayload =
      "{\"id\":\"esc-4\",\"request\":\"prelude.ask\",\"runId\":\"run-1\",\"createdAt\":\"2026-07-13T00:00:00.000Z\",\"presentation\":{\"kind\":\"carrier-pigeon\"}}"
