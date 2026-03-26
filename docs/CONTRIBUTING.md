# Contributing

## Development Workflow

All changes go through pull requests to `staging`. Direct pushes are not allowed.

1. **Create a feature branch** from `staging`:
   ```bash
   git checkout -b feat/my-feature origin/staging
   ```

2. **Develop and test locally** using the `--local` flag:
   ```bash
   bash install.sh --local=/path/to/your/checkout --fixed-demo
   ```
   Make sure everything works before pushing.

3. **Push your branch and open a PR** targeting `staging`:
   ```bash
   git push -u origin feat/my-feature
   ```
   A GitHub Action will automatically comment on the PR with a test command for reviewers.

4. **Reviewer tests your branch** remotely using `--branch`:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/united-manufacturing-hub/umh-factory-demo/staging/install.sh -o install.sh && bash install.sh --branch=feat/my-feature
   ```

5. **After approval and merge**, a stable release is created automatically from `staging`.

### Commit messages

Use [conventional commits](https://www.conventionalcommits.org/) for automatic version bumping:
- `feat: ...` — bumps minor version
- `fix: ...` — bumps patch version
- `feat!: ...` or `BREAKING CHANGE` — bumps major version

---

# Adding a New Machine Type

This guide explains how to add a new machine type to the simulator.

## Step 1: Create the machine YAML file

Create `machines/<your-machine-type>.yaml` using kebab-case (e.g., `laser-cutter.yaml`, `cnc-lathe.yaml`).

This single file is the **complete definition** for the machine type in the exact UMH config format. Copy an existing one and modify.

## Step 2: Define the data model and contract

The top of the file defines the machine identity, data model, and data contract:

```yaml
name: laser-cutter                        # Machine type identifier (kebab-case)
display_name: "Laser Cutter"              # Human-readable name

dataModel:
  name: laser_cutter                      # Model name (underscore)
  version:
    v1:
      structure:
        State:
          _payloadshape: timeseries-string
        CycleCount:
          _payloadshape: timeseries-number
        LaserPower:
          _payloadshape: timeseries-number
        # ... add all tags your machine exposes

dataContract:
  name: _laser_cutter_v1
  model:
    name: laser_cutter
    version: v1
```

## Step 3: Define address mappings and the protocol converter

Define an `addressMappings` array that maps each OPC-UA node address to a tag name. This data is passed as instance variables at build time and rendered into the template via Go `{{ range }}`:

```yaml
addressMappings:
  - Address: "ns=1;i=3"
    TagName: State
    Unit: raw
    VirtualPath: ""
    LocationPathSuffix: ""
    DataContract: _laser_cutter_v1
  - Address: "ns=1;i=4"
    TagName: CycleCount
    Unit: raw
    VirtualPath: ""
    LocationPathSuffix: ""
    DataContract: _laser_cutter_v1
  - Address: "ns=1;i=5"
    TagName: LaserPower
    Unit: raw
    VirtualPath: ""
    LocationPathSuffix: ""
    DataContract: _laser_cutter_v1
  # ... one entry per OPC-UA node
```

The `protocolConverter` section uses the exact UMH config format. List all OPC-UA nodeIDs explicitly. The `tag_processor` uses a `defaults` block with a `switch` statement that iterates over `AddressMappings`:

```yaml
protocolConverter:
  connection:
    nmap:
      target: '{{ .IP }}'
      port: '{{ .PORT }}'
  dataflowcomponent_read:
    benthos:
      input:
        opcua:
          endpoint: opc.tcp://{{ .IP }}:{{ .PORT }}
          nodeIDs:
            - "ns=1;i=3"
            - "ns=1;i=4"
            - "ns=1;i=5"
            # ... all node IDs
          pollRate: 1000
          subscribeEnabled: false
      pipeline:
        processors:
          - tag_processor:
              defaults: |-
                msg.meta.location_path = "{{ .location_path }}";
                msg.meta.data_contract = "_laser_cutter_v1";
                msg.meta.virtual_path = "";
                msg.meta.historian = "true";
                msg.meta.timestamp_ms = msg.meta.opcua_server_timestamp;

                switch(msg.meta.opcua_attr_nodeid) {
                {{- range .AddressMappings }}
                  case "{{ .Address }}":
                    msg.meta.tag_name = "{{ .TagName }}";
                    msg.meta.unit = "{{ .Unit }}";
                    {{- if .VirtualPath }}msg.meta.virtual_path = "{{ .VirtualPath }}";{{- end }}
                    {{- if .LocationPathSuffix }}msg.meta.location_path += ".{{ .LocationPathSuffix }}";{{- end }}
                    {{- if .DataContract }}msg.meta.data_contract = "{{ .DataContract }}";{{- end }}

                    break;
                {{- end }}
                  default:
                    msg.meta.tag_name = msg.meta.opcua_tag_name;
                    msg.meta.unit = "raw";
                    break;
                }

                return msg;
      buffer:
        none: {}
```

The `{{ .IP }}`, `{{ .PORT }}`, and `{{ .location_path }}` are UMH runtime template variables — they are NOT build-time placeholders. The `{{ range .AddressMappings }}` iterates over the address mappings passed as instance variables.

### Key fields

| Section | Purpose |
|---------|---------|
| `name` | Machine type identifier, used in factory setup |
| `display_name` | Shown in dashboards and logs |
| `dataModel` | Defines tag structure and payload shapes |
| `dataContract` | Links contract name to model version |
| `addressMappings` | Maps OPC-UA addresses to tag names, units, and paths |
| `protocolConverter` | OPC-UA connection, nodeIDs, and tag processing template |

## Step 4: Add to factory setup

Include the machine in a factory setup YAML file:

```yaml
lines:
  - name: "Line1"
    machines:
      - laser-cutter        # <-- your new type
      - packaging
standalone:
  - laser-cutter
```

## Step 5: Test

```bash
# List available machine types (should show your new type)
python3 scripts/generate-config.py --list --machines-dir ./machines

# Generate config
python3 scripts/generate-config.py \
    --from-file test-setup.yaml \
    --output-dir ./test-output \
    --templates-dir ./templates \
    --machines-dir ./machines

# Check the output
cat test-output/config.yaml
```

## What happens at build time

When `generate-config.py` runs:

1. It scans `machines/*.yaml` and loads every machine definition
2. For each machine in the factory setup, it collects `dataModel` and `dataContract` into the config
3. It uses each machine's `protocolConverter` section directly as the template (no substitution needed)
4. It creates protocol converter instances with port assignments and location hierarchy
5. If a machine defines `addressMappings`, these are passed into the instance's `variables` as `AddressMappings` so the template can render them via `{{ range .AddressMappings }}`

No code changes required. Push the machine YAML to GitHub and the builder picks it up.
