# Persistent remote sessions

Your terminal is the interface. Codex/Claude, tools, Git, and conversation state
run inside one private Daytona sandbox per session. No central service or
Cloudflare configuration is needed.

## Setup

Install Python 3.10+ locally, plus the usual Daytona CLI, jq, git and gh.
Optional Charm Gum improves the launch picker; the live view uses Python curses
(included with macOS and normal Linux Python installs).

```sh
dv init
dv setup github             # browser login or selected-repo PAT
dv setup codex              # existing Codex device sign-in or API key
dv setup claude             # Claude setup-token or API key
dv
```

Existing Codex `auth.json` and Claude sign-ins are also detected. API keys can
come from `OPENAI_API_KEY` / `ANTHROPIC_API_KEY` or private setup settings
`DEVFLOW_CODEX_API_KEY` / `DEVFLOW_ANTHROPIC_API_KEY`; API billing is separate
from subscriptions. Only the selected provider's credential is forwarded by
`new`. Never paste keys into a prompt or commit them to a repository.

GitHub uses `gh` OAuth or an explicitly supplied `GH_TOKEN` / `GITHUB_TOKEN`.
For fine-grained PATs, select only needed repositories and grant Contents and
Pull requests read/write (plus organization approval/SSO if required). The
remote gh credential helper works while your laptop is offline. The first
version forwards the token privately; it is **not** a GitHub App token broker
and does not automatically renew expired/revoked PATs. Git author name/email
come from your local Git configuration.

Credentials remain accessible to trusted code running as your sandbox user;
this is not privilege separation from a malicious agent or repository. Files,
session databases, and local input queues are private (0600), directories 0700.
Known provider/GitHub secrets are redacted from events. Don't ask an agent to
print secrets: unknown secrets in arbitrary tool output cannot be detected
reliably. No Daytona account credential is copied to the sandbox.

## Start and reconnect

```sh
dv new --repo owner/repo --agent codex -m "fix the failing test"
dv new --repo owner/repo --agent claude --branch devflow/my-feature --detach
dv sessions
dv attach dv-session-EXAMPLE
dv status dv-session-EXAMPLE
dv send dv-session-EXAMPLE "also add a regression test"
```

`new` uses a standard `daytona-medium` snapshot, ignoring any stale configured
custom snapshot; `--size small|medium|large` changes it. A fresh `devflow/<id>`
branch is created unless you supply a branch. An existing remote feature branch
is checked out, preserving its associated PR; the default branch is rejected.
The optional repository picker lists your first 200 owned repos; enter an
explicit `--repo` for other accessible organization/collaborator repos.

The picker, branch/task prompts, and live view need an interactive terminal.
Use flags plus `--detach` for scripting. Session ID and sandbox name are the same.
You can reconnect from a second machine with Devflow and your Daytona login;
no provider/GitHub login on that second machine is required.

## Live view

Output arrives through short authenticated Daytona exec polls (typically a
second or two, depending on your region/network), not a direct provider stream
to your laptop. Commands, output, file changes, plans and status are displayed.
Only public agent messages/summaries are shown, not hidden reasoning.

| Control | Action |
| --- | --- |
| Type text, Enter | Send prompt; while busy, queue a follow-up for the same thread |
| Tab | Answer the oldest pending approval/question; select numbers or type text |
| Esc in question | Leave it pending |
| Ctrl-D or `/detach` | Close this client only |
| Ctrl-C or `/interrupt` | Interrupt current turn and clear queued follow-ups |
| Page Up / Page Down | Scroll history |
| `/approve ID`, `/deny ID` | Approve once or deny one specific operation |
| `/answer ID {"question-id":"answer"}` | Structured/freeform answer; Claude uses question text as the key |
| `/recover` | Restart a failed provider using its saved conversation ID |
| `/pr TITLE` | Stage all changes, commit, push, create/reuse a draft PR |

Questions/approvals wait on the remote supervisor even with no client attached.
Unsupported provider requests are never approved. Codex uses `untrusted`
approval policy and workspace-write isolation; safe reads/workspace operations
may run without asking according to Codex's policy. Claude uses its default
permission mode with explicit callback handling, never bypass mode. Review
the full operation before approving it. Ordinary conversational questions can
be answered with another prompt after the turn completes.

## Persistence and failures

The remote supervisor owns the agent, with a private Unix socket—not an open
HTTP control port. All connections use your authenticated Daytona account over
TLS. SQLite retains metadata, numbered events, pending interactions and input
receipts. A local cursor/cache replays missed events without re-running them;
on another machine replay starts from the beginning. Lost acknowledgements
retry the same input ID, not a second prompt. Local input waiting for an
acknowledgement is stored privately and retried on reattach.

Network loss leaves the agent running; the UI reports disconnection and retries.
Agent exit is a different `failed` state; use `/recover` explicitly. Sandbox
stop or supervisor restart restores the saved provider thread, but **does not
replay an interrupted task or old approval**. Queued follow-ups are cancelled
on runtime restart; send a new prompt describing what should continue. After
an unclean supervisor kill, surviving orphan processes block duplicate starts:
stop the sandbox, then attach. A fresh creation whose clone failed must be
removed and recreated; recovery cannot reconstruct a missing workspace.

For programmatic inspection, `dv events SESSION [AFTER_SEQUENCE]` returns up to
300 events, current state, and the next cursor as JSON. Repeat until caught up.
Events remain on disk until the sandbox is deleted; long runs consume storage.

## Publish and lifecycle

```sh
dv exec SESSION -- 'cd ~/work/repo && git diff'  # review first
dv pr SESSION "Fix the failing test"           # explicit publication
dv status SESSION                             # status + PR URL
dv interrupt SESSION                          # stop only current turn
dv stop SESSION                               # stop compute, retain disk
dv attach SESSION                             # restart sandbox; same conversation
dv rm SESSION                                 # confirm permanent deletion
```

PR publication refuses the default branch or an unexpected checkout. It stages
**all** changes, commits when necessary, pushes without force, and reuses an
existing open PR for that branch. Failures retain local Git commits; fix auth
and retry. Agents can also use remote Git/gh tools under their provider's
approval policy. GitHub auth exists remotely, so an explicitly prompted agent
workflow can finish while the laptop is disconnected.

Auto-stop is disabled, auto-delete is disabled, and stopped disks archive after
seven days; completing a turn or detaching does not stop billing. Use `stop`
to stop compute or `rm` to delete disk and session history. No automatic idle
shutdown is enabled because Daytona idle timers do not track agent work.

After credential expiry, refresh locally (`dv token`, `codex login`, or
`dv setup github`), then `dv sync SESSION`, `dv stop SESSION`, `dv attach SESSION`.
Provider-native refresh may work, but shared OAuth refresh rotation can race
other clients; there is no promise of indefinite unattended authentication.

## Protocol references

- [Codex app-server](https://developers.openai.com/codex/app-server/) — stdio JSON-RPC, threads, approvals and events.
- [Claude Agent SDK](https://code.claude.com/docs/en/agent-sdk/python) and [user input](https://code.claude.com/docs/en/agent-sdk/user-input).
- [Daytona process execution](https://www.daytona.io/docs/en/process-code-execution/) — detached background execution.

Tested wire contract: Codex CLI 0.163.0; Claude Python SDK pinned to 0.2.169.
Installed Codex-generated JSON schemas take precedence over documentation examples
where enum spellings differ (`untrusted`, `workspace-write`).
