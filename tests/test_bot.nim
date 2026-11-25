## The scripted baseline must play whole episodes without ever proposing
## an illegal message or pick — it is an explicitly chosen policy for
## opponents and offline certification. Two scripted seats must also
## actually converge on the fixed code, or the baseline is no partner
## worth adapting to.

import std/[json, monotimes, times, unicode, unittest]
import babel/[llm, sim]

proc fixture(seed: int, rounds = 24): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.rounds = rounds
  result.sampled = true
  for index in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("t" & $index)

proc playScripted(config: GameConfig): Sim =
  let client = newScriptedClient(config.seed)
  result = initSim(config)
  while not result.done:
    let call = result.currentCall()
    case call.kind
    of ckRound:
      result.beginRound()
    of ckSpeak:
      let decision = client.scriptedAction(result, call)
      ## The bot's message must be legal as-is: applySpeak raises on
      ## anything else and would fail this test.
      result.applySpeak(call.pair, decision.tokens, decision.notes, true)
      check decision.notes.len == 0
    of ckPick:
      let decision = client.scriptedAction(result, call)
      result.applyPick(call.pair, decision.pick, decision.notes, true)
      check decision.notes.len == 0
    of ckNone:
      discard

suite "scripted baseline":
  test "four scripted seats play full episodes legally and fast":
    for seed in [1, 7, 42, 1234]:
      let config = fixture(seed)
      let started = getMonoTime()
      let sim = playScripted(config)
      let elapsed = (getMonoTime() - started).inMilliseconds
      check sim.done
      check sim.reason == "complete"
      check sim.roundsPlayed == config.rounds
      var picks = 0
      for event in sim.events:
        if event.kind == evPick:
          inc picks
      check picks == config.rounds * 2
      echo "seed ", seed, ": ", sim.roundsPlayed, " rounds, correct ",
        sim.correct, ", ", elapsed, " ms"
      check elapsed < config.rounds * 1000
      let results = sim.resultsJson()
      for seat in 0 ..< Seats:
        check results["scores"][seat].getFloat() >= 0.0
        check results["scores"][seat].getFloat() <= 1.0
      for seat in 0 ..< Seats:
        check sim.seatRounds[seat] == config.rounds

  test "scripted pairs converge: success above 0.75 after 12 rounds":
    var successes = 0
    var total = 0
    for seed in [1, 7, 42, 1234]:
      let sim = playScripted(fixture(seed, rounds = 24))
      for event in sim.events:
        if event.kind == evPick and event.round >= 12:
          inc total
          if event.correct:
            inc successes
    let rate = successes.float / total.float
    echo "scripted-with-scripted success after 12 rounds: ", successes, "/",
      total, " = ", rate
    check rate > 0.75

  test "scripted client advances its source-controlled policy":
    let config = fixture(3, rounds = 4)
    let client = newScriptedClient(config.seed)
    var sim = initSim(config)
    sim.beginRound()
    let spoken = client.scriptedAction(sim, sim.currentCall())
    check spoken.tokens == scriptedMessage(sim.plan.targets[0])
    sim.applySpeak(0, spoken.tokens, spoken.notes, true)
    let picked = client.scriptedAction(sim, sim.currentCall())
    sim.applyPick(0, picked.pick, picked.notes, true)
    check sim.currentCall() == (ckSpeak, 1, sim.plan.speakers[1])

  test "canonical actions parse strictly and support outer Markdown JSON fences":
    let config = fixture(0)
    var sim = initSim(config)
    sim.beginRound()
    let seat = sim.plan.speakers[0]
    let g3 = sim.glyphOf(seat, 3)
    let g9 = sim.glyphOf(seat, 9)
    let g14 = sim.glyphOf(seat, 14)
    let arrayJson = """{"tokens":["""" & g3 & """","""" & g9 & """","""" & g14 & """"],"notes":"first = shape"}"""
    let arrayReply = parseSpeak(sim, seat, extractJsonObject(arrayJson))
    check arrayReply.tokens == @[3, 9, 14]
    check arrayReply.notes == "first = shape"
    ## Standard outer Markdown JSON fences are supported.
    let fenced = extractJsonObject("```json\n" & arrayJson & "\n```")
    check parseSpeak(sim, seat, fenced).tokens == @[3, 9, 14]
    let plainFence = extractJsonObject("```\n{\"pick\":2}\n```")
    check parsePick(plainFence).pick == 2
    for wrapped in ["```{\"pick\":2}```", "```json\n{\"pick\":2}```"]:
      check parsePick(extractJsonObject(wrapped)).pick == 2
    ## Prose-wrapped JSON and non-object JSON are rejected.
    expect BabelError:
      discard extractJsonObject("Here is my move: {\"pick\":2}")
    expect BabelError:
      discard extractJsonObject("{\"pick\":2} thanks")
    expect BabelError:
      discard extractJsonObject("[0, 1]")
    ## The same glyphs mean different tokens from another seat's view.
    let other = sim.plan.listeners[0]
    let crossed = parseSpeak(sim, other, parseJson(arrayJson))
    check crossed.tokens != @[3, 9, 14]
    ## Redundant speaker aliases and malformed fields are rejected.
    expect BabelError:
      discard parseSpeak(sim, seat, parseJson(
        """{"tokens":"""" & g3 & " " & g9 & " " & g14 & """"}"""))
    expect BabelError:
      discard parseSpeak(sim, seat, parseJson("""{"tokens":[]}"""))
    expect BabelError:
      discard parseSpeak(sim, seat, parseJson("""{"tokens":["Z"]}"""))
    expect BabelError:
      discard parseSpeak(sim, seat, parseJson(
        """{"tokens":["""" & g3 & sim.glyphOf(seat, 4) & """"]}"""))
    expect BabelError:
      discard parseSpeak(sim, seat, parseJson("""{"notes":"?"}"""))
    expect BabelError:
      discard parseSpeak(sim, seat, parseJson(
        """{"tokens":["""" & g3 & """"],"notes":123}"""))
    ## Canonical listener pick is integer 0..3 with optional string notes.
    check parsePick(parseJson("""{"pick":0}""")).pick == 0
    check parsePick(parseJson("""{"pick":2}""")).pick == 2
    check parsePick(parseJson("""{"pick":3,"notes":"x"}""")).notes == "x"
    ## Letter/string/1-based aliases and out-of-range picks are rejected.
    for bad in [
      """{"pick":"A"}""",
      """{"pick":"B"}""",
      """{"pick":"d"}""",
      """{"pick":"C) 3 green circles"}""",
      """{"pick":"0"}""",
      """{"pick":"1"}""",
      """{"pick":4}""",
      """{"pick":-1}""",
      """{"pick":7}""",
      """{"pick":1,"notes":42}""",
      """{"notes":"no pick"}"""
    ]:
      expect BabelError:
        discard parsePick(parseJson(bad))
    var long = ""
    for index in 0 ..< 700:
      long.add("é")
    check cleanNotes(long).runeLen == MaxNotesLen

  test "rejected actions apply no legal move and leave simulation untouched":
    var sim = initSim(fixture(7, rounds = 4))
    sim.beginRound()
    let speakCall = sim.currentCall()
    let eventsBeforeSpeak = sim.events.len
    let speakRes = sim.resolveAction(speakCall, "not json", false)
    check not speakRes.accepted
    check speakRes.rejection.len > 0
    check sim.events.len == eventsBeforeSpeak
    check sim.currentCall() == speakCall
    check sim.tokens[speakCall.pair].len == 0
    ## Apply a valid speak, then verify rejected listener pick leaves sim untouched.
    let validSpeak = sim.resolveAction(speakCall,
      """{"tokens":["""" & sim.glyphOf(speakCall.seat, 0) & """"]}""", false)
    check validSpeak.accepted
    let pickCall = sim.currentCall()
    let eventsBeforePick = sim.events.len
    let pickRes = sim.resolveAction(pickCall, """{"pick":"A"}""", false)
    check not pickRes.accepted
    check pickRes.rejection.len > 0
    check sim.events.len == eventsBeforePick
    check sim.currentCall() == pickCall
    check sim.picks[pickCall.pair] == -1
    check not sim.corrects[pickCall.pair]
