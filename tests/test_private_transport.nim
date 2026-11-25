## Callback ordering regression: close cannot discard queued private HTTP facts.
include ../src/babel/server
import std/[base64, tempfiles, unittest]
import bitworld/native_http
import babel/llm

suite "private external owner lifecycle":
  test "close before queued stop retains facts without acknowledgement credit":
    state = GameState()
    let socket = default(WebSocket)
    let id = "babel-fixture"
    state.socketSlots[socket] = 0
    state.playerSockets[0] = socket
    state.registeredSlots.incl(0)
    state.decisionSeats[id] = 0
    state.decisionIssuedAt[id] = getMonoTime() - initDuration(seconds = 1)
    # The engine can issue a later decision while this earlier HTTP reader joins.
    state.latestDecisions[0] = "babel-next"
    state.decisionSeats["babel-next"] = 0
    state.decisionIssuedAt["babel-next"] = getMonoTime()
    var started = newDecisionAttempt(id & "-model", "fixture", aoModel)
    started.prompt = %*["private fixture"]
    started.request = %*{"fixture": true}
    started.decoder = %*{"temperature": 0}
    state.pendingAttempts[id] = started.attemptEvidenceJson()
    var received = started
    received.responseBodyB64 = some(encode("\xffprivate partial bytes"))
    received.responseHeadersB64 = some(encode("HTTP/1.1 200 OK\r\n\r\n"))
    received.responseComplete = some(false)
    received.responseReaderJoined = some(true)
    received.httpStatus = some(200)
    websocketHandler(socket, CloseEvent, Message())
    check not state.playerSockets.hasKey(0)
    check state.socketSlots[socket] == 0
    let stopped = %*{"type": "stopped", "decision_id": id,
      "stop_id": newJNull(), "worker_status": "joined", "attempts": [received.attemptEvidenceJson()]}
    websocketHandler(socket, MessageEvent, Message(kind: TextMessage, data: $stopped))
    check state.completedAttempts[id] == received.attemptEvidenceJson()
    check 0 notin state.stoppedSlots
    check 0 in state.registeredSlots
    # An already-sealed episode rejects further frames, even with retained attribution.
    state.finished = true
    received.responseBodyB64 = some(encode("different bytes"))
    let late = %*{"type": "stopped", "decision_id": id,
      "stop_id": newJNull(), "worker_status": "joined", "attempts": [received.attemptEvidenceJson()]}
    websocketHandler(socket, MessageEvent, Message(kind: TextMessage, data: $late))
    check state.completedAttempts[id] == stopped["attempts"][0]

  test "acknowledgement must echo the actual issued stop identity":
    state = GameState()
    let socket = default(WebSocket)
    state.socketSlots[socket] = 0
    state.registeredSlots.incl(0)
    state.stopping = true
    state.stopId = "issued-stop-identity"
    state.stopIssuedAt = getMonoTime() - initDuration(seconds = 1)
    state.acknowledgementDeadline = getMonoTime() + initDuration(seconds = 1)
    var stopped = %*{"type": "stopped", "decision_id": newJNull(),
      "stop_id": "guessed-stop-identity", "worker_status": "no_active_call", "attempts": []}
    websocketHandler(socket, MessageEvent, Message(kind: TextMessage, data: $stopped))
    check 0 notin state.stoppedSlots
    stopped["stop_id"] = %state.stopId
    websocketHandler(socket, MessageEvent, Message(kind: TextMessage, data: $stopped))
    check 0 in state.stoppedSlots

  test "nonce does not acknowledge an explicitly unjoined response reader":
    state = GameState()
    let socket = default(WebSocket)
    let id = "babel-unjoined"
    state.socketSlots[socket] = 0
    state.registeredSlots.incl(0)
    state.decisionSeats[id] = 0
    state.decisionIssuedAt[id] = getMonoTime() - initDuration(seconds = 1)
    state.latestDecisions[0] = id
    state.stopping = true
    state.stopId = "issued-stop-identity"
    state.stopIssuedAt = getMonoTime() - initDuration(seconds = 1)
    state.acknowledgementDeadline = getMonoTime() + initDuration(seconds = 1)
    var attempt = newDecisionAttempt(id & "-model", "fixture", aoModel)
    state.pendingAttempts[id] = attempt.attemptEvidenceJson()
    attempt.responseReaderJoined = some(false)
    let stopped = %*{"type": "stopped", "decision_id": id,
      "stop_id": state.stopId, "worker_status": "joined", "attempts": [attempt.attemptEvidenceJson()]}
    websocketHandler(socket, MessageEvent, Message(kind: TextMessage, data: $stopped))
    check state.completedAttempts[id] == attempt.attemptEvidenceJson()
    check 0 notin state.stoppedSlots

  test "raw header callbacks cannot be rewritten during native progress":
    var attempt = newDecisionAttempt("issued-model", "fixture", aoModel)
    attempt.responseHeadersB64 = some(encode("HTTP/1.1 200 OK\r\nX-Private: original\r\n"))
    let started = attempt.attemptEvidenceJson()
    attempt.responseHeadersB64 = some(encode("HTTP/1.1 200 OK\r\nX-Private: changed\r\n"))
    expect ValueError: validateAttemptProgress(started, attempt.attemptEvidenceJson())
    attempt.responseHeadersB64 = some(encode("HTTP/1.1 200 OK\r\nX-Private: original\r\n\r\n"))
    validateAttemptProgress(started, attempt.attemptEvidenceJson())

suite "native Messages response and game artifacts":
  for scenario in ["invalid model JSON", "endpoint outage", "fenced success"]:
    test scenario:
      let directory = createTempDir("babel-failure-", "")
      defer: removeDir(directory)
      let failurePath = directory / "player_failure.json"
      putEnv("COGAME_PLAYER_FAILURE_URI", "file://" & failurePath)
      defer: delEnv("COGAME_PLAYER_FAILURE_URI")
      let runtime = RuntimeConfig(resultsUri: "file://" & directory / "results.json",
        replayUri: "file://" & directory / "replay.json")
      var config = defaultGameConfig()
      for seat in 0 ..< Seats:
        config.players.add(PlayerConfig(name: "player" & $seat))
        config.tokens.add("token" & $seat)
      config = sampleEpisode(config)
      state = GameState(config: config, sim: initSim(config),
        episodeDeadline: getMonoTime() + initDuration(seconds = 10))
      while not state.sim.done:
        let call = state.sim.currentCall()
        if call.kind == ckRound:
          state.sim.beginRound()
          continue
        let client = LlmClient(lastCall: LlmCallEvidence(model: "requested"))
        let action = if call.kind == ckSpeak:
          %*{"tokens": [state.sim.glyphOf(call.seat, 0)]} else: %*{"pick": 0}
        let fenced = "```json\n" & $action & "\n```"
        let text = if scenario == "invalid model JSON" and call.seat == 2: "private invalid reply" else: fenced
        let outage = scenario == "endpoint outage" and call.seat == 2
        let body = if outage: "private provider detail" else:
          $(%*{"content": [{"type": "text", "text": text}]})
        let http = NativeHttpResponse(kind: nhComplete, httpStatus: some(if outage: 503 else: 200),
          headerBytes: "request-id: provider\r\nx-request-id: proxy\r\n", bodyBytes: body,
          transferComplete: true, responseReaderJoined: some(true))
        try:
          let reply = client.readCompletion(http)
          let payload = extractJsonObject(reply)
          let resolution = state.sim.resolveAction(call, $payload, false, some(reply))
          check resolution.accepted
          check client.lastCall.providerRequestId == some("provider")
        except CatchableError as error:
          check scenario != "fenced success"
          let evidence = client.lastCall.privateAttempt("fixture-model", error.msg).attemptEvidenceJson()
          check decode(evidence["response_body_b64"].getStr()) == body
          let frame = %*{"source": "error", "error": error.msg, "training_attempt": evidence}
          state.playerFailure = gamePlayerFailure(1, call, frame, true, true, error.msg)
          finishEpisode(runtime, esFailed)
          let declaration = parseFile(failurePath)
          check declaration == state.playerFailure
          check declaration["kind"].getStr() == (if outage: "episode_inconclusive" else: "player_error")
          check declaration["failed_policy_index"].getInt() == 2
          check (if outage: "HTTP 503" else: "JSON action") in declaration["message"].getStr()
          check "private" notin $declaration
          check not fileExists(directory / "results.json")
          check not fileExists(directory / "replay.json")
          break
      if scenario != "fenced success":
        check fileExists(failurePath)
      else:
        finishEpisode(runtime, esCompleted)
        check parseFile(directory / "results.json")["rounds"].getInt() == config.rounds
        check fileExists(directory / "replay.json")
        check not fileExists(failurePath)
