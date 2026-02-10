# Architecture

## Directory Structure

```
umh-simulator/
├── quick-start.sh                    # Host-side init script (curl + run)
├── reset-demo                        # Teardown utility
├── machines/                         # One YAML per machine type (UMH config format)
│   ├── cnc-milling.yaml
│   ├── injection-molding.yaml
│   ├── metal-forming.yaml
│   ├── packaging.yaml
│   ├── robot-pick-place.yaml
│   ├── robot-welder.yaml
│   └── spot-welder.yaml
├── builder/
│   ├── Dockerfile                    # Python 3.11 + jq + psql + imagemagick
│   └── entrypoint.sh                # Downloads templates, dispatches phases
├── scripts/
│   ├── builder-generate.sh           # Phase 1: file generation
│   ├── builder-post-init.sh          # Phase 2: DB/Grafana init
│   ├── generate-config.py            # YAML-aware config assembly
│   ├── generate-historical-data.py   # Historical data generator
│   └── validate-config.py            # Config validation
├── templates/
│   ├── dataflows/                    # Benthos dataflow configs
│   └── dashboards/                   # Grafana dashboard JSON templates
├── config/
│   ├── docker-compose.yaml           # Additional services template
│   ├── grafana-provisioning/
│   ├── nginx.conf
│   └── simulator-config/             # Static simulator configuration
├── sql/                              # PostgreSQL schema + views
├── img/                              # Default branding (UMH logo)
└── docs/
```

## Two-Phase Builder Flow

The builder container runs through two phases, coordinated via signal files in `.builder/`:

```
Host (quick-start.sh)              Builder Container
─────────────────────              ─────────────────

1. Check prereqs (docker)
2. Scan ports, prompt user
3. Pull builder image
4. docker run -d builder           → Download templates from GitHub
                                   → PHASE 1 (generate):
                                      - Parse docker-compose.yaml
                                      - Merge services
                                      - Handle logo (imagemagick)
                                      - Generate dashboards (jq+sed)
                                      - Generate UMH config (Python)
                                      - Apply port remappings
                                   → Write signal: generate-done

5. Poll for generate-done
6. docker compose build grafana
7. docker compose up -d
8. Connect builder to network
9. Write signal: compose-started   → PHASE 2 (post-init):
                                      - Health check: TimescaleDB
                                      - Run SQL schema + views
                                      - Health check: Grafana
                                      - Import dashboards via API
                                      - Generate historical data
                                      - Cleanup intermediate files
                                   → Write signal: post-init-done

10. Poll for post-init-done
11. Remove builder container
12. Print access URLs
```

## Config Generation

`generate-config.py` builds `config.yaml` by reading and merging `machines/*.yaml` files:

1. Scan `machines/*.yaml` to load all machine definitions
2. Start with empty config, add `internal` services (topicbrowser, redpanda)
3. For each used machine type:
   - Collect `dataModel` and `dataContract` into config arrays
   - Use `protocolConverter` section directly as the template
4. Load all `templates/dataflows/*.yaml`, substitute location placeholders
5. Build protocol converter instances with port assignments
6. Add agent section from docker-compose values
7. Dump final YAML

## Machine YAML Format

Each machine type is a single `machines/{type}.yaml` file containing the complete UMH config sections — directly copy-pasteable into a UMH config.yaml:

- **`dataModel`** — Tag structure with payload shapes
- **`dataContract`** — Links contract name to model version
- **`protocolConverter`** — Connection, OPC-UA input, tag_processor pipeline with fully expanded nodeIDs and conditions

No placeholders to substitute, no separate metadata files. The `{{ .IP }}`, `{{ .PORT }}`, and `{{ .location_path }}` variables are UMH runtime template variables, not build-time substitutions.

## Adding a New Machine

See [CONTRIBUTING.md](CONTRIBUTING.md) for step-by-step instructions. Summary:

1. Create `machines/<type>.yaml` with dataModel, dataContract, and protocolConverter sections
2. Include in factory setup YAML
3. Push to GitHub - the builder picks it up automatically
