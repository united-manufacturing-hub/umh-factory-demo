# UMH Simulator

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

```bash
curl -fsSL https://github.com/united-manufacturing-hub/umh-simulator/releases/download/v1.0.0/quick-start.sh -o quick-start.sh && bash quick-start.sh
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

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `VERSION` | 1.0.0 | Template version to download |
| `BUILDER_IMAGE` | dh2k/demo-builder:v1.0.0 | Builder Docker image |

## Reset

To start over:

```bash
./reset-demo
bash quick-start.sh
```

## Factory Configuration

The default demo includes 9 machines across 2 production lines + 1 standalone:

- **Line 1:** Injection Molding → Robot Pick & Place → CNC Milling → Robot Pick & Place → Packaging
- **Line 2:** Metal Forming → Spot Welder → Packaging
- **Standalone:** Robot Welder

## Documentation

- [Architecture](docs/ARCHITECTURE.md) - Directory structure and builder flow
- [Contributing](docs/CONTRIBUTING.md) - How to add a new machine template
