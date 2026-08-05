# TeslaMate price updater

Small Node.js service that runs alongside a self-hosted [TeslaMate](https://github.com/teslamate-org/teslamate) and sets the exact cost of finished charging sessions at one geofence, using real electricity prices from [borsihind.ee](https://borsihind.ee) (Nord Pool spot + grid fees + taxes, VAT included).

How it works:

- Every price interval (15 min or 1 h) it fetches the pre-calculated price JSON from the borsihind API and keeps the last 48 h of prices in a local JSON file (the API only serves current and future prices, so the service builds its own history).
- Every 5 minutes it looks for charging sessions at the geofence that have ended but have **no cost** (`cost IS NULL`). For each one it splits the session's energy across every price slot it touched — using TeslaMate's per-few-seconds `charges` samples, so even 1 minute in one slot and 4 hours in another are priced separately — scales to the billable energy (`charge_energy_used`, which includes charging losses), adds your marginal, and writes the total into `charging_processes.cost`.

Because all pricing happens after a session ends, the service can go down mid-charge (or the whole time) without any effect — unpriced sessions are picked up and calculated correctly as soon as it's back, as long as the price cache covers the session.

**Important:** leave the geofence's *cost per kWh* field empty in TeslaMate. If it's set, TeslaMate fills in a cost itself at session end and this service will skip the session (it never overwrites an existing cost — including ones you set manually).

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `GEOFENCE_ID` | *(required)* | TeslaMate geofence id (visible in the geofence edit URL, e.g. `/geo-fences/3/edit`) |
| `VORK` | `V1` | Elektrilevi grid package: `V1`, `V2`, `V4` or `V5` |
| `MARGINAL` | `0` | Your electricity provider's marginal in EUR/kWh (e.g. `0.005`) |
| `INTERVAL` | `1h` | Price interval: `1h` or `15min` |
| `DATA_DIR` | `./data` | Directory for the local price cache (mount as a volume so history survives restarts) |
| `DATABASE_HOST` | `database` | TeslaMate Postgres host |
| `DATABASE_PORT` | `5432` | |
| `DATABASE_USER` | `teslamate` | |
| `DATABASE_PASS` | | |
| `DATABASE_NAME` | `teslamate` | |
| `DATABASE_URL` | | Alternative: full connection string, overrides the above |

## docker-compose

Add next to your existing TeslaMate services:

```yaml
  priceupdater:
    build: ./teslamate
    restart: always
    environment:
      - GEOFENCE_ID=1
      - VORK=V4
      - MARGINAL=0.005
      - INTERVAL=1h
      - DATA_DIR=/data
      - DATABASE_HOST=database
      - DATABASE_USER=teslamate
      - DATABASE_PASS=${TM_DB_PASS}
      - DATABASE_NAME=teslamate
    volumes:
      - priceupdater-data:/data
    depends_on:
      - database
```

(and add `priceupdater-data:` under top-level `volumes:`)

## Run locally

```bash
GEOFENCE_ID=1 VORK=V4 MARGINAL=0.005 DATABASE_HOST=localhost DATABASE_PASS=secret node index.mjs
```

## Notes

- A session is only priced once every slot it touched has a cached price; otherwise it's skipped and retried on the next pass. Sessions older than the cache (e.g. from before the service was first launched, or after >48 h of downtime) stay unpriced — set those manually in TeslaMate.
- The price written is the full consumer price: spot (with VAT) + transmission + renewable tax + excise + supply security fee + marginal. Geofence session fees are not applied.
