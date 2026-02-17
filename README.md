# UMH Simulator

[![GitHub](https://img.shields.io/badge/GitHub-umh--factory--demo-blue)](https://github.com/united-manufacturing-hub/umh-factory-demo)

Factory demo environment for the United Manufacturing Hub (UMH). Sets up a complete production simulation with real industrial protocols (OPC-UA, Modbus TCP), webhook-based ERP/MES integration, Grafana dashboards, and OEE analytics.

## Quick Start

**Prerequisites:** Docker Engine + Docker Compose v2

### 1. Create a directory with your `docker-compose.yaml`

```yaml
services:
  umh-core:
    image: management.umh.app/oci/united-manufacturing-hub/umh-core:0.7.5
    restart: unless-stopped
    environment:
      - AUTH_TOKEN=your-auth-token-here
      - LOCATION_0=MyFactory
      - LOCATION_1=PlantA
    volumes:
      - ./umh-core-data:/data
```

### 2. Run the setup

**Stable (latest release):**
```bash
curl -fsSL https://github.com/united-manufacturing-hub/umh-factory-demo/releases/latest/download/quick-start.sh -o quick-start.sh && bash quick-start.sh
```

**Dev (latest prerelease):**
```bash
curl -fsSL https://github.com/united-manufacturing-hub/umh-factory-demo/releases/download/v1.0.1-dev.2/quick-start.sh -o quick-start.sh && bash quick-start.sh --dev
```

**Specific version:**
```bash
curl -fsSL https://github.com/united-manufacturing-hub/umh-factory-demo/releases/download/v1.0.0/quick-start.sh -o quick-start.sh && bash quick-start.sh --version=1.0.0
```

**Custom repo:**
```bash
curl -fsSL https://github.com/united-manufacturing-hub/umh-factory-demo/releases/latest/download/quick-start.sh -o quick-start.sh && bash quick-start.sh --repo=myRepo/umh-factory-demo
```

### 3. Access

| Service | URL | Description |
|---------|-----|-------------|
| Grafana | http://localhost:8080 (admin/admin) | OEE dashboards, machine monitoring |
| Machine Simulator | http://localhost:8081 | Interactive factory control UI |
| API (via Nginx) | http://localhost:80 | Stop reason API, operator forms |

## Machine Simulator

The simulator (`dh2k/machine-simulator-2:v1.0.0`) provides a realistic factory environment with an interactive web UI and full protocol support.

### Interactive Web UI

Access at **http://localhost:8081** - a dark-themed dashboard with real-time updates via WebSocket:

- **Dashboard** - Overview of all lines, machines, and active orders
- **Line Details** - Machine states, buffer levels, and production flow visualization
- **Machine Details** - Per-machine tags, cycle counts, and state history
- **Orders** - Create/manage production orders, view progress and completion
- **Simulation Controls** - Adjust time scale (0.1x-100x), random factor, machine parameters

### Protocols

| Protocol | Port(s) | Description |
|----------|---------|-------------|
| OPC-UA | 4840+ (one per machine) | Real-time machine tags (state, cycle count, good/scrap, sensor data) |
| Modbus TCP | 502 | Holding register gateway for all machines |
| HTTP Webhooks | Configurable | Pushes order and machine events to external systems (e.g., UMH Core) |
| REST API | 8081 | Full control: lines, machines, orders, operations, recipes, settings |
| WebSocket | 8081/ws | Real-time event stream for UI and integrations |

### Data Flow

```
Machine Simulator
├── OPC-UA ──────────> UMH Core (protocol converter) ──> UNS ──> PostgreSQL
├── Modbus TCP ──────> UMH Core (protocol converter) ──> UNS ──> PostgreSQL
└── Webhooks (HTTP) ─> UMH Core (erp-receiver:8090) ──> UNS ──> production_orders table
                       ├── order.created   → _erp.orders
                       ├── order.progress  → _erp.orders (includes planned_cycle_time_ms)
                       └── order.closed    → _erp.orders
```

### Available Line Templates

10 industrial domains with 27 machine types:

| Domain | Line Template | Machines |
|--------|--------------|----------|
| Automotive | assembly-line | Assembly Press, Spot Welder, Painting Booth, Robot Pick & Place |
| Automotive | welding-line | Laser Cutter, Robot Welder, Spot Welder, Trimming Press |
| Electronics | smt-line | SMT Placement, Reflow Oven, AOI Inspection, Labeling |
| Electronics | through-hole-line | Wave Solder, AOI Inspection, Labeling |
| Food & Beverage | filling-line | Filling Machine, Capping, Labeling, Sealing |
| Furniture | assembly-line | CNC Router, Edge Bander, Assembly Press, Labeling |
| Metal Parts | fabrication-line | Metal Forming, Press Brake, Deburring, Labeling |
| Pharma | batch-line | Reactor Vessel, Pharma Filler, Capping, Labeling |
| Plastic Parts | molding-line | Injection Molding, Trimming Press, Labeling |
| Windows | frame-line | Profile Cutter, Corner Welder, Glass Setter, Sealing |

### REST API

Full API available at `http://localhost:8081/api/`:

| Endpoint | Description |
|----------|-------------|
| `GET /api/simulation` | Current simulation state |
| `PUT /api/simulation/timescale` | Adjust speed (0.1x - 100x) |
| `GET /api/lines` | List all production lines |
| `POST /api/lines/{id}/start\|stop` | Start/stop a line |
| `GET /api/machines` | List all machines with current state |
| `POST /api/machines/{id}/command` | Send start/stop/reset commands |
| `GET /api/orders` | List all production orders |
| `POST /api/orders` | Create a new order |
| `PUT /api/orders/{id}/status` | Update order status |
| `GET /api/operations` | List MES operations |
| `GET /api/recipes` | List available recipes per line |
| `GET/PUT /api/settings/machines/{id}` | View/adjust machine parameters |
| `GET/PUT /api/settings/buffers/{id}` | View/adjust buffer capacity |

## What Gets Created

After setup, your directory contains:

```
your-factory/
├── docker-compose.yaml          # Merged with additional services
├── docker-compose.yaml.backup   # Your original file
├── umh-core-data/               # UMH Core config
├── grafana/                     # Dockerfile + branding
├── grafana-data/                # Grafana database
├── grafana-provisioning/        # Datasource config
├── configs/                     # Nginx config
├── simulator-config/            # Machine & line definitions
├── simulator-data/              # Simulator state
├── timescaledb-data/            # PostgreSQL data
├── builder-generate.log         # Builder phase 1 log
├── builder-post-init.log        # Builder phase 2 log
└── reset-demo                   # Reset utility
```

## Custom Branding

Place a logo file (any format: PNG, JPG, SVG) in your directory before running `quick-start.sh`. The builder automatically converts it for Grafana.

## Configuration

| Option | Default | Description |
|--------|---------|-------------|
| `--version=X.Y.Z` | — | Template version to download (highest priority) |
| `VERSION` env var | 1.0.0 | Template version to download |
| `BUILDER_IMAGE` | dh2k/demo-builder:v1.0.0 | Builder Docker image |
| `SELECTED_LINES` | automotive-welding:1 | Line templates and instance counts |

### Simulator Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SIMULATOR_PROFILE` | — | Named profile from `simulator-config/profiles/` |
| `SIMULATOR_LINE_<TEMPLATE>` | — | Instance count per line template (e.g., `SIMULATOR_LINE_AUTOMOTIVE_WELDING=2`) |
| `SIMULATOR_WEBHOOK_ENABLED` | false | Enable webhook event publishing |
| `SIMULATOR_WEBHOOK_TARGET_URL` | — | Webhook endpoint (e.g., `http://umh-core:8090/api/v1/`) |
| `SIMULATOR_WEBHOOK_EVENT_TYPES` | — | Comma-separated event types to publish |
| `SIMULATOR_TIME_SCALE` | 1.0 | Simulation speed multiplier |
| `SIMULATOR_OPCUA_HOSTNAME` | localhost | OPC-UA server hostname |

## Reset

To start over:

```bash
./reset-demo
```
Then run the curl command again.

## Documentation

- [Architecture](docs/ARCHITECTURE.md) - Directory structure and builder flow
- [Contributing](docs/CONTRIBUTING.md) - How to add a new machine template

## Developer Tools

### Export Dashboard (Experimental)

`dashboardRework/export-dashboard.sh` exports a live Grafana dashboard and converts it back to a template by reversing the substitutions that `builder-generate.sh` applies.

**Setup:**
1. Create a Grafana API token at http://localhost:8080/org/apikeys
2. Save it in `dashboardRework/token.yaml`:
   ```
   GRAFANA_TOKEN=glsa_xxxxx
   ```

**Usage:**
```bash
cd dashboardRework

# Export a simple dashboard (operator, stop-reason-admin, etc.)
./export-dashboard.sh --compose ../../yourfactory/docker-compose.yaml operator-dashboard

# Export a per-line dashboard
./export-dashboard.sh --compose ../../yourfactory/docker-compose.yaml \
    --line line1 --line-display "Line 1" \
    line1-oee-dashboard

# Export a per-machine dashboard
./export-dashboard.sh --compose ../../yourfactory/docker-compose.yaml \
    --line line1 --line-display "Line 1" \
    --workcell injection-molding-L1-01 \
    --workcell-display "Injection Molding (Pos 1)" \
    injection-molding-L1-01-dashboard
```

The script automatically verifies round-trip conversion (template -> concrete -> template) and warns if any values couldn't be cleanly reversed.

Run `./export-dashboard.sh --help` for all options.

## Changelog

## v1.0.1-dev.2 (2026-02-14)

### Features
- changed version handling in script and docker container.

**Full Changelog**: [`v1.0.1-dev.1...v1.0.1-dev.2`](https://github.com/united-manufacturing-hub/umh-factory-demo/compare/v1.0.1-dev.1...v1.0.1-dev.2)

## v1.0.1-dev.1 (2026-02-14)

### Other
- added build script for both branches. updated readme.
- added release script
- bumped simulator version. added support for modbus
- added support for csv import of data points.
- added dashboard exporter script. updated readme.
- fixed query id error for stop-reason api
- api fixes. updated docs.
- changed spot-welder template. small fixes in the post-init script
- pipefail fix
- fixed pgbouncer id error.
- fixed script merging.
- Added container name check, repo override flag.

**Full Changelog**: [`v1.0.0...v1.0.1-dev.1`](https://github.com/united-manufacturing-hub/umh-factory-demo/compare/v1.0.0...v1.0.1-dev.1)
