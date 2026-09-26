# devflow

Cloud Claude/Codex sessions on Daytona.

## Install

```sh
curl -fsSL https://devflow.sh/install | sh
dv setup
```

## Run

```sh
dv up org/repo
dv up org/repo -m "fix it" --detach
dv peek
dv status
dv demo                    # choose a sandbox demo
dv demo desktop            # recorded LibreOffice computer use
dv demo rl                 # Harbor reward evaluation
dv demo fix                # agent fixes an app; linked verifier checks it
dv demo windows            # Windows GUI + screenshot (Tier 3+)
```

Demo previews use your Daytona account; no Cloudflare setup needed.

## Teams

```sh
dv team up org/repo -m "ship it"
dv team up org/repo --mode linked --agents 3 -m "ship it"

dv team status repo
dv team ui repo            # watch, assign, message, hand off
dv team task repo worker-1 "fix tests"
dv team send repo worker-1 "check the edge cases"
dv team handoff repo worker-1 worker-2 "review the result"
dv team rm repo
```

## AWS

Add `--aws-profile NAME`, `--secret-env VAR`, or `--env NAME=VALUE`.

## Access

Run `dv web NAME`, or add `--port 3000` for an app. Use `dv mobile` or `dv attach` for SSH.

## Cost

Running sandboxes incur Daytona compute charges. `dv stop --all` stops compute and keeps disks. `dv rm --all` deletes everything.

[Full guide](docs/usage.md)
