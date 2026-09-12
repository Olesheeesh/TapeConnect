# TapeConnect 🔌

The open-source bridge between your MetaTrader 5 terminal and [TAPE](https://www.tape-tradingjournal.com) — read exactly what it sends and when, before you trust it with your account.

## What it does

TapeConnect is a MetaTrader 5 Expert Advisor. Attached to any chart, it:

1. **Journals every deal locally**, first and always — an append-only, hash-chained JSONL file under `MQL5\Files\journal\` on your own machine. This happens whether or not you ever connect it to a server.
2. **Mirrors that data to your TAPE account** over HTTPS, once you provide a server URL and API token — this is what actually feeds your TAPE dashboard (compliance checks, Trade Replay, analytics). The local journal from step 1 keeps writing either way, as a durable record and a safety net if the connection ever drops, but it's not a substitute for connecting: without a server configured, the dashboard has nothing to show.

## What it actually sends (and nothing else)

With a server URL and API token configured, TapeConnect calls exactly these endpoints:

| Endpoint | What it sends |
|---|---|
| `POST /api/ingest/deal` | One closed/opened deal: symbol, side, volume, price, time, profit |
| `POST /api/ingest/live-state` | Current balance/equity snapshot, roughly every few seconds |
| `POST /api/ingest/bars` | Price-bar history around a trade, for the Trade Replay chart |
| `GET /api/ingest/last-ticket` / `GET /api/ingest/missing-bars` | Self-healing checks - lets the EA notice and re-send anything the server is missing after a dropped connection |

Every request is authenticated with the token you generate yourself in TAPE's own Settings → Connect EA screen. **The EA refuses to send anything at all unless your server URL starts with `https://`** — it checks this once at startup and disables server sync entirely rather than risk sending your token over plaintext HTTP.

## Setup

1. Open MetaEditor in MetaTrader 5.
2. Copy `Experts/TradeJournalEA/TradeJournalEA.mq5` into your own `MQL5/Experts/` folder, and `Include/TradeJournal/Hashing.mqh` into `MQL5/Include/TradeJournal/`.
3. Compile the `.mq5` file (F7).
4. Attach it to any chart. In the Inputs tab:
   - `InpServerUrl` — your TAPE server URL (leave blank to run fully local, no server push at all)
   - `InpApiToken` — your account's API token, from TAPE's Settings → Connect EA
5. Allow WebRequest for your server's domain in MT5's Options → Expert Advisors, if you're connecting to a server.

## Why this repo exists

TAPE's own server and dashboard aren't open source, but the piece that actually touches your trading terminal is — so you (or anyone) can read precisely what leaves your machine, verify there's nothing else going on, and compile it yourself if you'd rather not trust a pre-built binary.

## For maintainers

This repo has a pre-commit hook that blocks commits containing anything
IP-address-shaped or credential-shaped, since this is a public repo and
should only ever contain the EA itself. Enable it once per clone:

```
git config core.hooksPath .githooks
```

## License

MIT — see [LICENSE](LICENSE). Use it, modify it, fork it.
