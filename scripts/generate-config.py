#!/usr/bin/env python3
"""
generate-config.py - Generate umh-core configuration from machine YAML files

Usage:
  ./generate-config.py --from-file setup.yaml     # Generate from factory setup file
  ./generate-config.py --list                      # List available machine types

Path Options:
  --output-dir PATH      Where to write config.yaml (default: ./umh-core-data)
  --templates-dir PATH   Where to find templates (default: ./templates)
  --machines-dir PATH    Where to find machine YAMLs (default: ./machines)
"""

import argparse
import os
import sys
from pathlib import Path
from io import StringIO

try:
    from ruamel.yaml import YAML
except ImportError:
    print("Error: ruamel.yaml is required. Install with: pip install ruamel.yaml")
    sys.exit(1)

SCRIPT_DIR = Path(__file__).parent.resolve()
REPO_ROOT = SCRIPT_DIR.parent


# ---------------------------------------------------------------------------
# Machine loading
# ---------------------------------------------------------------------------

def load_machines(machines_dir):
    """Load machine definitions from machines/*.yaml files."""
    yaml = YAML()
    machines = {}
    if not machines_dir.exists():
        return machines
    for machine_file in sorted(machines_dir.glob("*.yaml")):
        with open(machine_file) as f:
            data = yaml.load(f)
        if data and 'name' in data:
            machines[data['name']] = data
    return machines


def load_factory_setup(setup_path):
    """Load factory setup from YAML file."""
    yaml = YAML()
    with open(setup_path) as f:
        return yaml.load(f)


# ---------------------------------------------------------------------------
# Template assembly
# ---------------------------------------------------------------------------

def get_dataflow_requirements(df_file):
    """Parse '# requires: ...' comments from a dataflow YAML header."""
    requires = set()
    with open(df_file) as f:
        for line in f:
            stripped = line.strip()
            if not stripped.startswith('#'):
                break
            if stripped.startswith('# requires:'):
                requires.update(r.strip() for r in stripped.split(':', 1)[1].split(','))
    return requires


def build_dataflow_entry(df_file, enterprise, site):
    """Load a dataflow YAML, substitute placeholders, wrap in dataFlow entry."""
    yaml = YAML()
    yaml.preserve_quotes = True

    with open(df_file) as f:
        raw = f.read()

    # Strip leading comment lines
    lines = raw.split('\n')
    content_lines = []
    in_content = False
    for line in lines:
        if not in_content and line.strip().startswith('#'):
            continue
        in_content = True
        content_lines.append(line)
    clean = '\n'.join(content_lines)

    # Substitute location placeholders
    clean = clean.replace('__ENTERPRISE__', enterprise)
    clean = clean.replace('__SITE__', site)

    benthos = yaml.load(StringIO(clean))

    return {
        'name': df_file.stem,
        'desiredState': 'active',
        'dataFlowComponentConfig': {
            'benthos': benthos,
        },
    }


def build_instance(template_name, instance_name, host, port, location, address_mappings=None):
    """Build a protocolConverter instance entry."""
    variables = {'IP': host, 'PORT': str(port)}
    if address_mappings:
        variables['AddressMappings'] = address_mappings
    return {
        'name': instance_name,
        'desiredState': 'active',
        'protocolConverterServiceConfig': {
            'variables': variables,
            'location': location,
            'templateRef': template_name,
        },
    }


def get_docker_compose_values(output_dir):
    """Extract LOCATION_* and AUTH_TOKEN from docker-compose.yaml."""
    factory_dir = output_dir.parent if output_dir else Path.cwd()
    compose_file = factory_dir / 'docker-compose.yaml'
    if not compose_file.exists():
        compose_file = factory_dir / 'docker-compose.yml'

    values = {'location_0': 'Enterprise', 'location_1': 'Site', 'auth_token': None}

    if not compose_file.exists():
        return values

    yaml = YAML()
    with open(compose_file) as f:
        compose = yaml.load(f)

    if not compose or 'services' not in compose:
        return values

    umh = compose['services'].get('umh-core') or compose['services'].get('umh', {})
    env_list = umh.get('environment', [])
    if isinstance(env_list, list):
        for env in env_list:
            if isinstance(env, str) and '=' in env:
                key, val = env.split('=', 1)
                if key.startswith('LOCATION_'):
                    values[f'location_{key.split("_")[1]}'] = val
                elif key == 'AUTH_TOKEN':
                    values['auth_token'] = val
    elif isinstance(env_list, dict):
        for i in range(7):
            if f'LOCATION_{i}' in env_list:
                values[f'location_{i}'] = env_list[f'LOCATION_{i}']
        if 'AUTH_TOKEN' in env_list:
            values['auth_token'] = env_list['AUTH_TOKEN']

    return values


# ---------------------------------------------------------------------------
# Main config generation
# ---------------------------------------------------------------------------

def generate_config(factory_setup, machines, templates_dir, output_dir, skip_features=None):
    """Generate the complete config.yaml."""
    yaml = YAML()
    yaml.preserve_quotes = True
    yaml.default_flow_style = False

    enterprise = factory_setup.get('enterprise', 'Enterprise')
    site = factory_setup.get('site', 'Site')
    host = factory_setup.get('simulator_host', 'machine-simulator')

    # Start with empty config, add internal services
    config = {
        'internal': {
            'topicbrowser': {'desiredState': 'active'},
            'redpanda': {'desiredState': 'active'},
        },
    }

    # --- Collect dataModels and dataContracts from machine YAMLs ---
    templates_used = set()
    port = 4840
    instances = []

    # Collect all used templates and instances from lines + standalone
    for line_idx, line_cfg in enumerate(factory_setup.get('lines', []), start=1):
        line_name = line_cfg.get('name', f'Line{line_idx}')
        line_kebab = line_name.lower().replace(' ', '-').replace('_', '-')
        for pos_idx, machine_type in enumerate(line_cfg.get('machines', []), start=1):
            if machine_type not in machines:
                print(f"Error: Unknown machine type '{machine_type}'")
                sys.exit(1)
            templates_used.add(machine_type)
            instance_name = f"{machine_type}-L{line_idx}-{pos_idx:02d}"
            location = {
                "0": enterprise, "1": site, "2": "shopfloor",
                "3": line_kebab, "4": instance_name,
            }
            instances.append((machine_type, instance_name, host, port, location))
            port += 1

    standalone_counts = {}
    for machine_type in factory_setup.get('standalone', []):
        if machine_type not in machines:
            print(f"Error: Unknown machine type '{machine_type}'")
            sys.exit(1)
        templates_used.add(machine_type)
        standalone_counts[machine_type] = standalone_counts.get(machine_type, 0) + 1
        num = standalone_counts[machine_type]
        instance_name = f"{machine_type}-S{num:02d}"
        location = {
            "0": enterprise, "1": site, "2": "shopfloor",
            "3": "standalone", "4": instance_name,
        }
        instances.append((machine_type, instance_name, host, port, location))
        port += 1

    # Build dataModels and dataContracts arrays from used machine YAMLs
    data_models = []
    data_contracts = []
    for tname in sorted(templates_used):
        machine = machines[tname]
        if 'dataModel' in machine:
            data_models.append(machine['dataModel'])
        if 'dataContract' in machine:
            data_contracts.append(machine['dataContract'])

    config['dataModels'] = data_models
    config['dataContracts'] = data_contracts

    # Build protocol converter templates directly from machine YAMLs
    pc_templates = {}
    for tname in sorted(templates_used):
        print(f"  Building template: {tname}")
        pc_templates[tname] = machines[tname]['protocolConverter']

    config['templates'] = {'protocolConverter': pc_templates}

    # --- Dataflows ---
    skip = skip_features or set()
    dataflows_dir = templates_dir / 'dataflows'
    if dataflows_dir.exists():
        df_entries = []
        for df_file in sorted(dataflows_dir.glob('*.yaml')):
            reqs = get_dataflow_requirements(df_file)
            if reqs & skip:
                print(f"  Skipping dataflow: {df_file.stem} (requires: {', '.join(reqs & skip)})")
                continue
            print(f"  Adding dataflow: {df_file.stem}")
            df_entries.append(build_dataflow_entry(df_file, enterprise, site))
        if df_entries:
            config['dataFlow'] = df_entries

    # --- Protocol converter instances ---
    root_instances = set()
    pc_instances = []
    for tname, iname, h, p, loc in instances:
        if tname not in root_instances:
            root_instances.add(tname)
            effective_name = tname  # root instance: name == templateRef
        else:
            effective_name = iname
        address_mappings = machines[tname].get('addressMappings')
        pc_instances.append(build_instance(tname, effective_name, h, p, loc, address_mappings))
    config['protocolConverter'] = pc_instances

    # --- Agent section ---
    docker_values = get_docker_compose_values(output_dir)
    config['agent'] = {
        'location': {
            0: docker_values.get('location_0', enterprise),
            1: docker_values.get('location_1', site),
            2: '', 3: '', 4: '', 5: '', 6: '',
        },
        'releaseChannel': 'stable',
        'communicator': {
            'apiUrl': 'https://management.umh.app/api',
            'authToken': docker_values.get('auth_token') or 'YOUR_AUTH_TOKEN_HERE',
        },
        'metricsPort': 8080,
        'enableResourceLimitBlocking': False,
    }

    # Write output
    output_dir.mkdir(parents=True, exist_ok=True)
    config_path = output_dir / 'config.yaml'
    with open(config_path, 'w') as f:
        yaml.dump(config, f)

    print(f"\n  Config written to: {config_path}")
    return config_path


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def list_templates(machines_dir):
    """List available machine types."""
    machines = load_machines(machines_dir)
    if not machines:
        print("No machine types found.")
        return

    print("\nAvailable machine types:\n")
    for name in sorted(machines):
        machine = machines[name]
        display = machine.get('display_name', name)
        contract = machine.get('dataContract', {}).get('name', '?')
        print(f"  {display} ({name})")
        print(f"    Contract: {contract}")
        print()


def main():
    parser = argparse.ArgumentParser(description='Generate UMH config from factory setup')
    parser.add_argument('--from-file', help='Factory setup YAML file')
    parser.add_argument('--list', action='store_true', help='List available machine types')
    parser.add_argument('--output-dir', help='Output directory (default: ./umh-core-data)')
    parser.add_argument('--templates-dir', help='Templates directory (default: ./templates)')
    parser.add_argument('--machines-dir', help='Machines directory (default: ./machines)')
    args = parser.parse_args()

    # Resolve paths
    templates_dir = Path(args.templates_dir).resolve() if args.templates_dir else REPO_ROOT / 'templates'
    machines_dir = Path(args.machines_dir).resolve() if args.machines_dir else REPO_ROOT / 'machines'
    output_dir = Path(args.output_dir).resolve() if args.output_dir else REPO_ROOT / 'umh-core-data'

    if args.list:
        list_templates(machines_dir)
        return

    if not args.from_file:
        parser.print_help()
        sys.exit(1)

    # Load machines and factory setup
    machines = load_machines(machines_dir)
    if not machines:
        print(f"Error: No machine types found in {machines_dir}")
        sys.exit(1)

    factory_setup = load_factory_setup(args.from_file)

    print(f"\nGenerating config for: {factory_setup.get('enterprise', '?')}/{factory_setup.get('site', '?')}")

    # Determine features to skip based on env vars
    skip_features = set()
    if os.environ.get('NO_HISTORIAN', 'false').lower() == 'true':
        skip_features.add('historian')

    # Generate umh-core config
    generate_config(factory_setup, machines, templates_dir, output_dir, skip_features=skip_features)

    print("\nDone.")


if __name__ == '__main__':
    main()
