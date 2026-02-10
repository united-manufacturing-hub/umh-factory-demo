#!/usr/bin/env python3
"""
validate-config.py - Validate umh-core configuration files

This script validates generated configs against umh-core requirements before deployment.
Based on validation rules from umh-core source code:
- validation.go: Component name validation
- manager.go: Agent location requirements
- config.go: Structure and desiredState values
"""

import sys
import re
import argparse
from pathlib import Path
from dataclasses import dataclass, field
from typing import List, Dict, Any, Optional, Tuple

try:
    from ruamel.yaml import YAML
except ImportError:
    print("Error: ruamel.yaml not installed. Install with: pip install ruamel.yaml")
    sys.exit(3)


# Exit codes
EXIT_SUCCESS = 0
EXIT_VALIDATION_ERROR = 1
EXIT_FILE_NOT_FOUND = 2
EXIT_YAML_PARSE_ERROR = 3

# Valid desiredState values
VALID_DESIRED_STATES = {"active", "stopped"}


@dataclass
class ValidationError:
    """Represents a validation error or warning."""
    level: str  # "error" or "warning"
    path: str   # JSON path to the problematic field
    message: str
    hint: Optional[str] = None

    def __str__(self) -> str:
        prefix = "ERROR" if self.level == "error" else "WARNING"
        result = f"{prefix} [{self.path}]: {self.message}"
        if self.hint:
            result += f"\n  Hint: {self.hint}"
        return result


class ConfigValidator:
    """Validates umh-core configuration files."""

    def __init__(self, config: Dict[str, Any], config_path: str):
        self.config = config
        self.config_path = config_path
        self.errors: List[ValidationError] = []

    def validate(self) -> List[ValidationError]:
        """Run all validation checks and return list of errors/warnings."""
        self.errors = []

        # Core validations (errors)
        self.validate_agent_section()
        self.validate_agent_location()
        self.validate_templates()
        self.validate_protocol_converters()
        self.validate_data_flows()
        self.validate_stream_processors()
        self.validate_data_models()
        self.validate_data_contracts()

        # Optional validations (warnings)
        self.validate_desired_states()

        return self.errors

    def validate_agent_section(self) -> None:
        """Check that agent section exists."""
        if "agent" not in self.config:
            self.errors.append(ValidationError(
                level="error",
                path="agent",
                message="Missing required 'agent' section",
                hint="Add an 'agent' section with at least 'location' configuration"
            ))

    def validate_agent_location(self) -> None:
        """Check that agent.location exists and level 0 (enterprise) is set."""
        agent = self.config.get("agent", {})
        if not agent:
            return  # Already reported as missing

        location = agent.get("location")
        if location is None:
            self.errors.append(ValidationError(
                level="error",
                path="agent.location",
                message="Missing required 'location' in agent section",
                hint="Add 'location' map with at least level 0 (enterprise)"
            ))
            return

        # Location can be a dict with int or string keys
        level_0 = None
        if isinstance(location, dict):
            # Try int key first, then string key
            level_0 = location.get(0) or location.get("0")

        if not level_0:
            self.errors.append(ValidationError(
                level="error",
                path="agent.location.0",
                message="Missing required enterprise level (location 0)",
                hint="Add 'agent.location.0: YourEnterprise' to the config"
            ))

    def validate_component_name(self, name: str, path: str) -> bool:
        """
        Validate component name according to validation.go rules:
        - Cannot be empty
        - Must start and end with letter or number
        - Only letters, numbers, dashes and underscores allowed

        Returns True if valid, False if invalid (and adds error).
        """
        if not name:
            self.errors.append(ValidationError(
                level="error",
                path=path,
                message="Name cannot be empty"
            ))
            return False

        if name[0] in '-_' or name[-1] in '-_':
            self.errors.append(ValidationError(
                level="error",
                path=path,
                message=f"Name '{name}' must start and end with a letter or number",
                hint="Remove leading/trailing dashes or underscores"
            ))
            return False

        for char in name:
            if not (char.isalnum() or char in '-_'):
                self.errors.append(ValidationError(
                    level="error",
                    path=path,
                    message=f"Name '{name}' contains invalid character '{char}'",
                    hint="Only letters, numbers, dashes and underscores are allowed"
                ))
                return False

        return True

    def validate_templates(self) -> None:
        """Validate templates section structure."""
        templates = self.config.get("templates", {})
        if not templates:
            return  # Templates are optional

        # Validate protocol converter template names
        pc_templates = templates.get("protocolConverter", {})
        if isinstance(pc_templates, dict):
            for name in pc_templates.keys():
                self.validate_component_name(name, f"templates.protocolConverter.{name}")

        # Validate stream processor template names
        sp_templates = templates.get("streamProcessor", {})
        if isinstance(sp_templates, dict):
            for name in sp_templates.keys():
                self.validate_component_name(name, f"templates.streamProcessor.{name}")

    def validate_protocol_converters(self) -> None:
        """Validate protocol converter configurations."""
        converters = self.config.get("protocolConverter", [])
        if not converters:
            return

        # Get available templates from templates section
        templates = self.config.get("templates", {})
        available_templates = set(templates.get("protocolConverter", {}).keys())

        # Track names for uniqueness check
        seen_names: Dict[str, int] = {}

        # Track which templateRefs have a "root" instance (where name == templateRef)
        # umh-core requires a root instance for each template used by children
        root_templates: set = set()
        child_template_refs: Dict[str, List[int]] = {}  # templateRef -> list of indices

        for i, converter in enumerate(converters):
            path_prefix = f"protocolConverter[{i}]"

            # Validate name
            name = converter.get("name", "")
            if name:
                self.validate_component_name(name, f"{path_prefix}.name")

                # Check uniqueness
                if name in seen_names:
                    self.errors.append(ValidationError(
                        level="error",
                        path=f"{path_prefix}.name",
                        message=f"Duplicate protocol converter name '{name}'",
                        hint=f"First occurrence at protocolConverter[{seen_names[name]}]"
                    ))
                else:
                    seen_names[name] = i
            else:
                self.errors.append(ValidationError(
                    level="error",
                    path=f"{path_prefix}.name",
                    message="Protocol converter missing required 'name' field"
                ))

            # Validate template reference
            service_config = converter.get("protocolConverterServiceConfig", {})
            template_ref = service_config.get("templateRef")
            if template_ref:
                # Check if template exists in templates section
                if template_ref not in available_templates:
                    self.errors.append(ValidationError(
                        level="error",
                        path=f"{path_prefix}.protocolConverterServiceConfig.templateRef",
                        message=f"Template '{template_ref}' not found in templates section",
                        hint=f"Available templates: {', '.join(sorted(available_templates)) or 'none'}"
                    ))

                # Track root vs child instances
                # Root: name == templateRef (the "golden instance" that defines the template)
                # Child: name != templateRef (inherits from root)
                if name == template_ref:
                    root_templates.add(template_ref)
                else:
                    if template_ref not in child_template_refs:
                        child_template_refs[template_ref] = []
                    child_template_refs[template_ref].append(i)

        # Validate that every child's templateRef has a corresponding root instance
        # This is required by umh-core's convertSpecToYaml function
        for template_ref, child_indices in child_template_refs.items():
            if template_ref not in root_templates:
                # Report error for each child referencing a missing root
                for idx in child_indices:
                    child_name = converters[idx].get("name", "unknown")
                    self.errors.append(ValidationError(
                        level="error",
                        path=f"protocolConverter[{idx}].protocolConverterServiceConfig.templateRef",
                        message=f"No root instance found for template '{template_ref}'",
                        hint=f"Add a protocol converter with name='{template_ref}' and templateRef='{template_ref}' (root instance), "
                             f"or rename '{child_name}' to '{template_ref}' if this should be the root"
                    ))

    def validate_data_flows(self) -> None:
        """Validate data flow component configurations."""
        flows = self.config.get("dataFlow", [])
        if not flows:
            return

        seen_names: Dict[str, int] = {}

        for i, flow in enumerate(flows):
            path_prefix = f"dataFlow[{i}]"

            name = flow.get("name", "")
            if name:
                self.validate_component_name(name, f"{path_prefix}.name")

                if name in seen_names:
                    self.errors.append(ValidationError(
                        level="error",
                        path=f"{path_prefix}.name",
                        message=f"Duplicate data flow name '{name}'",
                        hint=f"First occurrence at dataFlow[{seen_names[name]}]"
                    ))
                else:
                    seen_names[name] = i
            else:
                self.errors.append(ValidationError(
                    level="error",
                    path=f"{path_prefix}.name",
                    message="Data flow missing required 'name' field"
                ))

    def validate_stream_processors(self) -> None:
        """Validate stream processor configurations."""
        processors = self.config.get("streamProcessor", [])
        if not processors:
            return

        # Get available templates
        templates = self.config.get("templates", {})
        available_templates = set(templates.get("streamProcessor", {}).keys())

        seen_names: Dict[str, int] = {}

        for i, processor in enumerate(processors):
            path_prefix = f"streamProcessor[{i}]"

            name = processor.get("name", "")
            if name:
                self.validate_component_name(name, f"{path_prefix}.name")

                if name in seen_names:
                    self.errors.append(ValidationError(
                        level="error",
                        path=f"{path_prefix}.name",
                        message=f"Duplicate stream processor name '{name}'",
                        hint=f"First occurrence at streamProcessor[{seen_names[name]}]"
                    ))
                else:
                    seen_names[name] = i
            else:
                self.errors.append(ValidationError(
                    level="error",
                    path=f"{path_prefix}.name",
                    message="Stream processor missing required 'name' field"
                ))

            # Validate template reference if present
            service_config = processor.get("streamProcessorServiceConfig", {})
            template_ref = service_config.get("templateRef")
            if template_ref and template_ref not in available_templates:
                self.errors.append(ValidationError(
                    level="error",
                    path=f"{path_prefix}.streamProcessorServiceConfig.templateRef",
                    message=f"Template '{template_ref}' not found",
                    hint=f"Available templates: {', '.join(sorted(available_templates)) or 'none'}"
                ))

    def validate_data_models(self) -> None:
        """Validate data model configurations."""
        models = self.config.get("dataModels", [])
        if not models:
            return

        seen_names: Dict[str, int] = {}
        version_pattern = re.compile(r'^v\d+$')

        for i, model in enumerate(models):
            path_prefix = f"dataModels[{i}]"

            name = model.get("name", "")
            if name:
                self.validate_component_name(name, f"{path_prefix}.name")

                if name in seen_names:
                    self.errors.append(ValidationError(
                        level="error",
                        path=f"{path_prefix}.name",
                        message=f"Duplicate data model name '{name}'",
                        hint=f"First occurrence at dataModels[{seen_names[name]}]"
                    ))
                else:
                    seen_names[name] = i
            else:
                self.errors.append(ValidationError(
                    level="error",
                    path=f"{path_prefix}.name",
                    message="Data model missing required 'name' field"
                ))

            # Validate version format
            versions = model.get("version", {})
            if isinstance(versions, dict):
                for version_key in versions.keys():
                    if not version_pattern.match(str(version_key)):
                        self.errors.append(ValidationError(
                            level="error",
                            path=f"{path_prefix}.version.{version_key}",
                            message=f"Invalid version format '{version_key}'",
                            hint="Version must match pattern 'v<number>' (e.g., v1, v2, v10)"
                        ))

    def validate_data_contracts(self) -> None:
        """Validate data contract configurations."""
        contracts = self.config.get("dataContracts", [])
        if not contracts:
            return

        # Build set of available data models with their versions
        available_models: Dict[str, set] = {}
        for model in self.config.get("dataModels", []):
            model_name = model.get("name", "")
            if model_name:
                versions = model.get("version", {})
                available_models[model_name] = set(versions.keys()) if isinstance(versions, dict) else set()

        seen_names: Dict[str, int] = {}

        for i, contract in enumerate(contracts):
            path_prefix = f"dataContracts[{i}]"

            name = contract.get("name", "")
            if name:
                self.validate_component_name(name.lstrip('_'), f"{path_prefix}.name")

                if name in seen_names:
                    self.errors.append(ValidationError(
                        level="error",
                        path=f"{path_prefix}.name",
                        message=f"Duplicate data contract name '{name}'",
                        hint=f"First occurrence at dataContracts[{seen_names[name]}]"
                    ))
                else:
                    seen_names[name] = i
            else:
                self.errors.append(ValidationError(
                    level="error",
                    path=f"{path_prefix}.name",
                    message="Data contract missing required 'name' field"
                ))

            # Validate model reference
            model_ref = contract.get("model")
            if model_ref:
                ref_name = model_ref.get("name", "")
                ref_version = model_ref.get("version", "")

                if ref_name not in available_models:
                    self.errors.append(ValidationError(
                        level="error",
                        path=f"{path_prefix}.model.name",
                        message=f"Referenced data model '{ref_name}' not found",
                        hint=f"Available models: {', '.join(sorted(available_models.keys())) or 'none'}"
                    ))
                elif ref_version and ref_version not in available_models.get(ref_name, set()):
                    self.errors.append(ValidationError(
                        level="error",
                        path=f"{path_prefix}.model.version",
                        message=f"Version '{ref_version}' not found in model '{ref_name}'",
                        hint=f"Available versions: {', '.join(sorted(available_models.get(ref_name, set()))) or 'none'}"
                    ))

    def validate_desired_states(self) -> None:
        """Validate desiredState values (warning level)."""
        # Check protocol converters
        for i, converter in enumerate(self.config.get("protocolConverter", [])):
            state = converter.get("desiredState", "")
            if state and state not in VALID_DESIRED_STATES:
                self.errors.append(ValidationError(
                    level="warning",
                    path=f"protocolConverter[{i}].desiredState",
                    message=f"Unknown desiredState '{state}'",
                    hint=f"Valid states: {', '.join(sorted(VALID_DESIRED_STATES))}"
                ))

        # Check data flows
        for i, flow in enumerate(self.config.get("dataFlow", [])):
            state = flow.get("desiredState", "")
            if state and state not in VALID_DESIRED_STATES:
                self.errors.append(ValidationError(
                    level="warning",
                    path=f"dataFlow[{i}].desiredState",
                    message=f"Unknown desiredState '{state}'",
                    hint=f"Valid states: {', '.join(sorted(VALID_DESIRED_STATES))}"
                ))

        # Check stream processors
        for i, processor in enumerate(self.config.get("streamProcessor", [])):
            state = processor.get("desiredState", "")
            if state and state not in VALID_DESIRED_STATES:
                self.errors.append(ValidationError(
                    level="warning",
                    path=f"streamProcessor[{i}].desiredState",
                    message=f"Unknown desiredState '{state}'",
                    hint=f"Valid states: {', '.join(sorted(VALID_DESIRED_STATES))}"
                ))

        # Check internal components
        internal = self.config.get("internal", {})
        for component in ["redpanda", "topicbrowser"]:
            comp_config = internal.get(component, {})
            state = comp_config.get("desiredState", "")
            if state and state not in VALID_DESIRED_STATES:
                self.errors.append(ValidationError(
                    level="warning",
                    path=f"internal.{component}.desiredState",
                    message=f"Unknown desiredState '{state}'",
                    hint=f"Valid states: {', '.join(sorted(VALID_DESIRED_STATES))}"
                ))


def load_yaml(config_path: str) -> Tuple[Optional[Dict[str, Any]], Optional[str]]:
    """Load and parse YAML file. Returns (config, error_message)."""
    yaml = YAML()
    yaml.preserve_quotes = True

    try:
        with open(config_path, 'r') as f:
            config = yaml.load(f)
            return config, None
    except FileNotFoundError:
        return None, f"File not found: {config_path}"
    except Exception as e:
        return None, f"YAML parse error: {e}"


def print_summary(errors: List[ValidationError]) -> None:
    """Print validation summary."""
    error_count = sum(1 for e in errors if e.level == "error")
    warning_count = sum(1 for e in errors if e.level == "warning")

    print("\n=== Validation Summary ===")
    print(f"Errors:   {error_count}")
    print(f"Warnings: {warning_count}")

    if error_count == 0:
        print("Status:   VALID")
    else:
        print("Status:   INVALID")


def main():
    parser = argparse.ArgumentParser(
        description="Validate umh-core configuration files",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Exit codes:
  0 - Valid config (no errors, warnings may exist)
  1 - Validation errors found
  2 - File not found
  3 - YAML parse error

Examples:
  %(prog)s config.yaml
  %(prog)s --quiet config.yaml
  %(prog)s --warnings-as-errors config.yaml
"""
    )
    parser.add_argument("config_file", help="Path to the config.yaml file to validate")
    parser.add_argument("-q", "--quiet", action="store_true",
                        help="Only print errors, not warnings")
    parser.add_argument("-w", "--warnings-as-errors", action="store_true",
                        help="Treat warnings as errors (affects exit code)")
    parser.add_argument("-v", "--verbose", action="store_true",
                        help="Print additional debug information")

    args = parser.parse_args()

    # Load config file
    config, error = load_yaml(args.config_file)

    if error:
        if "not found" in error.lower():
            print(f"ERROR: {error}")
            sys.exit(EXIT_FILE_NOT_FOUND)
        else:
            print(f"ERROR: {error}")
            sys.exit(EXIT_YAML_PARSE_ERROR)

    if config is None:
        print("ERROR: Config file is empty")
        sys.exit(EXIT_YAML_PARSE_ERROR)

    if args.verbose:
        print(f"Validating: {args.config_file}")
        print(f"Config sections: {list(config.keys())}")

    # Run validation
    validator = ConfigValidator(config, args.config_file)
    errors = validator.validate()

    # Filter and print errors
    if args.quiet:
        errors_to_print = [e for e in errors if e.level == "error"]
    else:
        errors_to_print = errors

    for error in errors_to_print:
        print(error)
        print()

    # Print summary
    print_summary(errors)

    # Determine exit code
    error_count = sum(1 for e in errors if e.level == "error")
    warning_count = sum(1 for e in errors if e.level == "warning")

    if args.warnings_as_errors and warning_count > 0:
        sys.exit(EXIT_VALIDATION_ERROR)
    elif error_count > 0:
        sys.exit(EXIT_VALIDATION_ERROR)
    else:
        sys.exit(EXIT_SUCCESS)


if __name__ == "__main__":
    main()
