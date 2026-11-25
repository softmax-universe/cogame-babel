## Game-owned action parsing and scripted baseline. No fallback or model transport.

import std/[json, options, random, strutils, tables, unicode]
import sim

const MaxNotesLen* = 600

type
  Decision* = object
    tokens*: seq[int]
    pick*: int
    notes*: string

  ActionResolution* = object
    decision*: Decision
    proposedAction*: JsonNode
    accepted*: bool
    rejection*: string

  ScriptedPolicy* = ref object
    rand: Rand

proc newScriptedPolicy*(seed: int): ScriptedPolicy =
  ScriptedPolicy(rand: initRand(seed xor 0x5EED))

# ---- Scripted baseline ------------------------------------------------------

const
  ## Attribute-value slots for the decoder's association counts: shapes
  ## 0..3, colours 4..7, counts 8..11.
  AttributeSlots = 12

proc attributeSlots(scene: Scene): array[3, int] =
  [scene.shape, 4 + scene.colour, 8 + scene.count]

proc scriptedMessage*(target: int): seq[int] =
  ## The fixed compositional code on token ids: shape, then 4 + colour,
  ## then 8 + count.
  let slots = attributeSlots(sceneOf(target))
  @[slots[0], slots[1], slots[2]]

proc associations(sim: Sim, seat: int):
    array[Tokens, array[AttributeSlots, int]] =
  ## assoc[token][attribute value] counts from this seat's own feedback:
  ## every completed round it was in (either role, any partner) credits
  ## the revealed target's three values to every token of that round's
  ## message. Evidence is pooled across partners rather than keyed per
  ## partner alias: a seat meets each partner only twice per six rounds,
  ## and per-partner tables were measured to reach only ~0.58 success by
  ## round 12 against the ~0.89 of the pooled table.
  var messages: Table[(int, int), seq[int]]
  for event in sim.events:
    case event.kind
    of evSpeak:
      messages[(event.round, event.pair)] = event.tokens
    of evPick:
      if seat != event.seat and seat != event.other:
        continue
      let target = sim.schedule[event.round].targets[event.pair]
      let message = messages.getOrDefault((event.round, event.pair))
      for token in message:
        for slot in attributeSlots(sceneOf(target)):
          inc result[token][slot]
    else:
      discard

proc scriptedPick*(policy: ScriptedPolicy, sim: Sim, pair: int): int =
  ## Count-based decoder: scores each candidate by the summed association
  ## of the message's tokens with the candidate's three values; ties
  ## (including the no-evidence start) break by the seeded RNG.
  let plan = sim.plan
  let assoc = sim.associations(plan.listeners[pair])
  var best = int.low
  var bestPicks: seq[int]
  for index in 0 ..< LineupSize:
    var score = 0
    for token in sim.tokens[pair]:
      for slot in attributeSlots(sceneOf(plan.lineups[pair][index])):
        score += assoc[token][slot]
    if score > best:
      best = score
      bestPicks = @[index]
    elif score == best:
      bestPicks.add(index)
  bestPicks[policy.rand.rand(bestPicks.high)]

proc scriptedAction*(policy: ScriptedPolicy, sim: Sim, call: Call): Decision =
  ## Rule-based baseline: the fixed code as speaker, the count decoder as
  ## listener. Always legal; never produces notes.
  case call.kind
  of ckSpeak:
    result.tokens = scriptedMessage(sim.plan.targets[call.pair])
  of ckPick:
    result.pick = policy.scriptedPick(sim, call.pair)
  else:
    raise newException(BabelError, "no decision is due")


proc cleanNotes*(text: string): string =
  ## Notes over the cap are cut at a rune boundary with the cut marked.
  result = strutils.strip(text)
  if result.runeLen <= MaxNotesLen:
    return
  result = result.runeSubStr(0, MaxNotesLen - 1) & "…"

proc parseNotes(payload: JsonNode): string =
  if not payload.hasKey("notes") or payload["notes"].kind == JNull:
    return ""
  if payload["notes"].kind != JString:
    raise newException(BabelError, "notes must be a string")
  cleanNotes(payload["notes"].getStr())

proc parseSpeak*(sim: Sim, seat: int, payload: JsonNode): Decision =
  ## Maps the canonical speaker JSON onto token ids through the seat's own view:
  ## "tokens" must be an array of 1..8 single glyphs from this seat's alphabet.
  if payload.kind != JObject:
    raise newException(BabelError, "speaker action must be a JSON object")
  result.notes = parseNotes(payload)
  if not payload.hasKey("tokens"):
    raise newException(BabelError, "no tokens in response")
  let node = payload["tokens"]
  if node.kind != JArray:
    raise newException(BabelError, "tokens must be an array of glyphs")
  for entry in node:
    if entry.kind != JString:
      raise newException(BabelError, "tokens must be glyph strings")
    let glyph = entry.getStr()
    if glyph.runeLen != 1:
      raise newException(BabelError,
        "each token must be exactly one glyph: " & glyph.escape)
    result.tokens.add(sim.tokenOf(seat, glyph))
  if result.tokens.len < 1 or result.tokens.len > MaxMessage:
    raise newException(BabelError,
      "a message is 1.." & $MaxMessage & " tokens")

proc parsePick*(payload: JsonNode): Decision =
  ## Canonical listener action: "pick" must be an integer 0..3.
  if payload.kind != JObject:
    raise newException(BabelError, "listener action must be a JSON object")
  result.notes = parseNotes(payload)
  if not payload.hasKey("pick"):
    raise newException(BabelError, "no pick in response")
  let node = payload["pick"]
  if node.kind != JInt:
    raise newException(BabelError, "pick must be an integer 0..3: " & $node)
  let pick = node.getInt()
  if pick < 0 or pick >= LineupSize:
    raise newException(BabelError, "pick must be an integer 0..3: " & $node)
  result.pick = pick

proc actionJson*(sim: Sim, call: Call, decision: Decision): JsonNode =
  ## Canonical wire action after production parsing and execution.
  if call.kind == ckSpeak:
    var glyphs = newJArray()
    for token in decision.tokens:
      glyphs.add(%sim.glyphOf(call.seat, token))
    %*{"tokens": glyphs, "notes": decision.notes}
  else:
    %*{"pick": decision.pick, "notes": decision.notes}

proc tokenIndex(alphabet: JsonNode, glyph: string): int =
  for index in 0 ..< alphabet.len:
    if alphabet[index].getStr() == glyph:
      return index
  raise newException(BabelError, "glyph outside this seat's alphabet")

proc scriptedAction*(view: JsonNode): JsonNode =
  let alphabet = view["alphabet"]
  if view["role"].getStr() == "speaker":
    let scene = sceneOf(view["target"].getInt())
    return %*{"tokens": [
      alphabet[scene.shape],
      alphabet[4 + scene.colour],
      alphabet[8 + scene.count]
    ], "notes": ""}

  var associations: array[Tokens, array[12, int]]
  for round in view["history"]:
    let scene = sceneOf(round["target"].getInt())
    for glyph in round["message"]:
      let token = tokenIndex(alphabet, glyph.getStr())
      inc associations[token][scene.shape]
      inc associations[token][4 + scene.colour]
      inc associations[token][8 + scene.count]
  var best = int.low
  var pick = 0
  for index in 0 ..< view["lineup"].len:
    let scene = sceneOf(view["lineup"][index].getInt())
    var score = 0
    for glyph in view["message"]:
      let token = tokenIndex(alphabet, glyph.getStr())
      score += associations[token][scene.shape]
      score += associations[token][4 + scene.colour]
      score += associations[token][8 + scene.count]
    if score > best:
      best = score
      pick = index
  %*{"pick": pick, "notes": ""}


proc extractJsonObject*(text: string): JsonNode =
  ## Parses a strict JSON object, allowing a single standard outer Markdown JSON fence.
  var candidate = text.strip()
  if candidate.startsWith("```"):
    let nl = candidate.find('\n')
    if nl < 0 or not candidate.endsWith("```"):
      raise newException(BabelError, "malformed Markdown JSON fence")
    let lang = candidate[3 ..< nl].strip().toLowerAscii()
    if lang notin ["", "json"]:
      raise newException(BabelError, "unsupported Markdown fence language: " & lang)
    let inner = candidate[nl + 1 ..< candidate.len - 3]
    if inner.len == 0 or (inner[^1] != '\n' and inner[^1] != '\r'):
      raise newException(BabelError, "closing Markdown fence must be on its own line")
    candidate = inner.strip()
  if candidate.len == 0 or candidate[0] != '{' or candidate[^1] != '}':
    raise newException(BabelError, "response must be a JSON object")
  try:
    result = parseJson(candidate)
  except CatchableError as error:
    raise newException(BabelError, "invalid JSON object: " & error.msg)
  if result.kind != JObject:
    raise newException(BabelError, "response must be a JSON object")


proc resolveAction*(sim: var Sim, call: Call, rawResponse: string,
    scripted: bool, modelResponse = none(string)): ActionResolution =
  ## Shared player/server/bridge action resolution. Rejected actions never
  ## apply or synthesize a legal action and leave the simulation untouched.
  result.accepted = true
  result.proposedAction = newJNull()
  try:
    let payload = extractJsonObject(rawResponse)
    if modelResponse.isSome:
      let sampled = extractJsonObject(modelResponse.get())
      let sampledDecision = if call.kind == ckSpeak:
        sim.parseSpeak(call.seat, sampled) else: parsePick(sampled)
      result.proposedAction = sim.actionJson(call, sampledDecision)
    result.decision = if call.kind == ckSpeak:
      sim.parseSpeak(call.seat, payload) else: parsePick(payload)
    if modelResponse.isSome:
      if result.proposedAction != sim.actionJson(call, result.decision):
        raise newException(BabelError, "model response differs from player action")
    else:
      result.proposedAction = sim.actionJson(call, result.decision)
    if call.kind == ckSpeak:
      sim.applySpeak(call.pair, result.decision.tokens, result.decision.notes,
        scripted)
    else:
      sim.applyPick(call.pair, result.decision.pick, result.decision.notes,
        scripted)
  except CatchableError as error:
    result.accepted = false
    result.rejection = error.msg
