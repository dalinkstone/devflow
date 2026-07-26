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
dv status
```

## Teams

```sh
dv team up org/repo -m "ship it"
dv team up org/repo --mode linked --agents 3 -m "ship it"

dv team status repo
dv team task repo worker-1 "fix tests"
dv team rm repo
```

## AWS

Add `--aws-profile NAME`, `--secret-env VAR`, or `--env NAME=VALUE`.

## Access

Run `dv web NAME`, or add `--port 3000` for an app. Use `dv mobile` or `dv attach` for SSH.

## Cost

Running sandboxes incur Daytona compute charges. `dv stop --all` stops compute and keeps disks. `dv rm --all` deletes everything.

[Full guide](docs/usage.md)
