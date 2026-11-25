"""Deterministic local /v1/messages fixture for offline Babel certification.

Serves valid canonical Babel speaker/listener JSON actions without paid LLM calls.
Never commit a local endpoint to coworld_manifest_template.json; pass it only via
COWORLD_LLM_ENDPOINT=http://host.docker.internal:<port> to `coworld certify --use-llm`.
"""

import http.server
import json
import os
import signal
import sys
import uuid


class BabelMessagesHandler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/v1/messages":
            self.send_response(404)
            self.end_headers()
            return
        length = int(self.headers.get("content-length", "0"))
        request = json.loads(self.rfile.read(length))
        content = request["messages"][0]["content"]
        view = json.loads(
            content.split("Your private observation:\n", 1)[1].split(
                "\nOperator guidance:", 1
            )[0]
        )
        if view["role"] == "speaker":
            action = {"tokens": [view["alphabet"][0]], "notes": ""}
        else:
            action = {"pick": 0, "notes": ""}
        call_id = str(uuid.uuid4())
        payload = {
            "id": "msg_" + call_id,
            "type": "message",
            "role": "assistant",
            "model": request.get("model", "fixture/babel"),
            "content": [{"type": "text", "text": json.dumps(action)}],
            "stop_reason": "end_turn",
            "usage": {"input_tokens": 10, "output_tokens": 5},
        }
        body = json.dumps(payload).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Softmax-Llm-Call-Id", call_id)
        self.send_header("request-id", "fixture-" + call_id)
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass


def main() -> None:
    host = os.environ.get("FIXTURE_HOST", "0.0.0.0")
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    server = http.server.ThreadingHTTPServer((host, port), BabelMessagesHandler)
    actual_port = server.server_address[1]
    print(f"PORT={actual_port}", flush=True)

    def shutdown(_signum, _frame):
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    try:
        server.serve_forever()
    except (KeyboardInterrupt, SystemExit):
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
