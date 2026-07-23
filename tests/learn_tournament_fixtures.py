"""Adapter source fixtures shared by the tournament end-to-end test."""

MUTATOR = r'''import hashlib, json, os, pathlib, sys, time
operation, request_path, response_path = sys.argv[1:4]
assert operation == "mutate"
request = json.loads(pathlib.Path(request_path).read_text())
index = request["candidate_index"]
barrier = pathlib.Path(os.environ["TOURNAMENT_BARRIER"])
(barrier / f"mutation-{index}").write_text("started")
deadline = time.monotonic() + 10
while len(list(barrier.glob("mutation-*"))) != 4:
    assert time.monotonic() < deadline, "mutations did not run concurrently"
    time.sleep(0.01)
attempt_path = barrier / f"mutator-attempts-{index}"
attempts = int(attempt_path.read_text()) if attempt_path.exists() else 0
attempt_path.write_text(str(attempts + 1))
retry_marker = barrier / f"mutator-retried-{index}"
if index == 0 and not retry_marker.exists():
    retry_marker.write_text("retry")
    raise SystemExit(19)
if (barrier / f"fail-mutator-{index}").exists():
    print("PRIVATE_ADAPTER_CANARY_DO_NOT_EXPOSE /Users/private/repository", file=sys.stderr)
    raise SystemExit(31)
parent = pathlib.Path(request["parent"]["path"]).read_text()
child = parent.rstrip() + f"\n\nTournament variant {index}.\n"
child_bytes = child.encode()
pathlib.Path(request["child_path"]).write_bytes(child_bytes)
response = {
    "schema": "codegraff.learn.mutation.response.v1",
    "trial_id": request["trial_id"],
    "candidate_index": index,
    "parent_id": request["parent"]["id"],
    "child_path": request["child_path"],
    "child_sha256": hashlib.sha256(child_bytes).hexdigest(),
    "description": f"PRIVATE_MUTATION_DESCRIPTION_{index}_DO_NOT_RENDER",
}
pathlib.Path(response_path).write_text(json.dumps(response, separators=(",", ":")) + "\n")
'''
