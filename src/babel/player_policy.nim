## Scripted and prompt policies over Babel's ordinary private decision view.

import std/[json, monotimes]
import llm, prompts

proc promptMessages*(view: JsonNode, operatorPrompt: string,
    selection: PromptSelection): JsonNode =
  let system = selection.systemPrompt()
  let (task, example) = if view["role"].getStr() == "speaker":
    ("Send 1 to 8 glyphs from your alphabet in tokens.", %*{"tokens": [view["alphabet"][0]]})
  else:
    ("Choose a lineup_scenes index from 0 to 3 in pick.", %*{"pick": 0})
  let user = "Your private observation:\n" & $view & "\n" &
    "Operator guidance:\n" & operatorPrompt & "\n" & task &
    " You may add string notes. Reply with one JSON action. Example: " & $example
  %*[
    {"role": "system", "content": system},
    {"role": "user", "content": user}
  ]

proc promptAction*(client: LlmClient, view: JsonNode,
    operatorPrompt: string, selection: PromptSelection, deadline: MonoTime): JsonNode =
  let messages = promptMessages(view, operatorPrompt, selection)
  extractJsonObject(client.completeText(messages[0]["content"].getStr(),
    messages[1]["content"].getStr(), view["slot"].getInt(), deadline))

proc modelFailureSummary*(attempt: JsonNode, reason: string): tuple[kind, message: string] =
  ## Only game-owned descriptions reach logs or the runner. The private attempt
  ## retains the provider bytes and parser exception.
  if reason == "no native LLM endpoint configured":
    return ("episode_inconclusive", reason)
  if attempt.isNil or attempt.kind != JObject:
    return ("player_error", "player failed to produce an action")
  let status = attempt{"http_status"}.getInt()
  if status >= 100 and status <= 599 and status notin 200..299:
    return ("episode_inconclusive", "model endpoint returned HTTP " & $status)
  if status == 0 or not attempt{"response_complete"}.getBool():
    case reason
    of "native transport nhDeadline": return ("episode_inconclusive", "model request timed out")
    of "native transport nhTransportFailure": return ("episode_inconclusive", "model endpoint connection failed")
    else: return ("episode_inconclusive", "model endpoint did not return a complete response")
  case attempt{"stop_reason"}.getStr()
  of "refusal": return ("player_error", "model refused the action")
  of "max_tokens": return ("player_error", "model reached the output limit before producing a valid action")
  else: discard
  case reason
  of "received platform call identity is not a UUID", "duplicate received identity header",
      "invalid received HTTP header", "received HTTP headers are not valid UTF-8",
      "native sampling evidence violates the token schema",
      "native usage must contain nonnegative integer counts",
      "native model name must be text", "native stop reason must be text or null":
    return ("episode_inconclusive", reason)
  else: discard
  if attempt{"response"}.kind == JString:
    return ("player_error", "model reply was not a single JSON action object")
  return ("episode_inconclusive", "model endpoint returned an invalid Messages response")
