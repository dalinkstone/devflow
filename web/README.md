# devflow.sh

Landing page, installer endpoint, and protected Daytona preview proxy.

## Prerequisites

- Node.js 22+

## Local

```bash
npm install
npm run dev
```

## Check

```bash
npm run lint
npm test
```

## Preview proxy

Cloudflare Access protects `*.devflow.sh`. The Worker maps `box.devflow.sh` to
port 22222 on `dv-box`, and `box--3000.devflow.sh` to port 3000.

`DAYTONA_API_KEY` is a Worker secret. Deploy the wildcard Worker with:

```bash
npm run build
npx wrangler deploy --config wrangler.preview.jsonc
```
