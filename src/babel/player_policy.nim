## Scripted and prompt policies over Babel's ordinary private decision view.

import std/[json, monotimes]
import llm, prompts

proc promptMessages*(view: JsonNode, operatorPrompt: string,
    selection: PromptSelection): JsonNode =
  let system = selection.systemPrompt()
  let task =
    if view["role"].getStr() == "speaker":
      let g0 = view["alphabet"][0].getStr()
      let g1 = view["alphabet"][1].getStr()
      "Reply with one JSON object containing \"tokens\" (array of 1 to 8 glyphs from your alphabet) " &
      "and optional \"notes\" (string). Example: {\"tokens\":[\"" & g0 & "\",\"" & g1 & "\"],\"notes\":\"\"}"
    else:
      "Reply with one JSON object containing \"pick\" (integer 0, 1, 2, or 3 indexing lineup_scenes) " &
      "and optional \"notes\" (string). Example: {\"pick\":0,\"notes\":\"\"}"
  let user = "Your private observation:\n" & $view & "\n" &
    "Operator guidance:\n" & operatorPrompt & "\n" & task
  %*[
    {"role": "system", "content": system},
    {"role": "user", "content": user}
  ]

proc promptAction*(client: LlmClient, view: JsonNode,
    operatorPrompt: string, selection: PromptSelection, deadline: MonoTime): JsonNode =
  let messages = promptMessages(view, operatorPrompt, selection)
  extractJsonObject(client.completeText(messages[0]["content"].getStr(),
    messages[1]["content"].getStr(), view["slot"].getInt(), deadline))
