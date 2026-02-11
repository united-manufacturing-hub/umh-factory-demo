#!/usr/bin/env python3
"""
Historical Data Generator for UMH Demo

Generates realistic historical data for machine simulation including:
- Tag values (CycleCount, GoodParts, ScrapParts, CycleTime, machine-specific sensor tags)
- Tag string values (State as string for availability dashboards)
- Tag numeric State values (State as integer for state timeline dashboards)
- Machine stops with assigned reasons

Tag names match the protocol converter templates exactly so that
Grafana dashboards display the data correctly.

Can enumerate workcell instances from a factory-setup.yaml file,
or fall back to machine type names via --machines.

Usage:
    ./generate-historical-data.py --days 7 --factory-setup /path/to/factory-setup.yaml --host pgbouncer
    ./generate-historical-data.py --days 3 --machines metal-forming cnc-milling --host localhost
"""

import argparse
import random
import sys
import time
from datetime import datetime, timedelta
from typing import List, Dict, Any, Optional, Tuple

try:
    import psycopg2
    from psycopg2.extras import execute_values
except ImportError:
    print("Error: psycopg2 is required. Install with: pip install psycopg2-binary")
    sys.exit(1)

# State integer mappings matching Grafana dashboard queries:
#   machine-dashboard.json:  CASE WHEN value = 0 THEN 'Idle' ... value = 2 THEN 'Running' ...
#   tag_string queries:      WHERE t.value = 'RUNNING'
STATE_INT = {
    "IDLE": 0,
    "RUNNING": 2,
    "STOPPED": 3,       # PlannedStop
    "FAULT": 4,          # UnplannedStop
    "MAINTENANCE": 3,    # PlannedStop
}

# Machine types and their configurations.
# Cycle times, scrap rates, breakdown probabilities match simulator-config/default.yaml.
# Tag names match the protocol converter templates exactly.
# Common tags emitted for ALL machines: State, CycleCount, GoodParts, ScrapParts, CycleTime, ErrorCode
MACHINE_CONFIGS = {
    "injection-molding": {
        "cycle_time_ms": 8000,
        "scrap_rate": 0.03,
        "breakdown_prob": 0.0003,
        "tags": {
            # From protocol-converters/injection-molding.yaml
            "BarrelTemperature": (180, 220),       # barrel_zone1_temp_c
            "MoldTemperature": (40, 50),            # mold_temp_c
            "InjectionPressure": (1400, 1600),      # injection_pressure_bar
            "HoldingPressure": (600, 800),          # holding_pressure_bar
            "ScrewPosition": (0, 150),              # screw_position_mm
            "ScrewSpeed": (80, 120),                # screw_speed_rpm
            "ClampForce": (1800, 2200),             # clamp_force_kN
            "CoolingTime": (10, 20),                # cooling_time_sec
            "ShotWeight": (45, 55),                 # shot_weight_g
            "CushionPosition": (5, 15),             # cushion_mm
        },
    },
    "cnc-milling": {
        "cycle_time_ms": 12000,
        "scrap_rate": 0.01,
        "breakdown_prob": 0.0002,
        "tags": {
            # From protocol-converters/cnc-milling.yaml
            "SpindleSpeed": (3000, 5000),           # spindle_speed_rpm
            "SpindleLoad": (40, 55),                # spindle_load_percent
            "FeedRate": (800, 1200),                # feed_rate_mmpm
            "PositionX": (0, 500),                  # x_position_mm
            "PositionY": (0, 400),                  # y_position_mm
            "PositionZ": (-200, 0),                 # z_position_mm
            "ToolNumber": (1, 8),                   # tool_number
            "ToolWear": (0, 80),                    # tool_life_percent
            "CoolantFlow": (5, 15),                 # coolant_flow_lpm
            "CoolantTemp": (20, 25),                # coolant_temp_c
        },
    },
    "robot-pick-place": {
        "cycle_time_ms": 3000,
        "scrap_rate": 0.005,
        "breakdown_prob": 0.0001,
        "tags": {
            # From protocol-converters/robot-pick-place.yaml
            "Joint1": (-180, 180),                  # joint1_deg
            "Joint2": (-90, 90),                    # joint2_deg
            "Joint3": (-170, 170),                  # joint3_deg
            "Joint4": (-180, 180),                  # joint4_deg
            "Joint5": (-120, 120),                  # joint5_deg
            "Joint6": (-360, 360),                  # joint6_deg
            "PositionX": (0, 1000),                 # tcp_x_mm
            "PositionY": (0, 800),                  # tcp_y_mm
            "PositionZ": (0, 600),                  # tcp_z_mm
            "GripperState": (0, 100),               # gripper_open_percent
            "GripForce": (40, 60),                  # gripper_force_N
            "Speed": (60, 95),                      # speed_percent
        },
    },
    "packaging": {
        "cycle_time_ms": 2000,
        "scrap_rate": 0.01,
        "breakdown_prob": 0.0002,
        "tags": {
            # From protocol-converters/packaging.yaml
            "ConveyorSpeed": (5, 15),               # conveyor_speed_mpm
            "BoxesPerMinute": (8, 15),              # boxes_per_minute
            "BoxCount": (0, 500),                   # current_box_count (resets daily)
            "PalletsCompleted": (0, 50),            # pallets_completed
            "SealerTemp": (150, 170),               # sealer_temp_c
            "SealerPressure": (180, 220),           # sealer_pressure_bar
            "LabelsPrinted": (0, 500),              # labels_printed
            "LabelRollRemaining": (100, 5000),      # label_roll_remaining
            "Weight": (2.0, 5.0),                   # last_weight_kg
        },
    },
    "metal-forming": {
        "cycle_time_ms": 5000,
        "scrap_rate": 0.02,
        "breakdown_prob": 0.0005,
        "tags": {
            # From protocol-converters/metal-forming.yaml
            "PressForce": (800, 1200),              # press_force_kN
            "MaterialTemp": (170, 190),             # material_temp_c
            "HydraulicPressure": (230, 270),        # hydraulic_pressure_bar
            "MotorCurrent": (40, 80),               # motor_current_A
            "OilLevel": (75, 100),                  # oil_level_percent
            "Vibration": (0.5, 2.0),                # vibration_rms
            "ProductionRate": (600, 720),            # production_rate_pph
            "ToolWear": (0, 80),                    # tool_wear_percent
        },
    },
    "spot-welder": {
        "cycle_time_ms": 4000,
        "scrap_rate": 0.015,
        "breakdown_prob": 0.0004,
        "tags": {
            # From protocol-converters/spot-welder.yaml
            "WeldCurrent": (8, 12),                 # weld_current_kA
            "WeldVoltage": (1500, 2500),            # weld_voltage_mV
            "WeldTime": (150, 300),                 # weld_time_ms
            "ElectrodeForce": (2.5, 3.5),           # electrode_force_kN
            "ElectrodeWear": (0, 2.0),              # electrode_wear_mm
            "NuggetDiameter": (4, 6),               # nugget_diameter_mm
            "WeldQuality": (0, 1),                  # weld_quality_flag
            "CoolingTemp": (20, 30),                # cooling_water_temp_c
            "CoolingFlow": (5, 10),                 # cooling_water_flow_lpm
            "SpotNumber": (1, 12),                  # current_spot_number
            "SpotsPerPart": (8, 12),                # spots_per_part
        },
    },
    "robot-welder": {
        "cycle_time_ms": 15000,
        "scrap_rate": 0.02,
        "breakdown_prob": 0.0003,
        "tags": {
            # From protocol-converters/robot-welder.yaml
            "Joint1": (-180, 180),                  # joint1_deg
            "Joint2": (-90, 90),                    # joint2_deg
            "Joint3": (-170, 170),                  # joint3_deg
            "Joint4": (-180, 180),                  # joint4_deg
            "Joint5": (-120, 120),                  # joint5_deg
            "Joint6": (-360, 360),                  # joint6_deg
            "WeldCurrent": (180, 220),              # weld_current_A
            "WeldVoltage": (22, 28),                # weld_voltage_V
            "WireSpeed": (5, 10),                   # wire_speed_mpm
            "GasFlow": (12, 18),                    # gas_flow_lpm
            "WeldQuality": (85, 100),               # weld_quality_score
        },
    },
}

# Stop reasons with their weights (likelihood)
STOP_REASONS = {
    1: ("Unspecified", 0.05),
    2: ("Material shortage", 0.15),
    3: ("Tool change", 0.20),
    4: ("Operator break", 0.25),
    5: ("Maintenance", 0.10),
    6: ("Quality issue", 0.08),
    7: ("Setup/changeover", 0.12),
    8: ("Waiting for parts", 0.03),
    9: ("Equipment failure", 0.02),
}

# Shift configuration (default: 2 shifts)
SHIFT_START_HOUR = 6   # 6 AM
SHIFT_END_HOUR = 22    # 10 PM


def parse_args():
    parser = argparse.ArgumentParser(
        description="Generate historical data for UMH demo"
    )
    parser.add_argument(
        "--days", type=int, default=7,
        help="Number of days of historical data to generate (max 7, default: 7)"
    )
    parser.add_argument(
        "--since", type=str,
        help="Start date (YYYY-MM-DD format). Overrides --days."
    )
    parser.add_argument(
        "--factory-setup", type=str,
        help="Path to factory-setup.yaml to enumerate workcell instances"
    )
    parser.add_argument(
        "--machines", nargs="+", default=None,
        help="Machine types to generate data for (fallback when --factory-setup not provided)"
    )
    parser.add_argument(
        "--host", type=str, default="localhost",
        help="PostgreSQL host (default: localhost)"
    )
    parser.add_argument(
        "--port", type=int, default=5432,
        help="PostgreSQL port (default: 5432)"
    )
    parser.add_argument(
        "--db", type=str, default="umh",
        help="Database name (default: umh)"
    )
    parser.add_argument(
        "--user", type=str, default="postgres",
        help="Database user (default: postgres)"
    )
    parser.add_argument(
        "--password", type=str, default="postgres",
        help="Database password (default: postgres)"
    )
    parser.add_argument(
        "--batch-size", type=int, default=1000,
        help="Batch size for inserts (default: 1000)"
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Print what would be generated without inserting"
    )
    parser.add_argument(
        "--skip-weekends", action="store_true",
        help="Skip weekend days (default: weekends included)"
    )
    return parser.parse_args()


def parse_factory_setup(path: str) -> Tuple[str, str, List[Dict[str, Any]]]:
    """Parse factory-setup.yaml and return (enterprise, site, workcell_list).

    Each workcell dict has: machine_type, workcell_name, line_name, area.
    """
    import yaml

    with open(path, "r") as f:
        setup = yaml.safe_load(f)

    enterprise = setup.get("enterprise", "Enterprise")
    site = setup.get("site", "Site")
    area = "shopfloor"

    workcells = []

    # Process production lines
    for i, line in enumerate(setup.get("lines", [])):
        line_name = line.get("name", f"Line{i+1}")
        line_lower = line_name.lower()
        line_num = i + 1
        machines = line.get("machines", [])

        for pos, machine_type in enumerate(machines, start=1):
            workcell_name = f"{machine_type}-L{line_num}-{pos:02d}"
            workcells.append({
                "machine_type": machine_type,
                "workcell_name": workcell_name,
                "line_name": line_lower,
                "area": area,
            })

    # Process standalone machines
    for machine_type in setup.get("standalone", []):
        workcell_name = f"{machine_type}-standalone"
        workcells.append({
            "machine_type": machine_type,
            "workcell_name": workcell_name,
            "line_name": workcell_name,
            "area": area,
        })

    return enterprise, site, workcells


def get_asset_id(conn, enterprise: str, site: str, area: str, line: str, workcell: str) -> Optional[int]:
    """Look up asset_id from the database."""
    cursor = conn.cursor()
    cursor.execute(
        "SELECT id FROM asset WHERE enterprise=%s AND site=%s AND area=%s AND line=%s AND workcell=%s",
        (enterprise, site, area, line, workcell),
    )
    row = cursor.fetchone()
    cursor.close()
    return row[0] if row else None


def get_asset_id_by_workcell(conn, workcell: str) -> Optional[int]:
    """Look up asset_id by workcell name only (fallback for --machines mode)."""
    cursor = conn.cursor()
    cursor.execute(
        "SELECT id FROM asset WHERE workcell=%s LIMIT 1",
        (workcell,),
    )
    row = cursor.fetchone()
    cursor.close()
    return row[0] if row else None


def is_shift_time(dt: datetime, skip_weekends: bool = False) -> bool:
    """Check if datetime is within shift hours."""
    if skip_weekends and dt.weekday() >= 5:  # Saturday=5, Sunday=6
        return False
    return SHIFT_START_HOUR <= dt.hour < SHIFT_END_HOUR


def choose_stop_reason() -> int:
    """Choose a random stop reason based on weights."""
    reasons = list(STOP_REASONS.keys())
    weights = [STOP_REASONS[r][1] for r in reasons]
    return random.choices(reasons, weights=weights)[0]


def generate_tag_value(tag_range: tuple) -> float:
    """Generate a random tag value within the specified range."""
    min_val, max_val = tag_range
    return round(random.uniform(min_val, max_val), 2)


def emit_state_change(state: str, current_time: datetime, tag_records: list, tag_string_records: list):
    """Emit a state change to both tag (numeric) and tag_string (string) tables."""
    tag_string_records.append((current_time, "State", state))
    tag_records.append((current_time, "State", float(STATE_INT.get(state, 0))))


def generate_machine_data(
    machine_type: str,
    config: Dict[str, Any],
    start_time: datetime,
    end_time: datetime,
    skip_weekends: bool = False,
) -> Dict[str, List]:
    """Generate historical data for a single machine instance.

    Returns dict with keys: tag_records, tag_string_records, stops, good_parts, scrap_parts
    - tag_records: list of (timestamp, name, value) for numeric tags
    - tag_string_records: list of (timestamp, name, value) for string tags
    - stops: list of dicts with start_time, end_time, stop_reason_id
    """

    tag_records = []       # (timestamp, name, value)
    tag_string_records = []  # (timestamp, name, value)
    stops = []

    current_time = start_time
    cycle_time = timedelta(milliseconds=config["cycle_time_ms"])
    state = "IDLE"
    cycle_count = 0
    good_parts = 0
    scrap_parts = 0

    # Track stops
    current_stop_start = None

    # Progress tracking
    total_seconds = (end_time - start_time).total_seconds()
    last_printed_day = None

    # Emit initial state to both tables
    emit_state_change("IDLE", current_time, tag_records, tag_string_records)

    while current_time < end_time:
        # Print progress when the simulated day changes
        current_day = current_time.date()
        if current_day != last_printed_day:
            elapsed_pct = (current_time - start_time).total_seconds() / total_seconds * 100
            print(f"      Simulating {current_day} ... {elapsed_pct:5.1f}%", flush=True)
            last_printed_day = current_day

        in_shift = is_shift_time(current_time, skip_weekends)

        if in_shift:
            if state == "IDLE":
                # Start running
                state = "RUNNING"
                emit_state_change("RUNNING", current_time, tag_records, tag_string_records)
                if current_stop_start:
                    # End any idle stop
                    stops.append({
                        "start_time": current_stop_start,
                        "end_time": current_time,
                        "stop_reason_id": 4,  # Operator break (shift start)
                    })
                    current_stop_start = None

            # Check for random breakdown
            if state == "RUNNING" and random.random() < config["breakdown_prob"]:
                state = "FAULT"
                emit_state_change("FAULT", current_time, tag_records, tag_string_records)
                current_stop_start = current_time

            # Check for random planned stop (tool change, quality check, etc.)
            if state == "RUNNING" and random.random() < 0.002:
                state = "STOPPED"
                emit_state_change("STOPPED", current_time, tag_records, tag_string_records)
                current_stop_start = current_time

            # Handle fault recovery
            if state == "FAULT":
                fault_duration = timedelta(minutes=random.randint(5, 30))
                if current_stop_start and (current_time - current_stop_start) >= fault_duration:
                    stops.append({
                        "start_time": current_stop_start,
                        "end_time": current_time,
                        "stop_reason_id": 9,  # Equipment failure
                    })
                    state = "RUNNING"
                    emit_state_change("RUNNING", current_time, tag_records, tag_string_records)
                    current_stop_start = None

            # Handle planned stop recovery
            if state == "STOPPED":
                stop_duration = timedelta(minutes=random.randint(2, 15))
                if current_stop_start and (current_time - current_stop_start) >= stop_duration:
                    reason = choose_stop_reason()
                    if reason == 9:  # Don't use equipment failure for planned stops
                        reason = 3  # Use tool change instead
                    stops.append({
                        "start_time": current_stop_start,
                        "end_time": current_time,
                        "stop_reason_id": reason,
                    })
                    state = "RUNNING"
                    emit_state_change("RUNNING", current_time, tag_records, tag_string_records)
                    current_stop_start = None

            # Generate running data
            if state == "RUNNING":
                cycle_count += 1
                is_good = random.random() > config["scrap_rate"]
                if is_good:
                    good_parts += 1
                else:
                    scrap_parts += 1

                # Common tags (all machines):
                # CycleCount - cumulative counter from OPC-UA
                tag_records.append((current_time, "CycleCount", float(cycle_count)))
                # GoodParts - cumulative counter (used by all dashboards for OEE quality)
                tag_records.append((current_time, "GoodParts", float(good_parts)))
                # ScrapParts - cumulative counter (used by all dashboards for OEE quality)
                tag_records.append((current_time, "ScrapParts", float(scrap_parts)))
                # CycleTime - in seconds (protocol converter maps cycle_time_sec)
                cycle_time_sec = config["cycle_time_ms"] / 1000.0 * random.uniform(0.9, 1.1)
                tag_records.append((current_time, "CycleTime", round(cycle_time_sec, 2)))
                # ErrorCode - 0 during normal operation
                tag_records.append((current_time, "ErrorCode", 0.0))

                # Machine-specific tags from protocol converter
                for tag_name, tag_range in config["tags"].items():
                    tag_records.append((current_time, tag_name, generate_tag_value(tag_range)))

            # Emit ErrorCode during fault states
            if state == "FAULT":
                tag_records.append((current_time, "ErrorCode", float(random.randint(100, 999))))

            # Handle maintenance trigger (every ~2000 cycles, random)
            if state == "RUNNING" and cycle_count > 0 and cycle_count % 2000 == 0 and random.random() < 0.3:
                state = "MAINTENANCE"
                emit_state_change("MAINTENANCE", current_time, tag_records, tag_string_records)
                current_stop_start = current_time

        else:
            # Outside shift hours
            if state == "RUNNING":
                state = "IDLE"
                emit_state_change("IDLE", current_time, tag_records, tag_string_records)
                current_stop_start = current_time

            # Handle maintenance completion
            if state == "MAINTENANCE":
                maint_duration = timedelta(minutes=random.randint(15, 45))
                if current_stop_start and (current_time - current_stop_start) >= maint_duration:
                    stops.append({
                        "start_time": current_stop_start,
                        "end_time": current_time,
                        "stop_reason_id": 5,  # Maintenance
                    })
                    state = "IDLE"
                    emit_state_change("IDLE", current_time, tag_records, tag_string_records)
                    current_stop_start = current_time

        # Advance time
        if state == "RUNNING":
            current_time += cycle_time
        else:
            current_time += timedelta(seconds=30)  # Check every 30 seconds when not running

    return {
        "tag_records": tag_records,
        "tag_string_records": tag_string_records,
        "stops": stops,
        "good_parts": good_parts,
        "scrap_parts": scrap_parts,
    }


def insert_tag_values(conn, asset_id: int, tag_records: List[Tuple], batch_size: int = 1000) -> int:
    """Insert numeric tag values into the tag table."""
    if not tag_records:
        return 0

    cursor = conn.cursor()
    inserted = 0
    total = len(tag_records)

    for i in range(0, total, batch_size):
        batch = tag_records[i:i + batch_size]
        values = [
            (ts, asset_id, name, value, "historical-data-generator")
            for ts, name, value in batch
        ]
        execute_values(
            cursor,
            """
            INSERT INTO tag (timestamp, asset_id, name, value, origin)
            VALUES %s
            ON CONFLICT DO NOTHING
            """,
            values,
        )
        inserted += cursor.rowcount
        done = min(i + batch_size, total)
        print(f"      Inserting tags ... {done}/{total}", end="\r", flush=True)

    print(f"      Inserting tags ... {total}/{total} done    ")
    conn.commit()
    cursor.close()
    return inserted


def insert_tag_string_values(conn, asset_id: int, tag_string_records: List[Tuple], batch_size: int = 1000) -> int:
    """Insert string tag values into the tag_string table."""
    if not tag_string_records:
        return 0

    cursor = conn.cursor()
    inserted = 0
    total = len(tag_string_records)

    for i in range(0, total, batch_size):
        batch = tag_string_records[i:i + batch_size]
        values = [
            (ts, asset_id, name, value, "historical-data-generator")
            for ts, name, value in batch
        ]
        execute_values(
            cursor,
            """
            INSERT INTO tag_string (timestamp, asset_id, name, value, origin)
            VALUES %s
            ON CONFLICT DO NOTHING
            """,
            values,
        )
        inserted += cursor.rowcount
        done = min(i + batch_size, total)
        print(f"      Inserting states ... {done}/{total}", end="\r", flush=True)

    print(f"      Inserting states ... {total}/{total} done    ")
    conn.commit()
    cursor.close()
    return inserted


def insert_stops(conn, asset_id: int, stops: List[Dict], batch_size: int = 1000) -> int:
    """Insert stop records into the database."""
    if not stops:
        return 0

    cursor = conn.cursor()
    inserted = 0
    total = len(stops)

    for i in range(0, total, batch_size):
        batch = stops[i:i + batch_size]
        values = [
            (asset_id, s["start_time"], s["end_time"], s["stop_reason_id"])
            for s in batch
        ]
        execute_values(
            cursor,
            """
            INSERT INTO machine_stops (asset_id, start_time, end_time, stop_reason_id)
            VALUES %s
            ON CONFLICT DO NOTHING
            """,
            values,
        )
        inserted += cursor.rowcount
        done = min(i + batch_size, total)
        print(f"      Inserting stops ... {done}/{total}", end="\r", flush=True)

    print(f"      Inserting stops ... {total}/{total} done    ")
    conn.commit()
    cursor.close()
    return inserted


def generate_production_orders(
    line_name: str,
    line_asset_id: int,
    good_parts: int,
    scrap_parts: int,
    start_time: datetime,
    end_time: datetime,
) -> List[Dict]:
    """Generate historical production orders for a line.

    Creates orders that span the time range, with realistic quantities.
    Returns list of order dicts ready for insertion.
    """
    orders = []
    if good_parts <= 0:
        return orders

    # Generate orders that sum up to approximately the total good_parts
    total_duration = (end_time - start_time).total_seconds()
    current_time = start_time
    remaining_good = good_parts
    remaining_scrap = scrap_parts
    order_num = 1

    # Product types per line
    product_types = {
        "line1": ["MOLDED-PART-001", "MOLDED-PART-002"],
        "line2": ["METAL-ASSEMBLY-001", "METAL-ASSEMBLY-002"],
    }
    products = product_types.get(line_name.lower(), ["PRODUCT-001"])

    while remaining_good > 0 and current_time < end_time:
        # Order size: 20-100 parts
        order_qty = min(remaining_good, random.randint(20, 100))
        # Scrap is proportional
        scrap_ratio = scrap_parts / max(good_parts, 1)
        order_scrap = int(order_qty * scrap_ratio * random.uniform(0.5, 1.5))
        order_scrap = min(order_scrap, remaining_scrap)

        # Order duration based on quantity (roughly 1-2 min per part at line level)
        order_duration_s = order_qty * random.uniform(60, 120)
        order_start = current_time
        order_end = order_start + timedelta(seconds=order_duration_s)

        if order_end > end_time:
            order_end = end_time

        order_id = f"ORD-HIST-{line_name.upper()}-{order_num:04d}"
        product = random.choice(products)

        orders.append({
            "timestamp": order_end,  # Use end time as the record timestamp
            "asset_id": line_asset_id,
            "order_id": order_id,
            "customer": "",
            "part_number": product,
            "part_description": f"Historical order for {line_name}",
            "quantity": order_qty + order_scrap,  # Planned = good + scrap
            "quantity_completed": order_qty,
            "quantity_scrap": order_scrap,
            "priority": random.randint(1, 100),
            "status": "COMPLETED",
            "due_date": order_end + timedelta(hours=random.randint(1, 24)),
            "started_at": order_start,
            "completed_at": order_end,
        })

        remaining_good -= order_qty
        remaining_scrap -= order_scrap
        current_time = order_end + timedelta(seconds=random.randint(60, 300))  # Gap between orders
        order_num += 1

    return orders


def insert_production_orders(conn, orders: List[Dict], batch_size: int = 100) -> int:
    """Insert production orders into the production_orders table."""
    if not orders:
        return 0

    cursor = conn.cursor()
    inserted = 0
    total = len(orders)

    for i in range(0, total, batch_size):
        batch = orders[i:i + batch_size]
        values = [
            (
                o["timestamp"], o["asset_id"], o["order_id"], o["customer"],
                o["part_number"], o["part_description"], o["quantity"],
                o["quantity_completed"], o["quantity_scrap"], o["priority"],
                o["status"], o["due_date"], o["started_at"], o["completed_at"]
            )
            for o in batch
        ]
        execute_values(
            cursor,
            """
            INSERT INTO production_orders
                (timestamp, asset_id, order_id, customer, part_number, part_description,
                 quantity, quantity_completed, quantity_scrap, priority, status,
                 due_date, started_at, completed_at)
            VALUES %s
            ON CONFLICT (asset_id, order_id) DO UPDATE SET
                quantity_completed = EXCLUDED.quantity_completed,
                quantity_scrap = EXCLUDED.quantity_scrap,
                status = EXCLUDED.status,
                started_at = EXCLUDED.started_at,
                completed_at = EXCLUDED.completed_at
            """,
            values,
        )
        inserted += cursor.rowcount
        done = min(i + batch_size, total)
        print(f"      Inserting orders ... {done}/{total}", end="\r", flush=True)

    print(f"      Inserting orders ... {total}/{total} done    ")
    conn.commit()
    cursor.close()
    return inserted


def get_line_asset_id(conn, enterprise: str, site: str, area: str, line: str) -> Optional[int]:
    """Get or create asset_id for a production line (for orders)."""
    cursor = conn.cursor()
    # First try to find existing line asset
    cursor.execute(
        """SELECT id FROM asset
           WHERE enterprise=%s AND site=%s AND area=%s AND line=%s AND workcell=''
           LIMIT 1""",
        (enterprise, site, area, line),
    )
    row = cursor.fetchone()
    if row:
        cursor.close()
        return row[0]

    # Create line asset if it doesn't exist
    cursor.execute(
        """INSERT INTO asset (enterprise, site, area, line, workcell, origin_id)
           VALUES (%s, %s, %s, %s, '', '')
           ON CONFLICT DO NOTHING
           RETURNING id""",
        (enterprise, site, area, line),
    )
    row = cursor.fetchone()
    conn.commit()
    cursor.close()
    return row[0] if row else None


def cleanup_historical_data(conn):
    """Delete all previously generated historical data to prevent interleaved counter streams."""
    cursor = conn.cursor()

    print("  Cleaning up old historical data...")

    tag_deleted = 0
    tag_string_deleted = 0
    stops_deleted = 0
    orders_deleted = 0

    try:
        cursor.execute("DELETE FROM tag WHERE origin = 'historical-data-generator'")
        tag_deleted = cursor.rowcount
    except psycopg2.errors.UndefinedTable:
        conn.rollback()  # Reset transaction after error

    try:
        cursor.execute("DELETE FROM tag_string WHERE origin = 'historical-data-generator'")
        tag_string_deleted = cursor.rowcount
    except psycopg2.errors.UndefinedTable:
        conn.rollback()

    try:
        cursor.execute("DELETE FROM machine_stops")
        stops_deleted = cursor.rowcount
    except psycopg2.errors.UndefinedTable:
        conn.rollback()

    try:
        cursor.execute("DELETE FROM production_orders WHERE order_id LIKE 'ORD-HIST-%'")
        orders_deleted = cursor.rowcount
    except psycopg2.errors.UndefinedTable:
        conn.rollback()

    conn.commit()
    cursor.close()

    if tag_deleted or tag_string_deleted or stops_deleted or orders_deleted:
        print(f"    Deleted {tag_deleted} tag rows, {tag_string_deleted} tag_string rows, {stops_deleted} stops, {orders_deleted} orders")
    else:
        print("    No existing data to clean up (fresh database)")
    print()


def main():
    args = parse_args()

    # Cap days at 7
    if args.days > 7:
        print(f"  Warning: Capping historical data to 7 days (requested {args.days})")
        args.days = 7

    # Determine time range
    end_time = datetime.now()
    if args.since:
        try:
            start_time = datetime.strptime(args.since, "%Y-%m-%d")
        except ValueError:
            print(f"Error: Invalid date format '{args.since}'. Use YYYY-MM-DD.")
            sys.exit(1)
    else:
        start_time = end_time - timedelta(days=args.days)

    # Determine workcells to generate
    # Each entry: {machine_type, workcell_name, line_name, area, enterprise, site}
    workcell_list = []

    if args.factory_setup:
        enterprise, site, workcells = parse_factory_setup(args.factory_setup)
        for wc in workcells:
            wc["enterprise"] = enterprise
            wc["site"] = site
        workcell_list = workcells
        print(f"  Loaded factory setup: {enterprise}/{site} with {len(workcell_list)} workcells")
    elif args.machines:
        # Fallback: use --machines with machine type as workcell name
        machine_types = args.machines
        if "all" in machine_types:
            machine_types = list(MACHINE_CONFIGS.keys())
        else:
            machine_types = [m for m in machine_types if m in MACHINE_CONFIGS]

        if not machine_types:
            print(f"Error: No valid machines specified. Available: {list(MACHINE_CONFIGS.keys())}")
            sys.exit(1)

        for mt in machine_types:
            workcell_list.append({
                "machine_type": mt,
                "workcell_name": mt,
                "line_name": "",
                "area": "",
                "enterprise": "",
                "site": "",
            })
    else:
        print("Error: Provide either --factory-setup or --machines")
        sys.exit(1)

    print(f"  Generating historical data:")
    print(f"    Time range: {start_time.strftime('%Y-%m-%d %H:%M')} to {end_time.strftime('%Y-%m-%d %H:%M')}")
    print(f"    Workcells:  {len(workcell_list)}")
    print(f"    Skip weekends: {args.skip_weekends}")
    print()

    if args.dry_run:
        print("  DRY RUN - No data will be inserted")
        print()

    # Connect to database
    conn = None
    if not args.dry_run:
        try:
            conn = psycopg2.connect(
                host=args.host,
                port=args.port,
                dbname=args.db,
                user=args.user,
                password=args.password,
            )
            print(f"  Connected to database {args.db}@{args.host}:{args.port}")
        except psycopg2.Error as e:
            print(f"  Error connecting to database: {e}")
            sys.exit(1)

        # Clean up any data from previous runs to prevent interleaved counter streams
        cleanup_historical_data(conn)

    total_tags = 0
    total_tag_strings = 0
    total_stops = 0
    total_orders = 0
    skipped = 0
    wc_total = len(workcell_list)
    overall_start = time.time()

    # Track production per line for order generation
    # Key: line_name, Value: {good_parts, scrap_parts, enterprise, site, area}
    line_production = {}

    for wc_idx, wc in enumerate(workcell_list, start=1):
        machine_type = wc["machine_type"]
        workcell_name = wc["workcell_name"]

        if machine_type not in MACHINE_CONFIGS:
            print(f"  [{wc_idx}/{wc_total}] Warning: Unknown machine type '{machine_type}', skipping {workcell_name}")
            skipped += 1
            continue

        config = MACHINE_CONFIGS[machine_type]

        # Look up asset_id from DB
        asset_id = None
        if conn:
            if wc.get("enterprise"):
                asset_id = get_asset_id(
                    conn,
                    wc["enterprise"], wc["site"], wc["area"],
                    wc["line_name"], workcell_name,
                )
            else:
                asset_id = get_asset_id_by_workcell(conn, workcell_name)

            if asset_id is None:
                print(f"  [{wc_idx}/{wc_total}] Warning: Asset not found for '{workcell_name}', skipping (umh-core may not have created it yet)")
                skipped += 1
                continue

        wc_start = time.time()
        print(f"  [{wc_idx}/{wc_total}] {workcell_name} (type: {machine_type}, asset_id: {asset_id})")

        data = generate_machine_data(
            machine_type,
            config,
            start_time,
            end_time,
            args.skip_weekends,
        )

        n_tags = len(data["tag_records"])
        n_strings = len(data["tag_string_records"])
        n_stops = len(data["stops"])
        gen_elapsed = time.time() - wc_start
        print(f"    Generated {n_tags} tag rows, {n_strings} state rows, {n_stops} stops in {gen_elapsed:.1f}s")
        print(f"    Production: {data['good_parts']} good + {data['scrap_parts']} scrap = {data['good_parts'] + data['scrap_parts']} total parts")

        # Track production by line (use the last machine's output as line output)
        line_name = wc.get("line_name", "")
        if line_name and line_name not in line_production:
            line_production[line_name] = {
                "good_parts": 0,
                "scrap_parts": 0,
                "enterprise": wc.get("enterprise", ""),
                "site": wc.get("site", ""),
                "area": wc.get("area", "shopfloor"),
            }
        if line_name:
            # Use max parts (last machine in line produces the output)
            line_production[line_name]["good_parts"] = max(
                line_production[line_name]["good_parts"], data["good_parts"]
            )
            line_production[line_name]["scrap_parts"] = max(
                line_production[line_name]["scrap_parts"], data["scrap_parts"]
            )

        if not args.dry_run and conn and asset_id is not None:
            insert_start = time.time()
            ins_tags = insert_tag_values(conn, asset_id, data["tag_records"], args.batch_size)
            ins_strings = insert_tag_string_values(conn, asset_id, data["tag_string_records"], args.batch_size)
            ins_stops = insert_stops(conn, asset_id, data["stops"], args.batch_size)
            total_tags += ins_tags
            total_tag_strings += ins_strings
            total_stops += ins_stops
            ins_elapsed = time.time() - insert_start
            print(f"    Inserted {ins_tags} tags, {ins_strings} states, {ins_stops} stops in {ins_elapsed:.1f}s")

    # Generate production orders per line
    if not args.dry_run and conn and line_production:
        print()
        print("  Generating production orders per line...")
        for line_name, line_data in line_production.items():
            if line_data["good_parts"] <= 0:
                continue

            # Get or create asset for the line
            line_asset_id = get_line_asset_id(
                conn,
                line_data["enterprise"],
                line_data["site"],
                line_data["area"],
                line_name,
            )
            if line_asset_id is None:
                print(f"    Warning: Could not create asset for line '{line_name}'")
                continue

            orders = generate_production_orders(
                line_name,
                line_asset_id,
                line_data["good_parts"],
                line_data["scrap_parts"],
                start_time,
                end_time,
            )
            if orders:
                ins_orders = insert_production_orders(conn, orders, args.batch_size)
                total_orders += ins_orders
                print(f"    {line_name}: {len(orders)} orders ({line_data['good_parts']} good parts)")

    # Summary
    total_elapsed = time.time() - overall_start
    print()
    print("  " + "=" * 50)
    print("  SUMMARY")
    print("  " + "=" * 50)
    print(f"  Workcells processed: {wc_total - skipped}/{wc_total}")
    if skipped > 0:
        print(f"  Workcells skipped:   {skipped}")
    if not args.dry_run:
        print(f"  Tags inserted:       {total_tags}")
        print(f"  State records:       {total_tag_strings}")
        print(f"  Stops inserted:      {total_stops}")
        print(f"  Orders inserted:     {total_orders}")
    print(f"  Total time:          {total_elapsed:.1f}s")

    # Show verification info
    if conn:
        try:
            cursor = conn.cursor()
            cursor.execute("SELECT count(*) FROM tag WHERE origin = 'historical-data-generator'")
            tag_count = cursor.fetchone()[0]
            cursor.execute("SELECT count(*) FROM tag_string WHERE origin = 'historical-data-generator'")
            tag_string_count = cursor.fetchone()[0]
            cursor.execute("SELECT min(timestamp), max(timestamp) FROM tag WHERE origin = 'historical-data-generator'")
            row = cursor.fetchone()
            cursor.close()
            print()
            print("  Verification:")
            print(f"    Total tag rows in DB:        {tag_count}")
            print(f"    Total tag_string rows in DB: {tag_string_count}")
            if row[0]:
                print(f"    Data range: {row[0].strftime('%Y-%m-%d %H:%M')} to {row[1].strftime('%Y-%m-%d %H:%M')}")
        except Exception:
            pass  # Don't fail on verification queries

        conn.close()

    print()
    print("  Historical data generation complete!")


if __name__ == "__main__":
    main()
