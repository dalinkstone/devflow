# Persistent session acceptance checks

Use v0.11.0 or later. For checkout testing, run `make tui`, then replace `dv`
below with `./bin/devflow`, or run `make install` to install the checkout.

## Automated

```sh
make lint && make test
```

`test_sessions.py` runs the actual embedded supervisor over Unix sockets, with
an explicit Codex protocol fixture. Coverage includes numbered event replay,
lost acknowledgements/deduplication, queued follow-ups, persistent approvals,
freeform answers, stale replies, interruption, provider crashes, process locks,
credential redaction, local outbox recovery, Claude SDK callback/resume/error
contracts, and real Git branch/commit/push against a temporary bare repository.
`test_session_console.py` drives both the fallback and native UI in a pseudo-terminal:
multiple-choice answer, Ctrl-C turn interruption, network outage/recovery,
and Ctrl-D detach, including prompt durability immediately before detach.
The Go suite covers layout at 35–160 columns, long scrollback, terminal escape
sanitization, input review, unknown cost, timers and metadata, and runs with the
race detector. Provider tests cover usage replacement (not double-counting),
persisted spend, effort propagation, title and turn timestamps.
Model behavior and hosted GitHub are not mocked into a
claim of successful live execution.

## Live results (2026-10-20 local time)

| Check | Result |
| --- | --- |
| A: remote Codex file edit | Passed. File created inside Daytona, not the laptop. |
| B: input in same conversation | Passed. Real approval answered through TUI; follow-up used the same thread. |
| C: detached execution | Passed. Approved a 15-second task, detached; remote file and final events completed independently. |
| D: GitHub lifecycle | Passed. Remote clone → feature branch → commit → push → draft [test PR #2](https://github.com/dalinkstone/devflow/pull/2); verified exactly two expected lines. Test PR closed afterward. |
| E: failure recovery | Passed for real provider termination and sandbox stop/start; original conversation ID and PR metadata retained. Network failure/client replay covered by local transport/PTY tests. |
| F: Claude execution | Not verified. Official SDK installed and produced a saved session ID, but existing OAuth sign-in was expired. User requested no further live Claude tests; sandbox removed. SDK contracts are tested automatically. |

Both disposable test sandboxes are removed after testing. The closed test PR
and its branch retain the remote execution evidence; no smoke-test file is
part of the implementation branch.

## Repeat manually

Creates billed sandboxes and uses your selected agent account. Choose a repo
you can safely test in, and review each approval:

```sh
dv new --repo OWNER/REPO --agent codex --branch devflow/session-check \
  -m "Create session-check.txt containing hello; do not commit or push."
# Tab → approve the specific file operation. Ctrl-D → detach.
dv status SESSION
dv send SESSION "Wait 30 seconds, then append done to session-check.txt."
dv attach SESSION
# Approve that operation, then Ctrl-D while it is running.
dv status SESSION
dv attach SESSION                 # missed output, same conversation
dv exec SESSION -- 'cd ~/work/REPO && git diff && git status --short'
dv pr SESSION "Test persistent session"
dv status SESSION                 # draft PR URL
dv stop SESSION
dv attach SESSION                 # same saved conversation; no replayed task
dv rm SESSION                     # deletes the sandbox and remote history
```

For Claude, refresh credentials with `dv setup claude`, then repeat using
`--agent claude` and a separate branch. Never paste tokens into the agent
conversation. For an actual network-drop test, disconnect the laptop network
after approval, wait, reconnect, and confirm the remote event sequence resumes.
