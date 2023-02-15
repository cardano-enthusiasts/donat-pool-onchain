{-# LANGUAGE QualifiedDo #-}

module Protocol.Validator where

import Ext.Plutarch.Extra.ApiV2
import Ext.Plutarch.Extra.Time
import Ext.Plutus.MinAda
import Fundraising.Datum
import Fundraising.Model (Fundraising (Fundraising))
import Generics.SOP
import Plutarch.Api.V1.Value
import Plutarch.Api.V2
import Plutarch.Bool
import Plutarch.Builtin
import Plutarch.DataRepr
import Plutarch.Extra.Interval
import Plutarch.Extra.TermCont
import qualified Plutarch.Monadic as P
import Plutarch.Prelude
import PlutusCore (Closed)
import qualified PlutusCore as PLC
import Protocol.Datum
import Protocol.Model
import Protocol.Redeemer
import Shared.Checks
import Shared.ScriptContextV2

-- TODO: Add config values validation for updateProtocol
-- validate config values:
-- -- minPoolSize >= minAdaTxOutAmount
-- -- maxPoolSize ?
-- -- minDuration >= 1 day
-- -- maxDuration <= 90 days
-- -- fee > 0 and < 100 %

protocolValidator :: ClosedTerm (PProtocol :--> PValidator)
protocolValidator = plam $ \protocol datm redm ctx -> P.do
  (dat, _) <- ptryFrom @PProtocolDatum datm
  (red, _) <- ptryFrom @PProtocolRedeemer redm
  let txInfo = getCtxInfoForSpending # ctx
  let protocolOutput = getOnlyOneOwnOutput # ctx
  pmatch red $ \case
    PUpdateProtocolConfig redData -> popaque . unTermCont $ do
      checkSignedByManager protocol ctx
      checkUpdateProtocolOutput protocol dat ctx
      pure $ pconstant ()
    PStartFundrise redData -> popaque . unTermCont $ do
      let fundriseConfig = pfield @"_0" # redData
      let fundriseAddress = pfield @"scriptAddress" # fundriseConfig
      let fundriseOutput = getOutputByAddress # ctx # fundriseAddress
      checkProtocolValueNotChanged protocol ctx protocolOutput
      checkProtocolDatumNotChanged dat ctx protocolOutput
      checkFrTokensMinted fundriseConfig txInfo
      checkFundriseOutputDatum dat fundriseConfig fundriseOutput ctx
      checkFundriseOutputValue fundriseConfig fundriseOutput
      pure $ pconstant ()
    PCloseProtocol _ -> popaque . unTermCont $ do
      checkNoOutputs ctx
      checkNftBurned protocol txInfo
      pure $ pconstant ()

checkSignedByManager :: Term s PProtocol -> Term s PScriptContext -> TermCont s ()
checkSignedByManager protocol ctx' = do
  let txInfo = getCtxInfoForSpending # ctx'
  let managerPkh = pfield @"managerPkh" # protocol
  checkIsSignedBy "111" managerPkh txInfo

checkUpdateProtocolOutput :: Term s PProtocol -> Term s PProtocolDatum -> Term s PScriptContext -> TermCont s ()
checkUpdateProtocolOutput protocol inDatum ctx = do
  let output = getOnlyOneOwnOutput # ctx
  checkUpdateProtocolDatum inDatum ctx output
  checkProtocolValueNotChanged protocol ctx output
  pure ()

checkUpdateProtocolDatum :: Term s PProtocolDatum -> Term s PScriptContext -> Term s PTxOut -> TermCont s ()
checkUpdateProtocolDatum inDatum ctx txOut = do
  let outDatum' = inlineDatumFromOutput # ctx # txOut
  (outDatum, _) <- ptryFromC @PProtocolDatum outDatum'
  pguardC "112" (pfield @"managerPkh" # inDatum #== pfield @"managerPkh" # outDatum)
  pguardC "113" (pfield @"tokenOriginRef" # inDatum #== pfield @"tokenOriginRef" # outDatum)
  pguardC "114" (pnot #$ inDatum #== outDatum)
  pure ()

checkProtocolValueNotChanged :: Term s PProtocol -> Term s PScriptContext -> Term s PTxOut -> TermCont s ()
checkProtocolValueNotChanged protocol ctx txOut = do
  let inValue = getOwnInputValue # ctx
  let outValue = pfield @"value" # txOut
  pguardC "115" (inValue #== outValue)
  let threadTokenAmount = pvalueOf # outValue # protocolSymbol protocol # protocolToken protocol
  pguardC "116" (threadTokenAmount #== 1)
  pure ()

checkNftBurned :: Term s PProtocol -> Term s (PAsData PTxInfo) -> TermCont s ()
checkNftBurned protocol = checkNftMinted "123" (-1) (protocolSymbol protocol) (protocolToken protocol)

checkProtocolDatumNotChanged :: Term s PProtocolDatum -> Term s PScriptContext -> Term s PTxOut -> TermCont s ()
checkProtocolDatumNotChanged inDatum ctx txOut = do
  let outDatum' = inlineDatumFromOutput # ctx # txOut
  (outDatum, _) <- ptryFromC @PProtocolDatum outDatum'
  pguardC "117" (inDatum #== outDatum)
  pure ()

checkFrTokensMinted :: Term s PFundriseConfig -> Term s (PAsData PTxInfo) -> TermCont s ()
checkFrTokensMinted frConfig = do
  checkNftMinted "124" 1 (pfield @"verCurrencySymbol" # frConfig) (pfield @"verTokenName" # frConfig)
  checkNftMinted "125" 1 (pfield @"threadCurrencySymbol" # frConfig) (pfield @"threadTokenName" # frConfig)

checkFundriseOutputDatum ::
  Term s PProtocolDatum ->
  Term s PFundriseConfig ->
  Term s PTxOut ->
  Term s PScriptContext ->
  TermCont s ()
checkFundriseOutputDatum protocolDatum frConfig frTxOut ctx = do
  let frOutDatum' = inlineDatumFromOutput # ctx # frTxOut
  (frOutDatum, _) <- ptryFromC @PFundraisingDatum frOutDatum'
  pguardC "118" (pfield @"frFee" # frOutDatum #== pfield @"protocolFee" # protocolDatum)

  let minAmount = pfromData $ pfield @"minAmount" # protocolDatum
  let maxAmount = pfromData $ pfield @"maxAmount" # protocolDatum
  let frAmount = pfromData $ pfield @"frAmount" # frOutDatum
  pguardC "119" (minAmount #<= frAmount #&& frAmount #<= maxAmount)

  let frStartedAt = pfield @"startedAt" # frConfig
  let frDeadline = pfield @"frDeadline" # frOutDatum

  let minDurationDays = pfromData $ pfield @"minDuration" # protocolDatum
  let minDurationMs = daysToMilliseconds # minDurationDays
  let minDurationPosix = toPosixTime # minDurationMs
  let minDuration = addTimes # frStartedAt # pdata minDurationPosix

  let maxDurationDays = pfromData $ pfield @"maxDuration" # protocolDatum
  let maxDurationMs = daysToMilliseconds # maxDurationDays
  let maxDurationPosix = toPosixTime # maxDurationMs
  let maxDuration = addTimes # frStartedAt # pdata maxDurationPosix

  let permittedDuration = pinterval # minDuration # maxDuration

  pguardC "126" (pmember # frDeadline # permittedDuration)

  pure ()

checkFundriseOutputValue :: Term s PFundriseConfig -> Term s PTxOut -> TermCont s ()
checkFundriseOutputValue frConfig frTxOut = do
  let value = pfield @"value" # frTxOut
  let adaAmount = plovelaceValueOf # value
  checkNftIsInValue "120" (pfield @"verCurrencySymbol" # frConfig) (pfield @"verTokenName" # frConfig) value
  checkNftIsInValue "121" (pfield @"threadCurrencySymbol" # frConfig) (pfield @"threadTokenName" # frConfig) value
  pguardC "122" (adaAmount #== minTxOut)
