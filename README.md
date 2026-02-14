# UMH Simulator

[![GitHub](https://img.shields.io/badge/GitHub-umh--factory--demo-blue)](https://github.com/united-manufacturing-hub/umh-factory-demo)

Factory demo environment for the United Manufacturing Hub (UMH). Sets up a complete stack with OPC-UA machine simulation, data collection, dashboards, and analytics.

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
curl -fsSL https://github.com/united-manufacturing-hub/umh-factory-demo/releases/latest/download/quick-start.sh -o quick-start.sh && bash quick-start.sh --dev
```

**Specific version:**
```bash
curl -fsSL https://github.com/united-manufacturing-hub/umh-factory-demo/releases/latest/download/quick-start.sh -o quick-start.sh && bash quick-start.sh --version=1.0.0
```

**Custom repo:**
```bash
curl -fsSL https://github.com/united-manufacturing-hub/umh-factory-demo/releases/latest/download/quick-start.sh -o quick-start.sh && bash quick-start.sh --repo=myRepo/umh-factory-demo
```

### 3. Access

| Service | URL |
|---------|-----|
| Grafana | http://localhost:8080 (admin/admin) |
| Machine Simulator | http://localhost:8081 |
| API (via Nginx) | http://localhost:80 |

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
├── simulator-config/            # Machine definitions
├── simulator-data/              # Simulator state
├── timescaledb-data/            # PostgreSQL data
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

## Reset

To start over:

```bash
./reset-demo
```
Then run the curl command again

## Factory Configuration

The default demo includes 9 machines across 2 production lines + 1 standalone:

- **Line 1:** Injection Molding → Robot Pick & Place → CNC Milling → Robot Pick & Place → Packaging
- **Line 2:** Metal Forming → Spot Welder → Packaging
- **Standalone:** Robot Welder

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

## v1.1.0 (2026-02-14)

### Features
- trigger stable release
- changed version handling in script and docker container.

### Other
- release: v1.0.1-dev.1

**Full Changelog**: [`v1.0.1...v1.1.0`](https://github.com/united-manufacturing-hub/umh-factory-demo/compare/v1.0.1...v1.1.0)

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

