#!/usr/bin/env python3
"""
Historical Data Generator for UMH Demo (v2)

Config-driven generator that reads machine and line definitions from YAML files
and simulates production lines as coordinated units with inter-stage buffers.

Changes from v1:
- Correct tag names from machine YAML definitions (snake_case, not CamelCase)
- All 27 machine types supported (dynamically loaded from machines/*.yaml)
- Line-level simulation with buffer blocking/starvation between stages
- Shift table population (fixes NULL from get_planned_minutes/get_runtime_minutes)
- Recipe-driven production orders from line config YAML files
- Per-stage cycle_time_ms, scrap_rate, breakdown_probability from line configs
- Event-driven simulation for performance

Usage:
    ./generate-historical-data.py --days 7 --factory-setup /path/to/factory-setup.yaml --host pgbouncer
    ./generate-historical-data.py --days 3 --machines metal-forming cnc-router --host localhost
"""

import argparse
import math
import os
import random
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, List, Optional, Tuple

try:
    import psycopg2
    from psycopg2.extras import execute_values
except ImportError:
    print("Error: psycopg2 is required. Install with: pip install psycopg2-binary")
    sys.exit(1)

try:
    import yaml
except ImportError:
    print("Error: PyYAML is required. Install with: pip install pyyaml")
    sys.exit(1)


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

STATE_INT = {
    "IDLE": 0,
    "RUNNING": 2,
    "STOPPED": 3,       # PlannedStop
    "FAULT": 4,          # UnplannedStop
    "MAINTENANCE": 3,    # PlannedStop (same as STOPPED in dashboards)
}

COMMON_TAGS = {"state", "cycle_count", "good_count", "scrap_count", "cycle_time_ms", "blocked_by_buffer"}

SHIFT_START_HOUR = 6
SHIFT_END_HOUR = 22

# Stop reasons for STOPPED state (weighted random)
STOP_REASONS_PLANNED = [2, 3, 4, 6, 7]
STOP_REASON_WEIGHTS = [0.15, 0.20, 0.25, 0.08, 0.12]

# Suffix-based fallback ranges for tags not in TAG_PARAMS
SUFFIX_DEFAULTS = {
    "_c":    (20.0,  0.3,  10.0,   300.0),
    "_bar":  (5.0,   0.2,  0.0,    400.0),
    "_rpm":  (1000,  5.0,  0.0,    5000.0),
    "_pct":  (50.0,  0.5,  0.0,    100.0),
    "_mm":   (10.0,  0.1,  0.0,    500.0),
    "_um":   (10.0,  0.5,  0.0,    500.0),
    "_kn":   (50.0,  1.0,  0.0,    5000.0),
    "_n":    (100.0, 2.0,  0.0,    10000.0),
    "_kw":   (5.0,   0.1,  0.0,    50.0),
    "_w":    (1000,  10.0, 0.0,    10000.0),
    "_a":    (20.0,  0.5,  0.0,    500.0),
    "_v":    (24.0,  0.3,  0.0,    400.0),
    "_ka":   (10.0,  0.2,  0.0,    50.0),
    "_ml":   (100,   1.0,  0.0,    5000.0),
    "_l":    (100,   1.0,  0.0,    5000.0),
    "_g":    (50.0,  0.3,  0.0,    1000.0),
    "_kg":   (5.0,   0.1,  0.0,    200.0),
    "_mg":   (1000,  1.0,  0.0,    10000.0),
    "_s":    (10.0,  0.1,  0.0,    300.0),
    "_ms":   (200,   5.0,  0.0,    10000.0),
    "_deg":  (45.0,  0.5,  -180.0, 180.0),
    "_db":   (85.0,  0.5,  60.0,   120.0),
    "_kpa":  (-50.0, 0.5,  -100.0, 100.0),
    "_pa":   (30.0,  0.5,  0.0,    200.0),
    "_mbar": (5.0,   0.2,  0.0,    100.0),
    "_lux":  (10000, 50.0, 0.0,    50000.0),
    "_ppm":  (500,   5.0,  0.0,    5000.0),
}


# ---------------------------------------------------------------------------
# Data classes
# ---------------------------------------------------------------------------

@dataclass
class TagSpec:
    initial: float
    delta: float
    min_val: float
    max_val: float


@dataclass
class StageConfig:
    stage: int
    machine_type: str
    cycle_time_ms: int
    scrap_rate: float
    breakdown_probability: float
    auto_restore_time_ms: int


@dataclass
class RecipeConfig:
    product_id: str
    description: str
    planned_qty_range: Tuple[int, int]
    overrides: Dict[int, Dict]


@dataclass
class LineConfig:
    name: str
    stages: List[StageConfig]
    buffer_capacity: int
    recipes: List[RecipeConfig]


# ---------------------------------------------------------------------------
# TAG_PARAMS — extracted from Go simulator source files
# (machine-simulator-2/internal/machine/types/*.go)
# ---------------------------------------------------------------------------

TAG_PARAMS = {
    "injection-molding": {
        "barrel_zone1_temp_c":    TagSpec(initial=180.0,  delta=0.3,   min_val=160.0,  max_val=200.0),
        "barrel_zone2_temp_c":    TagSpec(initial=200.0,  delta=0.3,   min_val=180.0,  max_val=220.0),
        "barrel_zone3_temp_c":    TagSpec(initial=215.0,  delta=0.3,   min_val=200.0,  max_val=240.0),
        "barrel_zone4_temp_c":    TagSpec(initial=225.0,  delta=0.3,   min_val=210.0,  max_val=250.0),
        "injection_pressure_bar": TagSpec(initial=1200.0, delta=10.0,  min_val=500.0,  max_val=2000.0),
        "mold_temp_c":            TagSpec(initial=45.0,   delta=0.2,   min_val=20.0,   max_val=80.0),
        "clamp_force_tons":       TagSpec(initial=200.0,  delta=2.0,   min_val=50.0,   max_val=500.0),
        "cooling_time_s":         TagSpec(initial=12.0,   delta=0.1,   min_val=5.0,    max_val=30.0),
        "shot_weight_g":          TagSpec(initial=85.0,   delta=0.3,   min_val=20.0,   max_val=200.0),
        "cushion_mm":             TagSpec(initial=5.0,    delta=0.1,   min_val=2.0,    max_val=12.0),
        "screw_speed_rpm":        TagSpec(initial=100.0,  delta=1.0,   min_val=30.0,   max_val=200.0),
        "back_pressure_bar":      TagSpec(initial=30.0,   delta=0.5,   min_val=10.0,   max_val=80.0),
        "melt_temp_c":            TagSpec(initial=230.0,  delta=0.3,   min_val=200.0,  max_val=280.0),
        "pack_pressure_bar":      TagSpec(initial=800.0,  delta=5.0,   min_val=300.0,  max_val=1500.0),
        "fill_time_s":            TagSpec(initial=1.5,    delta=0.02,  min_val=0.5,    max_val=5.0),
    },
    "metal-forming": {
        "press_force_kn":         TagSpec(initial=2500.0, delta=10.0,  min_val=2000.0, max_val=3000.0),
        "hydraulic_pressure_bar": TagSpec(initial=250.0,  delta=2.0,   min_val=200.0,  max_val=300.0),
        "die_temperature_c":      TagSpec(initial=45.0,   delta=0.5,   min_val=30.0,   max_val=80.0),
        "stroke_position_mm":     TagSpec(initial=0.0,    delta=5.0,   min_val=0.0,    max_val=300.0),
        "tool_wear_pct":          TagSpec(initial=5.0,    delta=0.001, min_val=0.0,    max_val=100.0),
        "ram_speed_mm_s":         TagSpec(initial=120.0,  delta=1.0,   min_val=80.0,   max_val=160.0),
        "blank_holder_force_kn":  TagSpec(initial=400.0,  delta=5.0,   min_val=300.0,  max_val=500.0),
        "material_thickness_mm":  TagSpec(initial=1.2,    delta=0.01,  min_val=0.8,    max_val=2.0),
        "tonnage_pct":            TagSpec(initial=72.0,   delta=1.0,   min_val=50.0,   max_val=95.0),
        "lubrication_level_pct":  TagSpec(initial=85.0,   delta=0.01,  min_val=20.0,   max_val=100.0),
        "vibration_mm_s":         TagSpec(initial=2.5,    delta=0.2,   min_val=0.5,    max_val=10.0),
        "noise_level_db":         TagSpec(initial=92.0,   delta=0.5,   min_val=80.0,   max_val=105.0),
        "motor_current_a":        TagSpec(initial=180.0,  delta=2.0,   min_val=120.0,  max_val=250.0),
        "hydraulic_oil_temp_c":   TagSpec(initial=42.0,   delta=0.3,   min_val=30.0,   max_val=65.0),
        "cycle_energy_kwh":       TagSpec(initial=3.8,    delta=0.1,   min_val=2.0,    max_val=6.0),
    },
    "cnc-router": {
        "spindle_speed_rpm":              TagSpec(initial=18000.0, delta=50.0,  min_val=6000.0,  max_val=24000.0),
        "x_position_mm":                  TagSpec(initial=500.0,   delta=20.0,  min_val=0.0,     max_val=2500.0),
        "y_position_mm":                  TagSpec(initial=300.0,   delta=15.0,  min_val=0.0,     max_val=1250.0),
        "z_position_mm":                  TagSpec(initial=-5.0,    delta=1.0,   min_val=-50.0,   max_val=10.0),
        "cut_depth_mm":                   TagSpec(initial=6.0,     delta=0.1,   min_val=1.0,     max_val=25.0),
        "feed_rate_mm_min":               TagSpec(initial=8000.0,  delta=50.0,  min_val=2000.0,  max_val=15000.0),
        "dust_extraction_m3_h":           TagSpec(initial=2000.0,  delta=20.0,  min_val=1000.0,  max_val=4000.0),
        "tool_wear_pct":                  TagSpec(initial=10.0,    delta=0.002, min_val=0.0,     max_val=100.0),
        "power_consumption_kw":           TagSpec(initial=7.5,     delta=0.2,   min_val=3.0,     max_val=15.0),
        "vibration_mm_s":                 TagSpec(initial=1.2,     delta=0.1,   min_val=0.3,     max_val=5.0),
        "vacuum_hold_down_kpa":           TagSpec(initial=-70.0,   delta=0.5,   min_val=-90.0,   max_val=-40.0),
        "surface_finish_um":              TagSpec(initial=5.0,     delta=0.2,   min_val=1.0,     max_val=15.0),
        "tool_temp_c":                    TagSpec(initial=55.0,    delta=0.5,   min_val=25.0,    max_val=90.0),
        "coolant_flow_l_min":             TagSpec(initial=0.0,     delta=0.1,   min_val=0.0,     max_val=5.0),
        "material_removal_rate_cm3_min":  TagSpec(initial=150.0,   delta=5.0,   min_val=50.0,    max_val=400.0),
    },
    "spot-welder": {
        "weld_current_ka":       TagSpec(initial=10.5,   delta=0.2,   min_val=8.0,    max_val=14.0),
        "electrode_force_kn":    TagSpec(initial=3.2,    delta=0.1,   min_val=2.0,    max_val=5.0),
        "weld_time_ms":          TagSpec(initial=200.0,  delta=5.0,   min_val=100.0,  max_val=400.0),
        "nugget_diameter_mm":    TagSpec(initial=5.5,    delta=0.1,   min_val=4.0,    max_val=7.0),
        "tip_wear_pct":          TagSpec(initial=3.0,    delta=0.005, min_val=0.0,    max_val=100.0),
        "squeeze_time_ms":       TagSpec(initial=100.0,  delta=2.0,   min_val=50.0,   max_val=200.0),
        "hold_time_ms":          TagSpec(initial=150.0,  delta=2.0,   min_val=80.0,   max_val=300.0),
        "electrode_temp_c":      TagSpec(initial=85.0,   delta=1.0,   min_val=40.0,   max_val=200.0),
        "water_flow_l_min":      TagSpec(initial=6.0,    delta=0.1,   min_val=3.0,    max_val=10.0),
        "resistance_mohm":       TagSpec(initial=120.0,  delta=2.0,   min_val=50.0,   max_val=250.0),
        "expulsion_count":       TagSpec(initial=0.0,    delta=0.0,   min_val=0.0,    max_val=0.0),
        "weld_power_kw":         TagSpec(initial=45.0,   delta=1.0,   min_val=20.0,   max_val=80.0),
        "cap_displacement_mm":   TagSpec(initial=0.3,    delta=0.02,  min_val=0.1,    max_val=0.8),
        "shunt_factor":          TagSpec(initial=0.92,   delta=0.005, min_val=0.80,   max_val=1.0),
        "sheet_gap_mm":          TagSpec(initial=0.05,   delta=0.01,  min_val=0.0,    max_val=0.5),
    },
    "filling-machine": {
        "fill_volume_ml":        TagSpec(initial=500.0,  delta=1.0,   min_val=450.0,  max_val=550.0),
        "fill_rate_ml_s":        TagSpec(initial=120.0,  delta=2.0,   min_val=80.0,   max_val=200.0),
        "nozzle_pressure_bar":   TagSpec(initial=2.5,    delta=0.05,  min_val=1.5,    max_val=4.0),
        "product_temp_c":        TagSpec(initial=4.0,    delta=0.1,   min_val=1.0,    max_val=10.0),
        "tank_level_pct":        TagSpec(initial=85.0,   delta=0.05,  min_val=10.0,   max_val=100.0),
        "flow_rate_l_min":       TagSpec(initial=7.2,    delta=0.1,   min_val=3.0,    max_val=15.0),
        "fill_accuracy_pct":     TagSpec(initial=99.5,   delta=0.05,  min_val=97.0,   max_val=100.0),
        "drip_count":            TagSpec(initial=0.0,    delta=0.0,   min_val=0.0,    max_val=0.0),
        "valve_cycle_count":     TagSpec(initial=0.0,    delta=0.0,   min_val=0.0,    max_val=0.0),
        "cip_status":            TagSpec(initial=0.0,    delta=0.0,   min_val=0.0,    max_val=0.0),
        "product_viscosity_cp":  TagSpec(initial=3.0,    delta=0.05,  min_val=1.0,    max_val=10.0),
        "line_pressure_bar":     TagSpec(initial=3.0,    delta=0.05,  min_val=1.5,    max_val=5.0),
        "fill_weight_g":         TagSpec(initial=505.0,  delta=1.0,   min_val=450.0,  max_val=560.0),
        "density_kg_m3":         TagSpec(initial=1010.0, delta=0.5,   min_val=990.0,  max_val=1050.0),
        "foam_level_pct":        TagSpec(initial=5.0,    delta=0.3,   min_val=0.0,    max_val=20.0),
    },
    "robot-welder": {
        "joint1_temp_c":              TagSpec(initial=42.0,  delta=0.3,   min_val=25.0,   max_val=70.0),
        "joint2_temp_c":              TagSpec(initial=44.0,  delta=0.3,   min_val=25.0,   max_val=70.0),
        "joint3_temp_c":              TagSpec(initial=40.0,  delta=0.3,   min_val=25.0,   max_val=70.0),
        "joint4_temp_c":              TagSpec(initial=38.0,  delta=0.3,   min_val=25.0,   max_val=70.0),
        "joint5_temp_c":              TagSpec(initial=39.0,  delta=0.3,   min_val=25.0,   max_val=70.0),
        "joint6_temp_c":              TagSpec(initial=37.0,  delta=0.3,   min_val=25.0,   max_val=70.0),
        "arc_voltage_v":              TagSpec(initial=24.0,  delta=0.3,   min_val=18.0,   max_val=32.0),
        "arc_current_a":              TagSpec(initial=220.0, delta=3.0,   min_val=150.0,  max_val=350.0),
        "wire_feed_m_min":            TagSpec(initial=8.5,   delta=0.2,   min_val=4.0,    max_val=15.0),
        "gas_flow_l_min":             TagSpec(initial=15.0,  delta=0.3,   min_val=10.0,   max_val=25.0),
        "travel_speed_mm_s":          TagSpec(initial=12.0,  delta=0.5,   min_val=5.0,    max_val=25.0),
        "weld_penetration_mm":        TagSpec(initial=3.2,   delta=0.1,   min_val=1.5,    max_val=6.0),
        "torch_angle_deg":            TagSpec(initial=15.0,  delta=0.5,   min_val=5.0,    max_val=45.0),
        "seam_tracking_offset_mm":    TagSpec(initial=0.1,   delta=0.05,  min_val=-1.0,   max_val=1.0),
        "spatter_count":              TagSpec(initial=0.0,   delta=0.0,   min_val=0.0,    max_val=0.0),
    },
    "edge-bander": {
        "glue_temp_c":              TagSpec(initial=200.0,  delta=1.0,    min_val=170.0,  max_val=230.0),
        "feed_speed_m_min":         TagSpec(initial=12.0,   delta=0.2,    min_val=5.0,    max_val=25.0),
        "trimmer_position_mm":      TagSpec(initial=0.5,    delta=0.01,   min_val=0.1,    max_val=1.5),
        "tape_tension_n":           TagSpec(initial=20.0,   delta=0.5,    min_val=8.0,    max_val=40.0),
        "roller_force_n":           TagSpec(initial=250.0,  delta=3.0,    min_val=100.0,  max_val=500.0),
        "edge_thickness_mm":        TagSpec(initial=0.8,    delta=0.01,   min_val=0.4,    max_val=3.0),
        "glue_flow_g_min":          TagSpec(initial=25.0,   delta=0.5,    min_val=10.0,   max_val=50.0),
        "panel_thickness_mm":       TagSpec(initial=18.0,   delta=0.05,   min_val=8.0,    max_val=40.0),
        "trim_quality_score_pct":   TagSpec(initial=95.0,   delta=0.3,    min_val=75.0,   max_val=100.0),
        "pressure_zone_bar":        TagSpec(initial=3.5,    delta=0.1,    min_val=1.5,    max_val=6.0),
        "pre_milling_depth_mm":     TagSpec(initial=0.2,    delta=0.005,  min_val=0.05,   max_val=0.5),
        "hot_air_temp_c":           TagSpec(initial=350.0,  delta=2.0,    min_val=280.0,  max_val=450.0),
        "joint_strength_n_cm":      TagSpec(initial=120.0,  delta=2.0,    min_val=60.0,   max_val=200.0),
        "scraper_position_mm":      TagSpec(initial=0.1,    delta=0.005,  min_val=0.0,    max_val=0.5),
        "buffing_speed_rpm":        TagSpec(initial=3000.0, delta=20.0,   min_val=1500.0, max_val=5000.0),
    },
    "sealing-machine": {
        "seal_temp_c":             TagSpec(initial=180.0,  delta=0.5,    min_val=140.0,  max_val=220.0),
        "seal_pressure_bar":       TagSpec(initial=3.5,    delta=0.1,    min_val=2.0,    max_val=6.0),
        "seal_time_ms":            TagSpec(initial=500.0,  delta=5.0,    min_val=200.0,  max_val=1000.0),
        "conveyor_speed_m_min":    TagSpec(initial=12.0,   delta=0.2,    min_val=5.0,    max_val=25.0),
        "jaw_gap_mm":              TagSpec(initial=0.5,    delta=0.02,   min_val=0.1,    max_val=2.0),
        "seal_strength_n":         TagSpec(initial=25.0,   delta=0.5,    min_val=10.0,   max_val=50.0),
        "peel_force_n":            TagSpec(initial=8.0,    delta=0.2,    min_val=3.0,    max_val=20.0),
        "seal_width_mm":           TagSpec(initial=10.0,   delta=0.05,   min_val=5.0,    max_val=20.0),
        "cooling_water_temp_c":    TagSpec(initial=18.0,   delta=0.1,    min_val=10.0,   max_val=25.0),
        "film_tension_n":          TagSpec(initial=15.0,   delta=0.3,    min_val=5.0,    max_val=30.0),
        "reject_count":            TagSpec(initial=0.0,    delta=0.0,    min_val=0.0,    max_val=0.0),
        "vacuum_level_mbar":       TagSpec(initial=5.0,    delta=0.2,    min_val=1.0,    max_val=20.0),
        "gas_flush_flow_l_min":    TagSpec(initial=2.0,    delta=0.05,   min_val=0.5,    max_val=5.0),
        "leak_rate_mbar_l_s":      TagSpec(initial=0.01,   delta=0.001,  min_val=0.001,  max_val=0.1),
        "heater_power_pct":        TagSpec(initial=75.0,   delta=0.5,    min_val=40.0,   max_val=100.0),
    },
    "robot-pick-place": {
        "joint1_angle":          TagSpec(initial=0.0,     delta=2.0,   min_val=-180.0,  max_val=180.0),
        "joint2_angle":          TagSpec(initial=-30.0,   delta=1.5,   min_val=-90.0,   max_val=90.0),
        "joint3_angle":          TagSpec(initial=60.0,    delta=2.0,   min_val=-120.0,  max_val=120.0),
        "joint4_angle":          TagSpec(initial=0.0,     delta=2.0,   min_val=-180.0,  max_val=180.0),
        "joint5_angle":          TagSpec(initial=-45.0,   delta=1.5,   min_val=-120.0,  max_val=120.0),
        "joint6_angle":          TagSpec(initial=0.0,     delta=2.0,   min_val=-360.0,  max_val=360.0),
        "tcp_x":                 TagSpec(initial=500.0,   delta=5.0,   min_val=-1000.0, max_val=1000.0),
        "tcp_y":                 TagSpec(initial=0.0,     delta=5.0,   min_val=-1000.0, max_val=1000.0),
        "tcp_z":                 TagSpec(initial=300.0,   delta=3.0,   min_val=0.0,     max_val=800.0),
        "gripper_force_n":       TagSpec(initial=50.0,    delta=1.0,   min_val=10.0,    max_val=150.0),
        "vacuum_pressure_kpa":   TagSpec(initial=-60.0,   delta=1.0,   min_val=-85.0,   max_val=-20.0),
        "pick_accuracy_um":      TagSpec(initial=25.0,    delta=1.0,   min_val=5.0,     max_val=100.0),
        "place_accuracy_um":     TagSpec(initial=30.0,    delta=1.0,   min_val=5.0,     max_val=100.0),
        "cycle_speed_pct":       TagSpec(initial=85.0,    delta=0.5,   min_val=50.0,    max_val=100.0),
        "payload_kg":            TagSpec(initial=2.5,     delta=0.1,   min_val=0.5,     max_val=10.0),
        "acceleration_m_s2":     TagSpec(initial=8.0,     delta=0.2,   min_val=3.0,     max_val=15.0),
    },
    "assembly-press": {
        "press_force_kn":          TagSpec(initial=15.0,   delta=0.3,    min_val=5.0,    max_val=50.0),
        "alignment_accuracy_mm":   TagSpec(initial=0.1,    delta=0.005,  min_val=0.02,   max_val=0.5),
        "dwell_time_ms":           TagSpec(initial=500.0,  delta=5.0,    min_val=200.0,  max_val=2000.0),
        "cycle_pressure_bar":      TagSpec(initial=6.0,    delta=0.1,    min_val=3.0,    max_val=10.0),
        "ram_position_mm":         TagSpec(initial=0.0,    delta=2.0,    min_val=-50.0,  max_val=50.0),
        "insertion_depth_mm":      TagSpec(initial=30.0,   delta=0.1,    min_val=10.0,   max_val=60.0),
        "parallelism_um":          TagSpec(initial=20.0,   delta=1.0,    min_val=5.0,    max_val=80.0),
        "stroke_speed_mm_s":       TagSpec(initial=80.0,   delta=1.0,    min_val=30.0,   max_val=150.0),
        "part_presence_pct":       TagSpec(initial=100.0,  delta=0.1,    min_val=90.0,   max_val=100.0),
        "force_curve_peak_kn":     TagSpec(initial=18.0,   delta=0.5,    min_val=5.0,    max_val=55.0),
        "work_energy_j":           TagSpec(initial=45.0,   delta=1.0,    min_val=10.0,   max_val=120.0),
        "temperature_c":           TagSpec(initial=28.0,   delta=0.2,    min_val=18.0,   max_val=45.0),
        "cushion_pressure_bar":    TagSpec(initial=2.0,    delta=0.05,   min_val=0.5,    max_val=5.0),
        "ejector_force_n":         TagSpec(initial=200.0,  delta=3.0,    min_val=50.0,   max_val=500.0),
        "servo_current_a":         TagSpec(initial=6.0,    delta=0.1,    min_val=2.0,    max_val=15.0),
    },
    "labeling-machine": {
        "label_position_accuracy_mm":  TagSpec(initial=0.3,    delta=0.02,   min_val=0.05,   max_val=1.0),
        "applicator_speed_labels_min": TagSpec(initial=200.0,  delta=2.0,    min_val=50.0,   max_val=400.0),
        "label_tension_n":             TagSpec(initial=8.0,    delta=0.2,    min_val=3.0,    max_val=15.0),
        "printer_dpi":                 TagSpec(initial=300.0,  delta=0.1,    min_val=200.0,  max_val=600.0),
        "print_speed_mm_s":            TagSpec(initial=150.0,  delta=1.0,    min_val=80.0,   max_val=300.0),
        "label_count":                 TagSpec(initial=0.0,    delta=0.0,    min_val=0.0,    max_val=0.0),
        "reject_count":                TagSpec(initial=0.0,    delta=0.0,    min_val=0.0,    max_val=0.0),
        "ribbon_remaining_pct":        TagSpec(initial=90.0,   delta=0.01,   min_val=0.0,    max_val=100.0),
        "label_remaining_pct":         TagSpec(initial=85.0,   delta=0.01,   min_val=0.0,    max_val=100.0),
        "sensor_signal_pct":           TagSpec(initial=95.0,   delta=0.2,    min_val=70.0,   max_val=100.0),
        "web_speed_m_min":             TagSpec(initial=25.0,   delta=0.3,    min_val=10.0,   max_val=50.0),
        "registration_error_mm":       TagSpec(initial=0.1,    delta=0.01,   min_val=0.0,    max_val=0.5),
        "adhesive_temp_c":             TagSpec(initial=35.0,   delta=0.2,    min_val=20.0,   max_val=50.0),
        "roller_pressure_n":           TagSpec(initial=40.0,   delta=0.5,    min_val=15.0,   max_val=80.0),
        "camera_verify_score_pct":     TagSpec(initial=98.0,   delta=0.2,    min_val=85.0,   max_val=100.0),
    },
    "painting-booth": {
        "booth_temp_c":                TagSpec(initial=22.0,    delta=0.2,    min_val=18.0,    max_val=28.0),
        "booth_humidity_pct":          TagSpec(initial=55.0,    delta=0.5,    min_val=40.0,    max_val=70.0),
        "paint_flow_ml_min":           TagSpec(initial=250.0,   delta=5.0,    min_val=100.0,   max_val=500.0),
        "atomization_pressure_bar":    TagSpec(initial=4.5,     delta=0.1,    min_val=2.0,     max_val=7.0),
        "film_thickness_um":           TagSpec(initial=35.0,    delta=1.0,    min_val=15.0,    max_val=60.0),
        "overspray_pct":               TagSpec(initial=25.0,    delta=0.5,    min_val=10.0,    max_val=45.0),
        "fan_speed_rpm":               TagSpec(initial=1800.0,  delta=10.0,   min_val=1200.0,  max_val=2400.0),
        "filter_pressure_drop_pa":     TagSpec(initial=120.0,   delta=0.2,    min_val=50.0,    max_val=500.0),
        "solvent_concentration_ppm":   TagSpec(initial=350.0,   delta=5.0,    min_val=100.0,   max_val=800.0),
        "cure_temp_c":                 TagSpec(initial=140.0,   delta=0.5,    min_val=120.0,   max_val=180.0),
        "conveyor_speed_m_min":        TagSpec(initial=3.5,     delta=0.05,   min_val=1.0,     max_val=6.0),
        "paint_viscosity_cp":          TagSpec(initial=85.0,    delta=1.0,    min_val=50.0,    max_val=150.0),
        "color_delta_e":               TagSpec(initial=0.5,     delta=0.05,   min_val=0.0,     max_val=3.0),
        "booth_airflow_m3_h":          TagSpec(initial=25000.0, delta=100.0,  min_val=15000.0, max_val=35000.0),
        "paint_waste_pct":             TagSpec(initial=8.0,     delta=0.2,    min_val=2.0,     max_val=20.0),
    },
    "laser-cutter": {
        "laser_power_w":             TagSpec(initial=4000.0,  delta=20.0,   min_val=500.0,   max_val=6000.0),
        "cutting_speed_mm_s":        TagSpec(initial=40.0,    delta=0.5,    min_val=5.0,     max_val=100.0),
        "assist_gas_pressure_bar":   TagSpec(initial=12.0,    delta=0.2,    min_val=2.0,     max_val=25.0),
        "focal_point_mm":            TagSpec(initial=0.0,     delta=0.02,   min_val=-3.0,    max_val=3.0),
        "kerf_width_mm":             TagSpec(initial=0.2,     delta=0.005,  min_val=0.1,     max_val=0.5),
        "beam_quality_mm_mrad":      TagSpec(initial=4.0,     delta=0.05,   min_val=2.0,     max_val=8.0),
        "nozzle_standoff_mm":        TagSpec(initial=1.0,     delta=0.02,   min_val=0.3,     max_val=3.0),
        "pierce_time_ms":            TagSpec(initial=200.0,   delta=5.0,    min_val=50.0,    max_val=2000.0),
        "sheet_temp_c":              TagSpec(initial=30.0,    delta=0.5,    min_val=20.0,    max_val=80.0),
        "exhaust_flow_m3_h":         TagSpec(initial=3000.0,  delta=30.0,   min_val=1500.0,  max_val=5000.0),
        "lens_condition_pct":        TagSpec(initial=95.0,    delta=0.001,  min_val=50.0,    max_val=100.0),
        "gas_consumption_l_min":     TagSpec(initial=20.0,    delta=0.3,    min_val=5.0,     max_val=50.0),
        "edge_roughness_um":         TagSpec(initial=12.0,    delta=0.3,    min_val=3.0,     max_val=30.0),
        "taper_angle_deg":           TagSpec(initial=0.5,     delta=0.02,   min_val=0.0,     max_val=2.0),
        "power_stability_pct":       TagSpec(initial=98.0,    delta=0.1,    min_val=90.0,    max_val=100.0),
    },
    "reactor-vessel": {
        "vessel_temp_c":             TagSpec(initial=37.0,    delta=0.1,    min_val=20.0,    max_val=80.0),
        "vessel_pressure_bar":       TagSpec(initial=1.2,     delta=0.02,   min_val=0.5,     max_val=5.0),
        "agitator_speed_rpm":        TagSpec(initial=120.0,   delta=1.0,    min_val=30.0,    max_val=300.0),
        "ph_level":                  TagSpec(initial=7.0,     delta=0.02,   min_val=4.0,     max_val=10.0),
        "batch_volume_l":            TagSpec(initial=500.0,   delta=0.5,    min_val=100.0,   max_val=1000.0),
        "dissolved_oxygen_ppm":      TagSpec(initial=6.0,     delta=0.1,    min_val=0.5,     max_val=12.0),
        "conductivity_us_cm":        TagSpec(initial=1200.0,  delta=5.0,    min_val=500.0,   max_val=3000.0),
        "turbidity_ntu":             TagSpec(initial=15.0,    delta=0.5,    min_val=1.0,     max_val=100.0),
        "jacket_temp_c":             TagSpec(initial=35.0,    delta=0.1,    min_val=15.0,    max_val=85.0),
        "feed_rate_ml_min":          TagSpec(initial=50.0,    delta=1.0,    min_val=5.0,     max_val=200.0),
        "off_gas_flow_l_min":        TagSpec(initial=5.0,     delta=0.2,    min_val=0.5,     max_val=20.0),
        "torque_nm":                 TagSpec(initial=25.0,    delta=0.5,    min_val=5.0,     max_val=80.0),
        "impeller_tip_speed_m_s":    TagSpec(initial=3.0,     delta=0.05,   min_val=1.0,     max_val=8.0),
        "redox_potential_mv":        TagSpec(initial=200.0,   delta=2.0,    min_val=-200.0,  max_val=500.0),
        "foam_level_pct":            TagSpec(initial=10.0,    delta=0.5,    min_val=0.0,     max_val=40.0),
    },
    "press-brake": {
        "ram_force_tons":            TagSpec(initial=100.0,  delta=2.0,    min_val=10.0,    max_val=300.0),
        "bend_angle_deg":            TagSpec(initial=90.0,   delta=0.1,    min_val=30.0,    max_val=175.0),
        "back_gauge_position_mm":    TagSpec(initial=50.0,   delta=0.5,    min_val=5.0,     max_val=500.0),
        "stroke_length_mm":          TagSpec(initial=120.0,  delta=0.5,    min_val=50.0,    max_val=300.0),
        "die_temp_c":                TagSpec(initial=30.0,   delta=0.2,    min_val=20.0,    max_val=60.0),
        "crowning_mm":               TagSpec(initial=0.05,   delta=0.005,  min_val=0.0,     max_val=0.3),
        "daylight_mm":               TagSpec(initial=400.0,  delta=1.0,    min_val=200.0,   max_val=600.0),
        "ram_speed_mm_s":            TagSpec(initial=10.0,   delta=0.2,    min_val=1.0,     max_val=25.0),
        "tonnage_pct":               TagSpec(initial=65.0,   delta=1.0,    min_val=20.0,    max_val=100.0),
        "material_springback_deg":   TagSpec(initial=2.0,    delta=0.05,   min_val=0.5,     max_val=5.0),
        "repeatability_mm":          TagSpec(initial=0.02,   delta=0.002,  min_val=0.005,   max_val=0.1),
        "hydraulic_pressure_bar":    TagSpec(initial=200.0,  delta=2.0,    min_val=100.0,   max_val=350.0),
        "beam_deflection_mm":        TagSpec(initial=0.1,    delta=0.005,  min_val=0.0,     max_val=0.5),
        "energy_consumption_kwh":    TagSpec(initial=1.5,    delta=0.05,   min_val=0.5,     max_val=5.0),
        "cycle_time_actual_s":       TagSpec(initial=8.0,    delta=0.1,    min_val=3.0,     max_val=20.0),
    },
    "smt-placement": {
        "placement_rate_cph":      TagSpec(initial=25000.0, delta=100.0,  min_val=15000.0, max_val=40000.0),
        "nozzle_vacuum_kpa":       TagSpec(initial=-55.0,   delta=0.5,    min_val=-80.0,   max_val=-30.0),
        "feeder_status_pct":       TagSpec(initial=98.0,    delta=0.2,    min_val=80.0,    max_val=100.0),
        "placement_accuracy_um":   TagSpec(initial=35.0,    delta=1.0,    min_val=10.0,    max_val=80.0),
        "head_x_mm":               TagSpec(initial=200.0,   delta=10.0,   min_val=0.0,     max_val=500.0),
        "head_y_mm":               TagSpec(initial=150.0,   delta=10.0,   min_val=0.0,     max_val=400.0),
        "vision_score_pct":        TagSpec(initial=96.0,    delta=0.3,    min_val=80.0,    max_val=100.0),
        "component_count":         TagSpec(initial=0.0,     delta=0.0,    min_val=0.0,     max_val=0.0),
        "reject_count":            TagSpec(initial=0.0,     delta=0.0,    min_val=0.0,     max_val=0.0),
        "nozzle_temp_c":           TagSpec(initial=28.0,    delta=0.2,    min_val=20.0,    max_val=45.0),
        "board_temp_c":            TagSpec(initial=25.0,    delta=0.1,    min_val=20.0,    max_val=40.0),
        "tape_tension_n":          TagSpec(initial=2.5,     delta=0.1,    min_val=1.0,     max_val=5.0),
        "conveyor_width_mm":       TagSpec(initial=250.0,   delta=0.1,    min_val=200.0,   max_val=350.0),
        "rotation_accuracy_deg":   TagSpec(initial=0.02,    delta=0.002,  min_val=0.005,   max_val=0.1),
        "pick_failure_count":      TagSpec(initial=0.0,     delta=0.0,    min_val=0.0,     max_val=0.0),
    },
    "pharma-filler": {
        "fill_volume_ml":                TagSpec(initial=2.0,     delta=0.005,  min_val=1.8,     max_val=2.2),
        "fill_accuracy_pct":             TagSpec(initial=99.8,    delta=0.02,   min_val=98.0,    max_val=100.0),
        "particulate_count":             TagSpec(initial=5.0,     delta=0.5,    min_val=0.0,     max_val=50.0),
        "clean_room_pressure_pa":        TagSpec(initial=30.0,    delta=0.5,    min_val=15.0,    max_val=60.0),
        "laminar_flow_velocity_m_s":     TagSpec(initial=0.45,    delta=0.005,  min_val=0.36,    max_val=0.54),
        "stopper_insertion_force_n":      TagSpec(initial=35.0,    delta=0.5,    min_val=20.0,    max_val=60.0),
        "vial_count":                    TagSpec(initial=0.0,     delta=0.0,    min_val=0.0,     max_val=0.0),
        "reject_count":                  TagSpec(initial=0.0,     delta=0.0,    min_val=0.0,     max_val=0.0),
        "fill_weight_mg":                TagSpec(initial=2010.0,  delta=1.0,    min_val=1900.0,  max_val=2100.0),
        "tare_weight_mg":                TagSpec(initial=8500.0,  delta=5.0,    min_val=8000.0,  max_val=9000.0),
        "nitrogen_overlay_flow_l_min":   TagSpec(initial=5.0,     delta=0.1,    min_val=2.0,     max_val=10.0),
        "product_temp_c":                TagSpec(initial=5.0,     delta=0.1,    min_val=2.0,     max_val=8.0),
        "pump_speed_rpm":                TagSpec(initial=60.0,    delta=0.5,    min_val=20.0,    max_val=120.0),
        "dosing_accuracy_pct":           TagSpec(initial=99.5,    delta=0.02,   min_val=98.0,    max_val=100.0),
        "checkweigh_deviation_mg":       TagSpec(initial=2.0,     delta=0.2,    min_val=0.5,     max_val=10.0),
    },
    "deburring-machine": {
        "brush_speed_rpm":         TagSpec(initial=1500.0, delta=10.0,   min_val=500.0,   max_val=3000.0),
        "contact_pressure_bar":    TagSpec(initial=2.0,    delta=0.05,   min_val=0.5,     max_val=5.0),
        "feed_rate_mm_s":          TagSpec(initial=30.0,   delta=0.5,    min_val=10.0,    max_val=80.0),
        "surface_finish_ra_um":    TagSpec(initial=1.6,    delta=0.05,   min_val=0.4,     max_val=6.3),
        "material_removal_mm":     TagSpec(initial=0.05,   delta=0.002,  min_val=0.01,    max_val=0.2),
        "brush_wear_pct":          TagSpec(initial=5.0,    delta=0.002,  min_val=0.0,     max_val=100.0),
        "power_consumption_kw":    TagSpec(initial=3.5,    delta=0.1,    min_val=1.0,     max_val=8.0),
        "vibration_mm_s":          TagSpec(initial=1.0,    delta=0.05,   min_val=0.2,     max_val=4.0),
        "coolant_flow_l_min":      TagSpec(initial=2.0,    delta=0.05,   min_val=0.5,     max_val=6.0),
        "dust_extraction_m3_h":    TagSpec(initial=500.0,  delta=10.0,   min_val=200.0,   max_val=1000.0),
        "part_temp_c":             TagSpec(initial=32.0,   delta=0.3,    min_val=20.0,    max_val=60.0),
        "spindle_current_a":       TagSpec(initial=8.0,    delta=0.2,    min_val=3.0,     max_val=20.0),
        "burr_height_before_um":   TagSpec(initial=200.0,  delta=5.0,    min_val=50.0,    max_val=500.0),
        "burr_height_after_um":    TagSpec(initial=10.0,   delta=0.5,    min_val=1.0,     max_val=50.0),
        "cycle_count_brush":       TagSpec(initial=0.0,    delta=0.0,    min_val=0.0,     max_val=0.0),
    },
    "reflow-oven": {
        "zone1_temp_c":              TagSpec(initial=150.0,  delta=0.5,    min_val=130.0,   max_val=170.0),
        "zone2_temp_c":              TagSpec(initial=180.0,  delta=0.5,    min_val=160.0,   max_val=200.0),
        "zone3_temp_c":              TagSpec(initial=245.0,  delta=0.5,    min_val=230.0,   max_val=260.0),
        "zone4_temp_c":              TagSpec(initial=100.0,  delta=0.5,    min_val=50.0,    max_val=150.0),
        "conveyor_speed_cm_min":     TagSpec(initial=80.0,   delta=0.5,    min_val=40.0,    max_val=120.0),
        "oxygen_level_ppm":          TagSpec(initial=500.0,  delta=10.0,   min_val=50.0,    max_val=2000.0),
        "nitrogen_flow_l_min":       TagSpec(initial=40.0,   delta=0.5,    min_val=20.0,    max_val=80.0),
        "peak_temp_c":               TagSpec(initial=250.0,  delta=0.5,    min_val=240.0,   max_val=265.0),
        "time_above_liquidus_s":     TagSpec(initial=60.0,   delta=1.0,    min_val=30.0,    max_val=120.0),
        "heating_rate_c_s":          TagSpec(initial=2.0,    delta=0.05,   min_val=1.0,     max_val=4.0),
        "cooling_rate_c_s":          TagSpec(initial=3.5,    delta=0.1,    min_val=1.0,     max_val=6.0),
        "board_count":               TagSpec(initial=0.0,    delta=0.0,    min_val=0.0,     max_val=0.0),
        "power_consumption_kw":      TagSpec(initial=18.0,   delta=0.3,    min_val=10.0,    max_val=30.0),
        "exhaust_temp_c":            TagSpec(initial=85.0,   delta=0.5,    min_val=50.0,    max_val=120.0),
        "belt_width_mm":             TagSpec(initial=450.0,  delta=0.1,    min_val=300.0,   max_val=600.0),
    },
    "capping-machine": {
        "torque_nm":                    TagSpec(initial=1.8,    delta=0.05,   min_val=0.5,    max_val=4.0),
        "cap_position_accuracy_mm":     TagSpec(initial=0.2,    delta=0.01,   min_val=0.05,   max_val=0.5),
        "reject_rate_pct":              TagSpec(initial=0.5,    delta=0.05,   min_val=0.0,    max_val=5.0),
        "feed_rate_caps_min":           TagSpec(initial=120.0,  delta=1.0,    min_val=60.0,   max_val=300.0),
        "cap_presence_pct":             TagSpec(initial=99.5,   delta=0.05,   min_val=95.0,   max_val=100.0),
        "seal_integrity_pct":           TagSpec(initial=99.8,   delta=0.02,   min_val=95.0,   max_val=100.0),
        "chuck_speed_rpm":              TagSpec(initial=600.0,  delta=5.0,    min_val=200.0,  max_val=1200.0),
        "cam_track_force_n":            TagSpec(initial=150.0,  delta=2.0,    min_val=50.0,   max_val=300.0),
        "cap_height_mm":                TagSpec(initial=20.0,   delta=0.05,   min_val=15.0,   max_val=30.0),
        "skirt_diameter_mm":            TagSpec(initial=28.0,   delta=0.02,   min_val=20.0,   max_val=40.0),
        "liner_compression_pct":        TagSpec(initial=30.0,   delta=0.5,    min_val=10.0,   max_val=60.0),
        "elevator_level_pct":           TagSpec(initial=75.0,   delta=0.02,   min_val=10.0,   max_val=100.0),
        "servo_current_a":              TagSpec(initial=4.5,    delta=0.1,    min_val=1.0,    max_val=10.0),
        "vibration_mm_s":               TagSpec(initial=1.5,    delta=0.1,    min_val=0.3,    max_val=5.0),
        "cap_orientation_score_pct":    TagSpec(initial=98.0,   delta=0.1,    min_val=90.0,   max_val=100.0),
    },
    "wave-solder": {
        "solder_pot_temp_c":       TagSpec(initial=255.0,  delta=0.3,    min_val=245.0,   max_val=265.0),
        "wave_height_mm":          TagSpec(initial=5.0,    delta=0.1,    min_val=2.0,     max_val=10.0),
        "flux_density_ml_m2":      TagSpec(initial=80.0,   delta=1.0,    min_val=40.0,    max_val=150.0),
        "conveyor_speed_m_min":    TagSpec(initial=1.2,    delta=0.02,   min_val=0.5,     max_val=2.5),
        "preheat_top_temp_c":      TagSpec(initial=110.0,  delta=0.5,    min_val=80.0,    max_val=140.0),
        "preheat_bottom_temp_c":   TagSpec(initial=95.0,   delta=0.5,    min_val=60.0,    max_val=120.0),
        "solder_purity_pct":       TagSpec(initial=99.5,   delta=0.001,  min_val=97.0,    max_val=99.99),
        "dross_level_pct":         TagSpec(initial=3.0,    delta=0.005,  min_val=0.0,     max_val=15.0),
        "finger_clearance_mm":     TagSpec(initial=2.0,    delta=0.05,   min_val=0.5,     max_val=5.0),
        "contact_time_s":          TagSpec(initial=3.0,    delta=0.05,   min_val=1.0,     max_val=6.0),
        "board_angle_deg":         TagSpec(initial=6.0,    delta=0.1,    min_val=3.0,     max_val=10.0),
        "nitrogen_flow_l_min":     TagSpec(initial=30.0,   delta=0.5,    min_val=10.0,    max_val=60.0),
        "pot_level_mm":            TagSpec(initial=180.0,  delta=0.2,    min_val=150.0,   max_val=220.0),
        "bridge_defect_count":     TagSpec(initial=0.0,    delta=0.0,    min_val=0.0,     max_val=0.0),
        "icicle_count":            TagSpec(initial=0.0,    delta=0.0,    min_val=0.0,     max_val=0.0),
    },
    "profile-cutter": {
        "blade_speed_rpm":         TagSpec(initial=3000.0, delta=10.0,   min_val=2000.0,  max_val=4500.0),
        "cut_length_mm":           TagSpec(initial=1200.0, delta=0.1,    min_val=300.0,   max_val=3000.0),
        "feed_rate_mm_s":          TagSpec(initial=50.0,   delta=0.5,    min_val=20.0,    max_val=100.0),
        "blade_temp_c":            TagSpec(initial=45.0,   delta=0.3,    min_val=25.0,    max_val=80.0),
        "angle_accuracy_deg":      TagSpec(initial=0.05,   delta=0.002,  min_val=0.01,    max_val=0.2),
        "cut_depth_mm":            TagSpec(initial=40.0,   delta=0.1,    min_val=10.0,    max_val=80.0),
        "clamp_pressure_bar":      TagSpec(initial=5.0,    delta=0.1,    min_val=3.0,     max_val=8.0),
        "material_hardness_hrc":   TagSpec(initial=15.0,   delta=0.1,    min_val=8.0,     max_val=30.0),
        "chip_extraction_m3_h":    TagSpec(initial=120.0,  delta=2.0,    min_val=60.0,    max_val=200.0),
        "blade_wear_pct":          TagSpec(initial=8.0,    delta=0.002,  min_val=0.0,     max_val=100.0),
        "power_consumption_kw":    TagSpec(initial=5.5,    delta=0.1,    min_val=2.0,     max_val=10.0),
        "vibration_mm_s":          TagSpec(initial=1.8,    delta=0.1,    min_val=0.5,     max_val=5.0),
        "coolant_flow_l_min":      TagSpec(initial=3.0,    delta=0.05,   min_val=1.0,     max_val=8.0),
        "surface_roughness_um":    TagSpec(initial=3.2,    delta=0.05,   min_val=0.8,     max_val=10.0),
        "noise_level_db":          TagSpec(initial=88.0,   delta=0.5,    min_val=75.0,    max_val=100.0),
    },
    "aoi-inspection": {
        "inspection_speed_cm2_s":       TagSpec(initial=15.0,     delta=0.3,    min_val=5.0,     max_val=30.0),
        "camera_resolution_mp":         TagSpec(initial=12.0,     delta=0.01,   min_val=5.0,     max_val=25.0),
        "lighting_intensity_lux":       TagSpec(initial=15000.0,  delta=50.0,   min_val=5000.0,  max_val=30000.0),
        "defect_count":                 TagSpec(initial=0.0,      delta=0.0,    min_val=0.0,     max_val=0.0),
        "false_positive_count":         TagSpec(initial=0.0,      delta=0.0,    min_val=0.0,     max_val=0.0),
        "board_count":                  TagSpec(initial=0.0,      delta=0.0,    min_val=0.0,     max_val=0.0),
        "solder_joint_count":           TagSpec(initial=0.0,      delta=0.0,    min_val=0.0,     max_val=0.0),
        "component_count_inspected":    TagSpec(initial=0.0,      delta=0.0,    min_val=0.0,     max_val=0.0),
        "pass_rate_pct":                TagSpec(initial=97.5,     delta=0.1,    min_val=85.0,    max_val=100.0),
        "image_capture_ms":             TagSpec(initial=8.0,      delta=0.2,    min_val=2.0,     max_val=20.0),
        "processing_time_ms":           TagSpec(initial=25.0,     delta=0.5,    min_val=10.0,    max_val=50.0),
        "fov_width_mm":                 TagSpec(initial=30.0,     delta=0.1,    min_val=10.0,    max_val=50.0),
        "fov_height_mm":                TagSpec(initial=22.0,     delta=0.1,    min_val=8.0,     max_val=40.0),
        "magnification_x":             TagSpec(initial=5.0,      delta=0.05,   min_val=2.0,     max_val=15.0),
        "focus_score_pct":              TagSpec(initial=95.0,     delta=0.2,    min_val=80.0,    max_val=100.0),
    },
    "extruder": {
        "zone1_temp_c":            TagSpec(initial=170.0,  delta=0.3,    min_val=150.0,   max_val=200.0),
        "zone2_temp_c":            TagSpec(initial=185.0,  delta=0.3,    min_val=165.0,   max_val=210.0),
        "zone3_temp_c":            TagSpec(initial=195.0,  delta=0.3,    min_val=175.0,   max_val=220.0),
        "zone4_temp_c":            TagSpec(initial=200.0,  delta=0.3,    min_val=180.0,   max_val=230.0),
        "screw_speed_rpm":         TagSpec(initial=80.0,   delta=0.5,    min_val=20.0,    max_val=150.0),
        "melt_pressure_bar":       TagSpec(initial=180.0,  delta=2.0,    min_val=80.0,    max_val=350.0),
        "die_pressure_bar":        TagSpec(initial=120.0,  delta=1.5,    min_val=40.0,    max_val=250.0),
        "haul_off_speed_m_min":    TagSpec(initial=5.0,    delta=0.05,   min_val=1.0,     max_val=15.0),
        "melt_temp_c":             TagSpec(initial=205.0,  delta=0.3,    min_val=180.0,   max_val=260.0),
        "motor_current_a":         TagSpec(initial=45.0,   delta=0.5,    min_val=15.0,    max_val=100.0),
        "throughput_kg_h":         TagSpec(initial=60.0,   delta=0.5,    min_val=20.0,    max_val=150.0),
        "torque_pct":              TagSpec(initial=70.0,   delta=0.5,    min_val=30.0,    max_val=95.0),
        "head_pressure_bar":       TagSpec(initial=150.0,  delta=2.0,    min_val=60.0,    max_val=300.0),
        "vacuum_mbar":             TagSpec(initial=-200.0, delta=2.0,    min_val=-500.0,  max_val=-50.0),
        "cooling_water_temp_c":    TagSpec(initial=15.0,   delta=0.1,    min_val=8.0,     max_val=25.0),
        "line_speed_m_min":        TagSpec(initial=5.0,    delta=0.05,   min_val=1.0,     max_val=15.0),
    },
    "corner-welder": {
        "weld_temp_c":             TagSpec(initial=260.0,  delta=0.5,    min_val=240.0,   max_val=280.0),
        "weld_time_s":             TagSpec(initial=25.0,   delta=0.2,    min_val=15.0,    max_val=40.0),
        "clamp_force_kn":          TagSpec(initial=8.0,    delta=0.1,    min_val=4.0,     max_val=15.0),
        "joint_strength_n":        TagSpec(initial=3500.0, delta=20.0,   min_val=2500.0,  max_val=5000.0),
        "alignment_accuracy_mm":   TagSpec(initial=0.15,   delta=0.005,  min_val=0.05,    max_val=0.5),
        "heating_plate_temp_c":    TagSpec(initial=265.0,  delta=0.5,    min_val=250.0,   max_val=285.0),
        "melt_depth_mm":           TagSpec(initial=2.5,    delta=0.05,   min_val=1.5,     max_val=4.0),
        "joining_pressure_bar":    TagSpec(initial=4.0,    delta=0.1,    min_val=2.0,     max_val=7.0),
        "cooling_time_s":          TagSpec(initial=15.0,   delta=0.2,    min_val=8.0,     max_val=30.0),
        "bead_height_mm":          TagSpec(initial=1.5,    delta=0.02,   min_val=0.5,     max_val=3.0),
        "weld_flash_mm":           TagSpec(initial=0.3,    delta=0.02,   min_val=0.0,     max_val=1.0),
        "corner_angle_deg":        TagSpec(initial=90.0,   delta=0.01,   min_val=89.5,    max_val=90.5),
        "servo_position_mm":       TagSpec(initial=0.0,    delta=0.5,    min_val=-50.0,   max_val=50.0),
        "power_consumption_kw":    TagSpec(initial=4.0,    delta=0.1,    min_val=2.0,     max_val=8.0),
        "cycle_pressure_bar":      TagSpec(initial=5.5,    delta=0.1,    min_val=3.0,     max_val=8.0),
    },
    "trimming-press": {
        "press_force_kn":          TagSpec(initial=50.0,   delta=0.5,    min_val=10.0,    max_val=150.0),
        "trim_accuracy_mm":        TagSpec(initial=0.05,   delta=0.002,  min_val=0.01,    max_val=0.2),
        "feed_rate_mm_s":          TagSpec(initial=40.0,   delta=0.5,    min_val=15.0,    max_val=80.0),
        "die_clearance_mm":        TagSpec(initial=0.08,   delta=0.002,  min_val=0.02,    max_val=0.3),
        "stroke_speed_spm":        TagSpec(initial=60.0,   delta=0.5,    min_val=20.0,    max_val=120.0),
        "material_thickness_mm":   TagSpec(initial=2.5,    delta=0.02,   min_val=0.5,     max_val=8.0),
        "die_temp_c":              TagSpec(initial=35.0,   delta=0.2,    min_val=20.0,    max_val=60.0),
        "stripper_force_n":        TagSpec(initial=500.0,  delta=5.0,    min_val=100.0,   max_val=1500.0),
        "slug_ejection_pct":       TagSpec(initial=98.0,   delta=0.1,    min_val=85.0,    max_val=100.0),
        "lubrication_level_pct":   TagSpec(initial=80.0,   delta=0.01,   min_val=20.0,    max_val=100.0),
        "die_wear_pct":            TagSpec(initial=5.0,    delta=0.001,  min_val=0.0,     max_val=100.0),
        "punch_alignment_um":      TagSpec(initial=15.0,   delta=0.3,    min_val=3.0,     max_val=50.0),
        "press_energy_j":          TagSpec(initial=120.0,  delta=2.0,    min_val=30.0,    max_val=300.0),
        "vibration_mm_s":          TagSpec(initial=2.0,    delta=0.1,    min_val=0.5,     max_val=8.0),
        "noise_level_db":          TagSpec(initial=90.0,   delta=0.3,    min_val=78.0,    max_val=105.0),
    },
    "glass-setter": {
        "suction_vacuum_kpa":          TagSpec(initial=-65.0,   delta=0.5,    min_val=-85.0,   max_val=-30.0),
        "glass_thickness_mm":          TagSpec(initial=4.0,     delta=0.01,   min_val=3.0,     max_val=24.0),
        "sealant_flow_ml_min":         TagSpec(initial=25.0,    delta=0.5,    min_val=10.0,    max_val=50.0),
        "positioning_accuracy_mm":     TagSpec(initial=0.3,     delta=0.01,   min_val=0.05,    max_val=1.0),
        "glazing_depth_mm":            TagSpec(initial=18.0,    delta=0.1,    min_val=10.0,    max_val=30.0),
        "frame_dimension_mm":          TagSpec(initial=1200.0,  delta=0.5,    min_val=400.0,   max_val=3000.0),
        "glass_weight_kg":             TagSpec(initial=15.0,    delta=0.1,    min_val=3.0,     max_val=50.0),
        "sealant_temp_c":              TagSpec(initial=22.0,    delta=0.2,    min_val=15.0,    max_val=35.0),
        "press_force_n":               TagSpec(initial=200.0,   delta=3.0,    min_val=50.0,    max_val=500.0),
        "roller_speed_mm_s":           TagSpec(initial=80.0,    delta=1.0,    min_val=30.0,    max_val=150.0),
        "gasket_compression_pct":      TagSpec(initial=25.0,    delta=0.3,    min_val=10.0,    max_val=50.0),
        "uv_cure_intensity_mw_cm2":    TagSpec(initial=120.0,   delta=2.0,    min_val=50.0,    max_val=250.0),
        "edge_clearance_mm":           TagSpec(initial=3.0,     delta=0.05,   min_val=1.0,     max_val=6.0),
        "moisture_level_pct":          TagSpec(initial=8.0,     delta=0.2,    min_val=2.0,     max_val=20.0),
        "alignment_offset_mm":         TagSpec(initial=0.1,     delta=0.02,   min_val=0.0,     max_val=1.0),
    },
}


# ---------------------------------------------------------------------------
# Config Loaders
# ---------------------------------------------------------------------------

def _detect_repo_dir() -> str:
    """Auto-detect repository root relative to this script."""
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def normalize_machine_type(name: str) -> str:
    """Normalize machine type to kebab-case (hyphens)."""
    return name.replace("_", "-")


def load_machine_tags(machines_dir: str) -> Dict[str, List[str]]:
    """Load machine-specific tag names from machines/*.yaml.

    Returns dict: machine_type (kebab-case) -> list of machine-specific tag names.
    """
    result = {}
    for fname in sorted(os.listdir(machines_dir)):
        if not fname.endswith(".yaml"):
            continue
        path = os.path.join(machines_dir, fname)
        with open(path) as f:
            data = yaml.safe_load(f)
        name = data.get("name", fname.replace(".yaml", ""))
        structure = data.get("dataModel", {}).get("version", {}).get("v1", {}).get("structure", {})
        tags = [t for t in structure.keys() if t not in COMMON_TAGS]
        result[name] = tags
    return result


def load_line_configs(lines_dir: str) -> Dict[str, LineConfig]:
    """Load all line template configs from lines/**/*.yaml.

    Returns dict: template_name -> LineConfig.
    """
    result = {}
    for root, _dirs, files in os.walk(lines_dir):
        for fname in files:
            if not fname.endswith(".yaml"):
                continue
            path = os.path.join(root, fname)
            with open(path) as f:
                data = yaml.safe_load(f)

            name = data["name"]
            stages = []
            for m in data.get("machines", []):
                stages.append(StageConfig(
                    stage=m["stage"],
                    machine_type=normalize_machine_type(m["type"]),
                    cycle_time_ms=m["defaults"]["cycle_time_ms"],
                    scrap_rate=m["defaults"]["scrap_rate"],
                    breakdown_probability=m["defaults"]["breakdown_probability"],
                    auto_restore_time_ms=m["defaults"]["auto_restore_time_ms"],
                ))

            buf_cap = data.get("buffers", {}).get("default_capacity", 10)

            recipes = []
            for r in data.get("recipes", []):
                qty_range = tuple(r["planned_qty_range"])
                overrides = {}
                for stage_str, ovr in r.get("overrides", {}).items():
                    overrides[int(stage_str)] = ovr
                recipes.append(RecipeConfig(
                    product_id=r["product_id"],
                    description=r.get("description", ""),
                    planned_qty_range=qty_range,
                    overrides=overrides,
                ))

            result[name] = LineConfig(name=name, stages=stages, buffer_capacity=buf_cap, recipes=recipes)
    return result


def find_line_template(machine_types: List[str], templates: Dict[str, LineConfig]) -> Optional[str]:
    """Match a sequence of machine types to a line template by comparing stage types.

    Returns template name or None.
    """
    normalized = [normalize_machine_type(m) for m in machine_types]
    for tname, tconfig in templates.items():
        template_types = [s.machine_type for s in tconfig.stages]
        if normalized == template_types:
            return tname
    return None


def get_tag_spec(machine_type: str, tag_name: str) -> TagSpec:
    """Get TagSpec for a tag, with suffix-based fallback for unknown tags."""
    params = TAG_PARAMS.get(machine_type, {})
    if tag_name in params:
        return params[tag_name]
    # Suffix fallback — match longest suffix first
    for suffix, (initial, delta, min_val, max_val) in sorted(
        SUFFIX_DEFAULTS.items(), key=lambda x: -len(x[0])
    ):
        if tag_name.endswith(suffix):
            return TagSpec(initial=initial, delta=delta, min_val=min_val, max_val=max_val)
    return TagSpec(initial=50.0, delta=0.5, min_val=0.0, max_val=100.0)


def validate_tag_params(machine_tags: Dict[str, List[str]]):
    """Cross-check TAG_PARAMS against machine YAML tag names. Warn on mismatches."""
    for mtype, yaml_tags in machine_tags.items():
        param_tags = set(TAG_PARAMS.get(mtype, {}).keys())
        yaml_set = set(yaml_tags)
        missing = yaml_set - param_tags
        extra = param_tags - yaml_set
        if missing:
            print(f"  Warning: {mtype}: tags in YAML but not in TAG_PARAMS: {sorted(missing)}")
        if extra:
            print(f"  Warning: {mtype}: tags in TAG_PARAMS but not in YAML: {sorted(extra)}")


def parse_factory_setup(path: str) -> Tuple[str, str, List[Dict[str, Any]]]:
    """Parse factory-setup.yaml and return (enterprise, site, workcell_list).

    Each workcell dict has: machine_type, workcell_name, line_name, area.
    Lines are grouped so line-level simulation can identify stage sequences.
    """
    with open(path, "r") as f:
        setup = yaml.safe_load(f)

    enterprise = setup.get("enterprise", "Enterprise")
    site = setup.get("site", "Site")
    area = "shopfloor"

    workcells = []

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
                "line_machines": machines,  # full list for template matching
            })

    for machine_type in setup.get("standalone", []):
        workcell_name = f"{machine_type}-standalone"
        workcells.append({
            "machine_type": machine_type,
            "workcell_name": workcell_name,
            "line_name": workcell_name,
            "area": area,
            "line_machines": [machine_type],
        })

    return enterprise, site, workcells


# ---------------------------------------------------------------------------
# Simulation Classes
# ---------------------------------------------------------------------------

class DriftingTag:
    """A sensor tag that drifts randomly within bounds, matching Go simulator behavior."""

    __slots__ = ("current", "delta", "min_val", "max_val")

    def __init__(self, spec: TagSpec):
        self.current = spec.initial
        self.delta = spec.delta
        self.min_val = spec.min_val
        self.max_val = spec.max_val

    def tick(self):
        """Drift the tag value by one step: current += random(-1,+1) * delta; clamp."""
        if self.delta > 0:
            self.current += (random.random() * 2 - 1) * self.delta
            self.current = max(self.min_val, min(self.max_val, self.current))
        return self.current


class SimBuffer:
    """FIFO counter between production stages."""

    __slots__ = ("count", "capacity")

    def __init__(self, capacity: int):
        self.count = 0
        self.capacity = capacity

    def is_full(self) -> bool:
        return self.count >= self.capacity

    def is_empty(self) -> bool:
        return self.count <= 0

    def add(self):
        self.count = min(self.count + 1, self.capacity)

    def remove(self):
        self.count = max(self.count - 1, 0)


class SimMachine:
    """Per-machine state machine with counters and drifting sensor tags.

    State transitions match the Go simulator:
      IDLE -> RUNNING        (shift start)
      RUNNING -> IDLE        (shift end)
      RUNNING -> FAULT       (per-cycle probability = breakdown_probability)
      RUNNING -> STOPPED     (per-cycle ~0.2% probability)
      RUNNING -> MAINTENANCE (every ~2000 cycles, 30% chance)
      FAULT -> RUNNING       (after auto_restore_time_ms)
      STOPPED -> RUNNING     (after 2-15 min)
      MAINTENANCE -> IDLE    (after 15-45 min)
    """

    def __init__(self, machine_type: str, stage_config: StageConfig, tag_names: List[str]):
        self.machine_type = machine_type
        self.cycle_time_ms = stage_config.cycle_time_ms
        self.scrap_rate = stage_config.scrap_rate
        self.breakdown_prob = stage_config.breakdown_probability
        self.auto_restore_ms = stage_config.auto_restore_time_ms
        self.stage_num = stage_config.stage

        # Counters
        self.state = "IDLE"
        self.cycle_count = 0
        self.good_count = 0
        self.scrap_count = 0

        # Drifting sensor tags
        self.tags: Dict[str, DriftingTag] = {}
        for tname in tag_names:
            spec = get_tag_spec(machine_type, tname)
            self.tags[tname] = DriftingTag(spec)

        # Event scheduling
        self.next_event_time: Optional[datetime] = None
        self.stop_start: Optional[datetime] = None
        self.blocked = False
        self.starved = False

        # Override support (from active recipe)
        self._override_cycle_ms: Optional[int] = None
        self._override_scrap: Optional[float] = None

    @property
    def effective_cycle_ms(self) -> int:
        return self._override_cycle_ms or self.cycle_time_ms

    @property
    def effective_scrap_rate(self) -> float:
        return self._override_scrap if self._override_scrap is not None else self.scrap_rate

    def apply_recipe_override(self, overrides: Optional[Dict] = None):
        """Apply per-stage recipe overrides."""
        if overrides:
            self._override_cycle_ms = overrides.get("cycle_time_ms")
            self._override_scrap = overrides.get("scrap_rate")
        else:
            self._override_cycle_ms = None
            self._override_scrap = None

    def schedule_cycle(self, t: datetime):
        """Schedule next cycle completion with ±10% variance."""
        base = self.effective_cycle_ms
        variance = base * 0.1
        actual = base + random.uniform(-variance, variance)
        self.next_event_time = t + timedelta(milliseconds=actual)

    def start_running(self, t: datetime):
        self.state = "RUNNING"
        self.schedule_cycle(t)

    def enter_fault(self, t: datetime):
        self.state = "FAULT"
        self.stop_start = t
        restore_ms = self.auto_restore_ms * random.uniform(0.5, 1.5)
        self.next_event_time = t + timedelta(milliseconds=restore_ms)

    def enter_stopped(self, t: datetime):
        self.state = "STOPPED"
        self.stop_start = t
        duration = random.randint(2 * 60 * 1000, 15 * 60 * 1000)  # 2-15 min in ms
        self.next_event_time = t + timedelta(milliseconds=duration)

    def enter_maintenance(self, t: datetime):
        self.state = "MAINTENANCE"
        self.stop_start = t
        duration = random.randint(15 * 60 * 1000, 45 * 60 * 1000)  # 15-45 min
        self.next_event_time = t + timedelta(milliseconds=duration)

    def enter_idle(self, t: datetime):
        self.state = "IDLE"
        self.next_event_time = None


class LineSimulator:
    """Simulates a production line as coordinated stages with buffers.

    Uses event-driven stepping: jumps to next event rather than fixed ticks.
    """

    def __init__(
        self,
        line_config: LineConfig,
        machine_tag_names: Dict[str, List[str]],
        enterprise: str,
        site: str,
        area: str,
        line_name: str,
        workcell_names: List[str],
    ):
        self.line_config = line_config
        self.enterprise = enterprise
        self.site = site
        self.area = area
        self.line_name = line_name
        self.workcell_names = workcell_names

        # Create machines for each stage
        self.machines: List[SimMachine] = []
        for sc in line_config.stages:
            tags = machine_tag_names.get(sc.machine_type, [])
            self.machines.append(SimMachine(sc.machine_type, sc, tags))

        # Create buffers between stages
        self.buffers: List[SimBuffer] = []
        for _ in range(max(0, len(self.machines) - 1)):
            self.buffers.append(SimBuffer(line_config.buffer_capacity))

        # Recipe tracking
        self.recipes = line_config.recipes
        self.recipe_idx = 0
        self.active_order = None
        self.completed_orders: List[Dict] = []
        self.order_num = 0
        self._order_completed_qty = 0
        self._order_scrap_qty = 0
        self._order_planned_qty = 0

    def simulate(
        self,
        start_time: datetime,
        end_time: datetime,
        skip_weekends: bool = False,
    ) -> Dict[str, Dict]:
        """Run simulation, returns {workcell_name: {tag_records, tag_string_records, stops}}."""
        n = len(self.machines)
        last = n - 1

        # Per-machine output accumulators
        results = {}
        for i, wc_name in enumerate(self.workcell_names):
            results[wc_name] = {
                "tag_records": [],
                "tag_string_records": [],
                "stops": [],
                "machine_type": self.machines[i].machine_type,
                "stage_idx": i,
            }

        # Emit initial IDLE state for all machines
        for i, m in enumerate(self.machines):
            wc = self.workcell_names[i]
            results[wc]["tag_string_records"].append((start_time, "state", "IDLE"))
            results[wc]["tag_records"].append((start_time, "state", float(STATE_INT["IDLE"])))

        current_time = start_time
        last_printed_day = None

        while current_time < end_time:
            # Progress
            current_day = current_time.date()
            if current_day != last_printed_day:
                elapsed_pct = (current_time - start_time).total_seconds() / max(1, (end_time - start_time).total_seconds()) * 100
                print(f"      Simulating {current_day} ... {elapsed_pct:5.1f}%", flush=True)
                last_printed_day = current_day

            in_shift = self._is_shift_time(current_time, skip_weekends)

            if in_shift:
                # Start new order if needed
                if self.active_order is None and self.recipes:
                    self._start_new_order(current_time)

                # Start idle machines
                for i, m in enumerate(self.machines):
                    if m.state == "IDLE":
                        m.start_running(current_time)
                        wc = self.workcell_names[i]
                        results[wc]["tag_string_records"].append((current_time, "state", "RUNNING"))
                        results[wc]["tag_records"].append((current_time, "state", float(STATE_INT["RUNNING"])))

                # Find next event time
                next_time = end_time
                for m in self.machines:
                    if m.next_event_time and m.next_event_time < next_time:
                        next_time = m.next_event_time

                # Also limit to next shift boundary
                shift_end = current_time.replace(hour=SHIFT_END_HOUR, minute=0, second=0, microsecond=0)
                if shift_end <= current_time:
                    shift_end += timedelta(days=1)
                next_time = min(next_time, shift_end)

                if next_time <= current_time:
                    next_time = current_time + timedelta(milliseconds=100)

                current_time = next_time

                # Process each machine
                for i, m in enumerate(self.machines):
                    if m.next_event_time is None or m.next_event_time > current_time:
                        continue

                    wc = self.workcell_names[i]

                    if m.state == "RUNNING":
                        # Check blocking/starvation
                        blocked = (i < last) and self.buffers[i].is_full()
                        starved = (i > 0) and self.buffers[i - 1].is_empty()

                        if blocked or starved:
                            m.blocked = blocked
                            m.starved = starved
                            m.schedule_cycle(current_time)  # Retry later
                            results[wc]["tag_records"].append((current_time, "blocked_by_buffer", 1.0 if blocked else 0.0))
                            continue

                        m.blocked = False
                        m.starved = False

                        # Cycle complete
                        m.cycle_count += 1
                        is_scrap = random.random() < m.effective_scrap_rate
                        if is_scrap:
                            m.scrap_count += 1
                        else:
                            m.good_count += 1

                        # Buffer management
                        if i > 0:
                            self.buffers[i - 1].remove()
                        if i < last:
                            self.buffers[i].add()

                        # Track order on last stage
                        if i == last and self.active_order:
                            if is_scrap:
                                self._order_scrap_qty += 1
                            else:
                                self._order_completed_qty += 1
                            if self._order_completed_qty + self._order_scrap_qty >= self._order_planned_qty:
                                self._complete_order(current_time)

                        # Emit tag values at cycle completion
                        actual_ct = m.effective_cycle_ms * random.uniform(0.9, 1.1)
                        results[wc]["tag_records"].append((current_time, "cycle_count", float(m.cycle_count)))
                        results[wc]["tag_records"].append((current_time, "good_count", float(m.good_count)))
                        results[wc]["tag_records"].append((current_time, "scrap_count", float(m.scrap_count)))
                        results[wc]["tag_records"].append((current_time, "cycle_time_ms", round(actual_ct, 1)))
                        results[wc]["tag_records"].append((current_time, "blocked_by_buffer", 0.0))

                        # Drift and emit machine-specific sensor tags
                        for tname, dtag in m.tags.items():
                            results[wc]["tag_records"].append((current_time, tname, round(dtag.tick(), 4)))

                        # State transitions after cycle
                        if random.random() < m.breakdown_prob:
                            m.enter_fault(current_time)
                            results[wc]["tag_string_records"].append((current_time, "state", "FAULT"))
                            results[wc]["tag_records"].append((current_time, "state", float(STATE_INT["FAULT"])))
                        elif random.random() < 0.002:
                            m.enter_stopped(current_time)
                            results[wc]["tag_string_records"].append((current_time, "state", "STOPPED"))
                            results[wc]["tag_records"].append((current_time, "state", float(STATE_INT["STOPPED"])))
                        elif m.cycle_count > 0 and m.cycle_count % 2000 == 0 and random.random() < 0.3:
                            m.enter_maintenance(current_time)
                            results[wc]["tag_string_records"].append((current_time, "state", "MAINTENANCE"))
                            results[wc]["tag_records"].append((current_time, "state", float(STATE_INT["MAINTENANCE"])))
                        else:
                            m.schedule_cycle(current_time)

                    elif m.state == "FAULT":
                        # Fault resolved
                        results[wc]["stops"].append({
                            "start_time": m.stop_start,
                            "end_time": current_time,
                            "stop_reason_id": 9,  # Equipment failure
                        })
                        m.start_running(current_time)
                        results[wc]["tag_string_records"].append((current_time, "state", "RUNNING"))
                        results[wc]["tag_records"].append((current_time, "state", float(STATE_INT["RUNNING"])))

                    elif m.state == "STOPPED":
                        reason = random.choices(STOP_REASONS_PLANNED, STOP_REASON_WEIGHTS)[0]
                        results[wc]["stops"].append({
                            "start_time": m.stop_start,
                            "end_time": current_time,
                            "stop_reason_id": reason,
                        })
                        m.start_running(current_time)
                        results[wc]["tag_string_records"].append((current_time, "state", "RUNNING"))
                        results[wc]["tag_records"].append((current_time, "state", float(STATE_INT["RUNNING"])))

                    elif m.state == "MAINTENANCE":
                        results[wc]["stops"].append({
                            "start_time": m.stop_start,
                            "end_time": current_time,
                            "stop_reason_id": 5,  # Maintenance
                        })
                        m.enter_idle(current_time)
                        results[wc]["tag_string_records"].append((current_time, "state", "IDLE"))
                        results[wc]["tag_records"].append((current_time, "state", float(STATE_INT["IDLE"])))
            else:
                # Outside shift: all machines idle
                for i, m in enumerate(self.machines):
                    if m.state != "IDLE":
                        wc = self.workcell_names[i]
                        if m.state in ("FAULT", "STOPPED", "MAINTENANCE") and m.stop_start:
                            rid = 5 if m.state == "MAINTENANCE" else (9 if m.state == "FAULT" else 4)
                            results[wc]["stops"].append({
                                "start_time": m.stop_start,
                                "end_time": current_time,
                                "stop_reason_id": rid,
                            })
                        m.enter_idle(current_time)
                        results[wc]["tag_string_records"].append((current_time, "state", "IDLE"))
                        results[wc]["tag_records"].append((current_time, "state", float(STATE_INT["IDLE"])))

                # Complete any active order
                if self.active_order:
                    self._complete_order(current_time)

                # Jump to next shift start
                next_shift = current_time.replace(hour=SHIFT_START_HOUR, minute=0, second=0, microsecond=0)
                if next_shift <= current_time:
                    next_shift += timedelta(days=1)
                # Skip weekends
                if skip_weekends:
                    while next_shift.weekday() >= 5:
                        next_shift += timedelta(days=1)
                current_time = next_shift

        # Final order completion
        if self.active_order:
            self._complete_order(end_time)

        # Add summary info
        for i, wc_name in enumerate(self.workcell_names):
            m = self.machines[i]
            results[wc_name]["good_parts"] = m.good_count
            results[wc_name]["scrap_parts"] = m.scrap_count

        return results

    def _is_shift_time(self, dt: datetime, skip_weekends: bool) -> bool:
        if skip_weekends and dt.weekday() >= 5:
            return False
        return SHIFT_START_HOUR <= dt.hour < SHIFT_END_HOUR

    def _start_new_order(self, t: datetime):
        if not self.recipes:
            return
        recipe = self.recipes[self.recipe_idx % len(self.recipes)]
        self.recipe_idx += 1
        self.order_num += 1

        self._order_planned_qty = random.randint(*recipe.planned_qty_range)
        self._order_completed_qty = 0
        self._order_scrap_qty = 0

        self.active_order = {
            "order_id": f"ORD-HIST-{self.line_name.upper()}-{self.order_num:04d}",
            "product_id": recipe.product_id,
            "description": recipe.description,
            "planned_qty": self._order_planned_qty,
            "started_at": t,
            "recipe": recipe,
        }

        # Apply recipe overrides to each stage
        for m in self.machines:
            ovr = recipe.overrides.get(m.stage_num)
            m.apply_recipe_override(ovr)

    def _complete_order(self, t: datetime):
        if not self.active_order:
            return
        self.completed_orders.append({
            "timestamp": t,
            "order_id": self.active_order["order_id"],
            "customer": "",
            "part_number": self.active_order["product_id"],
            "part_description": self.active_order["description"],
            "quantity": self._order_planned_qty,
            "quantity_completed": self._order_completed_qty,
            "quantity_scrap": self._order_scrap_qty,
            "priority": random.randint(1, 100),
            "status": "COMPLETED",
            "due_date": t + timedelta(hours=random.randint(1, 24)),
            "started_at": self.active_order["started_at"],
            "completed_at": t,
        })
        self.active_order = None
        # Clear recipe overrides
        for m in self.machines:
            m.apply_recipe_override(None)


def generate_standalone_data(
    machine_type: str,
    tag_names: List[str],
    start_time: datetime,
    end_time: datetime,
    skip_weekends: bool = False,
) -> Dict[str, List]:
    """Generate historical data for a standalone machine (no line, no buffers).

    Uses default parameters when no line config is available.
    """
    default_stage = StageConfig(
        stage=1,
        machine_type=machine_type,
        cycle_time_ms=8000,
        scrap_rate=0.02,
        breakdown_probability=0.002,
        auto_restore_time_ms=30000,
    )
    dummy_line = LineConfig(
        name="standalone",
        stages=[default_stage],
        buffer_capacity=10,
        recipes=[],
    )
    sim = LineSimulator(
        line_config=dummy_line,
        machine_tag_names={machine_type: tag_names},
        enterprise="", site="", area="", line_name="standalone",
        workcell_names=["standalone"],
    )
    results = sim.simulate(start_time, end_time, skip_weekends)
    return results["standalone"]


def generate_shifts(start_time: datetime, end_time: datetime, skip_weekends: bool = False) -> List[Tuple]:
    """Generate shift records for the shifts table.

    Two shifts per day:
      Morning:   06:00 – 14:00
      Afternoon: 14:00 – 22:00

    Returns list of (shift_name, start_time, end_time) tuples.
    """
    shifts = []
    day = start_time.replace(hour=0, minute=0, second=0, microsecond=0)
    while day < end_time:
        if skip_weekends and day.weekday() >= 5:
            day += timedelta(days=1)
            continue

        morning_start = day.replace(hour=6)
        morning_end = day.replace(hour=14)
        afternoon_start = day.replace(hour=14)
        afternoon_end = day.replace(hour=22)

        if morning_end > start_time and morning_start < end_time:
            shifts.append(("Morning", max(morning_start, start_time), min(morning_end, end_time)))
        if afternoon_end > start_time and afternoon_start < end_time:
            shifts.append(("Afternoon", max(afternoon_start, start_time), min(afternoon_end, end_time)))

        day += timedelta(days=1)
    return shifts


# ---------------------------------------------------------------------------
# DB Functions
# ---------------------------------------------------------------------------

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
    cursor.execute("SELECT id FROM asset WHERE workcell=%s LIMIT 1", (workcell,))
    row = cursor.fetchone()
    cursor.close()
    return row[0] if row else None


def get_line_asset_id(conn, enterprise: str, site: str, area: str, line: str) -> Optional[int]:
    """Get or create asset_id for a production line (for orders)."""
    cursor = conn.cursor()
    cursor.execute(
        "SELECT id FROM asset WHERE enterprise=%s AND site=%s AND area=%s AND line=%s AND workcell='' LIMIT 1",
        (enterprise, site, area, line),
    )
    row = cursor.fetchone()
    if row:
        cursor.close()
        return row[0]

    cursor.execute(
        "INSERT INTO asset (enterprise, site, area, line, workcell, origin_id) VALUES (%s, %s, %s, %s, '', '') ON CONFLICT DO NOTHING RETURNING id",
        (enterprise, site, area, line),
    )
    row = cursor.fetchone()
    conn.commit()
    cursor.close()
    return row[0] if row else None


def insert_tag_values(conn, asset_id: int, tag_records: List[Tuple], batch_size: int = 5000) -> int:
    """Insert numeric tag values into the tag table."""
    if not tag_records:
        return 0
    cursor = conn.cursor()
    inserted = 0
    total = len(tag_records)

    for i in range(0, total, batch_size):
        batch = tag_records[i:i + batch_size]
        values = [(ts, asset_id, name, value, "historical-data-generator") for ts, name, value in batch]
        execute_values(
            cursor,
            "INSERT INTO tag (timestamp, asset_id, name, value, origin) VALUES %s ON CONFLICT DO NOTHING",
            values,
        )
        inserted += cursor.rowcount
        done = min(i + batch_size, total)
        print(f"      Inserting tags ... {done}/{total}", end="\r", flush=True)

    print(f"      Inserting tags ... {total}/{total} done    ")
    conn.commit()
    cursor.close()
    return inserted


def insert_tag_string_values(conn, asset_id: int, tag_string_records: List[Tuple], batch_size: int = 5000) -> int:
    """Insert string tag values into the tag_string table."""
    if not tag_string_records:
        return 0
    cursor = conn.cursor()
    inserted = 0
    total = len(tag_string_records)

    for i in range(0, total, batch_size):
        batch = tag_string_records[i:i + batch_size]
        values = [(ts, asset_id, name, value, "historical-data-generator") for ts, name, value in batch]
        execute_values(
            cursor,
            "INSERT INTO tag_string (timestamp, asset_id, name, value, origin) VALUES %s ON CONFLICT DO NOTHING",
            values,
        )
        inserted += cursor.rowcount
        done = min(i + batch_size, total)
        print(f"      Inserting states ... {done}/{total}", end="\r", flush=True)

    print(f"      Inserting states ... {total}/{total} done    ")
    conn.commit()
    cursor.close()
    return inserted


def insert_stops(conn, asset_id: int, stops: List[Dict], batch_size: int = 5000) -> int:
    """Insert stop records into the database."""
    if not stops:
        return 0
    cursor = conn.cursor()
    inserted = 0
    total = len(stops)

    for i in range(0, total, batch_size):
        batch = stops[i:i + batch_size]
        values = [(asset_id, s["start_time"], s["end_time"], s["stop_reason_id"]) for s in batch]
        execute_values(
            cursor,
            "INSERT INTO machine_stops (asset_id, start_time, end_time, stop_reason_id) VALUES %s ON CONFLICT DO NOTHING",
            values,
        )
        inserted += cursor.rowcount

    print(f"      Inserting stops ... {total}/{total} done    ")
    conn.commit()
    cursor.close()
    return inserted


def insert_shifts(conn, shifts: List[Tuple], batch_size: int = 1000) -> int:
    """Insert shift records into the shifts table."""
    if not shifts:
        return 0
    cursor = conn.cursor()
    inserted = 0
    total = len(shifts)

    for i in range(0, total, batch_size):
        batch = shifts[i:i + batch_size]
        values = [(name, start, end) for name, start, end in batch]
        execute_values(
            cursor,
            "INSERT INTO shifts (shift_name, start_time, end_time) VALUES %s",
            values,
        )
        inserted += cursor.rowcount

    conn.commit()
    cursor.close()
    return inserted


def insert_production_orders(conn, asset_id: int, orders: List[Dict], batch_size: int = 100) -> int:
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
                o["timestamp"], asset_id, o["order_id"], o["customer"],
                o["part_number"], o["part_description"], o["quantity"],
                o["quantity_completed"], o["quantity_scrap"], o["priority"],
                o["status"], o["due_date"], o["started_at"], o["completed_at"]
            )
            for o in batch
        ]
        execute_values(
            cursor,
            """INSERT INTO production_orders
                (timestamp, asset_id, order_id, customer, part_number, part_description,
                 quantity, quantity_completed, quantity_scrap, priority, status,
                 due_date, started_at, completed_at)
            VALUES %s
            ON CONFLICT (asset_id, order_id) DO UPDATE SET
                quantity_completed = EXCLUDED.quantity_completed,
                quantity_scrap = EXCLUDED.quantity_scrap,
                status = EXCLUDED.status,
                started_at = EXCLUDED.started_at,
                completed_at = EXCLUDED.completed_at""",
            values,
        )
        inserted += cursor.rowcount

    conn.commit()
    cursor.close()
    return inserted


def cleanup_historical_data(conn):
    """Delete all previously generated historical data."""
    cursor = conn.cursor()
    print("  Cleaning up old historical data...")

    counts = {}
    tables = [
        ("tag", "DELETE FROM tag WHERE origin = 'historical-data-generator'"),
        ("tag_string", "DELETE FROM tag_string WHERE origin = 'historical-data-generator'"),
        ("machine_stops", "DELETE FROM machine_stops"),
        ("production_orders", "DELETE FROM production_orders WHERE order_id LIKE 'ORD-HIST-%'"),
        ("shifts", "DELETE FROM shifts"),
    ]

    for name, sql in tables:
        try:
            cursor.execute(sql)
            counts[name] = cursor.rowcount
        except psycopg2.errors.UndefinedTable:
            conn.rollback()
            counts[name] = 0

    conn.commit()
    cursor.close()

    total = sum(counts.values())
    if total:
        parts = [f"{v} {k}" for k, v in counts.items() if v > 0]
        print(f"    Deleted: {', '.join(parts)}")
    else:
        print("    No existing data to clean up (fresh database)")
    print()


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def parse_args():
    parser = argparse.ArgumentParser(description="Generate historical data for UMH demo")
    parser.add_argument("--days", type=int, default=7, help="Days of historical data (max 7, default: 7)")
    parser.add_argument("--since", type=str, help="Start date (YYYY-MM-DD). Overrides --days.")
    parser.add_argument("--factory-setup", type=str, help="Path to factory-setup.yaml")
    parser.add_argument("--machines", nargs="+", default=None, help="Machine types for standalone mode")
    parser.add_argument("--host", type=str, default="localhost", help="PostgreSQL host")
    parser.add_argument("--port", type=int, default=5432, help="PostgreSQL port")
    parser.add_argument("--db", type=str, default="umh", help="Database name")
    parser.add_argument("--user", type=str, default="postgres", help="Database user")
    parser.add_argument("--password", type=str, default="postgres", help="Database password")
    parser.add_argument("--batch-size", type=int, default=5000, help="Batch size for inserts")
    parser.add_argument("--dry-run", action="store_true", help="Print stats without inserting")
    parser.add_argument("--skip-weekends", action="store_true", help="Skip weekend days")
    return parser.parse_args()


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    args = parse_args()

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

    # Load configs from YAML files
    repo_dir = _detect_repo_dir()
    machines_dir = os.path.join(repo_dir, "machines")
    lines_dir = os.path.join(repo_dir, "config", "simulator-config", "lines")

    machine_tags = {}
    line_templates = {}

    if os.path.isdir(machines_dir):
        machine_tags = load_machine_tags(machines_dir)
        print(f"  Loaded {len(machine_tags)} machine types from {machines_dir}")
        validate_tag_params(machine_tags)
    else:
        print(f"  Warning: machines dir not found at {machines_dir}, using TAG_PARAMS only")
        machine_tags = {mt: list(tags.keys()) for mt, tags in TAG_PARAMS.items()}

    if os.path.isdir(lines_dir):
        line_templates = load_line_configs(lines_dir)
        print(f"  Loaded {len(line_templates)} line templates from {lines_dir}")
    else:
        print(f"  Warning: lines config dir not found at {lines_dir}")

    # Determine workcells to generate
    workcell_list = []
    enterprise = ""
    site = ""

    if args.factory_setup:
        enterprise, site, workcells = parse_factory_setup(args.factory_setup)
        for wc in workcells:
            wc["enterprise"] = enterprise
            wc["site"] = site
        workcell_list = workcells
        print(f"  Factory setup: {enterprise}/{site} with {len(workcell_list)} workcells")
    elif args.machines:
        all_types = list(machine_tags.keys()) if machine_tags else list(TAG_PARAMS.keys())
        if "all" in args.machines:
            mtypes = all_types
        else:
            mtypes = [m for m in args.machines if m in machine_tags or m in TAG_PARAMS]
        if not mtypes:
            print(f"Error: No valid machines. Available: {sorted(all_types)}")
            sys.exit(1)
        for mt in mtypes:
            workcell_list.append({
                "machine_type": mt,
                "workcell_name": mt,
                "line_name": "",
                "area": "",
                "enterprise": "",
                "site": "",
                "line_machines": [mt],
            })
    else:
        print("Error: Provide either --factory-setup or --machines")
        sys.exit(1)

    print(f"\n  Generating historical data:")
    print(f"    Time range:      {start_time.strftime('%Y-%m-%d %H:%M')} to {end_time.strftime('%Y-%m-%d %H:%M')}")
    print(f"    Workcells:       {len(workcell_list)}")
    print(f"    Skip weekends:   {args.skip_weekends}")
    print()

    # Connect to database
    conn = None
    if not args.dry_run:
        try:
            conn = psycopg2.connect(
                host=args.host, port=args.port, dbname=args.db,
                user=args.user, password=args.password,
            )
            print(f"  Connected to database {args.db}@{args.host}:{args.port}")
        except psycopg2.Error as e:
            print(f"  Error connecting to database: {e}")
            sys.exit(1)

        cleanup_historical_data(conn)

    # Generate and insert shifts
    shift_records = generate_shifts(start_time, end_time, args.skip_weekends)
    print(f"  Generated {len(shift_records)} shift records")
    if conn and shift_records:
        insert_shifts(conn, shift_records)
        print(f"  Inserted {len(shift_records)} shifts")
    print()

    # Group workcells by line for line-level simulation
    lines: Dict[str, List[Dict]] = {}
    for wc in workcell_list:
        key = wc.get("line_name", "")
        if key not in lines:
            lines[key] = []
        lines[key].append(wc)

    total_tags = 0
    total_tag_strings = 0
    total_stops = 0
    total_orders = 0
    skipped = 0
    overall_start = time.time()

    for line_name, line_workcells in lines.items():
        # Try to match line to a template
        machine_list = line_workcells[0].get("line_machines", [])
        template_name = find_line_template(machine_list, line_templates)
        template = line_templates.get(template_name) if template_name else None

        if template and len(line_workcells) == len(template.stages):
            # Line-level simulation
            print(f"  Line: {line_name} (template: {template_name}, {len(template.stages)} stages)")
            workcell_names = [wc["workcell_name"] for wc in line_workcells]

            sim = LineSimulator(
                line_config=template,
                machine_tag_names=machine_tags,
                enterprise=enterprise, site=site, area="shopfloor",
                line_name=line_name,
                workcell_names=workcell_names,
            )

            line_start = time.time()
            results = sim.simulate(start_time, end_time, args.skip_weekends)
            gen_elapsed = time.time() - line_start

            # Insert per-machine data
            for wc_info in line_workcells:
                wc_name = wc_info["workcell_name"]
                data = results[wc_name]

                asset_id = None
                if conn:
                    if wc_info.get("enterprise"):
                        asset_id = get_asset_id(conn, wc_info["enterprise"], wc_info["site"], wc_info["area"], wc_info["line_name"], wc_name)
                    else:
                        asset_id = get_asset_id_by_workcell(conn, wc_name)

                    if asset_id is None:
                        print(f"    Warning: Asset not found for '{wc_name}', skipping")
                        skipped += 1
                        continue

                n_tags = len(data["tag_records"])
                n_strings = len(data["tag_string_records"])
                n_stops = len(data["stops"])
                print(f"    {wc_name}: {n_tags} tags, {n_strings} states, {n_stops} stops, "
                      f"{data.get('good_parts', 0)} good + {data.get('scrap_parts', 0)} scrap")

                if conn and asset_id is not None:
                    total_tags += insert_tag_values(conn, asset_id, data["tag_records"], args.batch_size)
                    total_tag_strings += insert_tag_string_values(conn, asset_id, data["tag_string_records"], args.batch_size)
                    total_stops += insert_stops(conn, asset_id, data["stops"], args.batch_size)

            # Insert production orders at line level
            if conn and sim.completed_orders:
                line_asset_id = get_line_asset_id(conn, enterprise, site, "shopfloor", line_name)
                if line_asset_id:
                    n_orders = insert_production_orders(conn, line_asset_id, sim.completed_orders, args.batch_size)
                    total_orders += n_orders
                    print(f"    Orders: {len(sim.completed_orders)} ({n_orders} inserted)")

            print(f"    Line simulated in {gen_elapsed:.1f}s")
            print()

        else:
            # Standalone machine simulation (no template match)
            for wc_info in line_workcells:
                wc_name = wc_info["workcell_name"]
                mt = wc_info["machine_type"]
                tags = machine_tags.get(mt, list(TAG_PARAMS.get(mt, {}).keys()))

                if not tags and mt not in TAG_PARAMS:
                    print(f"  Warning: Unknown machine type '{mt}', skipping {wc_name}")
                    skipped += 1
                    continue

                asset_id = None
                if conn:
                    if wc_info.get("enterprise"):
                        asset_id = get_asset_id(conn, wc_info["enterprise"], wc_info["site"], wc_info["area"], wc_info["line_name"], wc_name)
                    else:
                        asset_id = get_asset_id_by_workcell(conn, wc_name)

                    if asset_id is None:
                        print(f"  Warning: Asset not found for '{wc_name}', skipping")
                        skipped += 1
                        continue

                print(f"  Standalone: {wc_name} (type: {mt})")
                wc_start = time.time()
                data = generate_standalone_data(mt, tags, start_time, end_time, args.skip_weekends)
                gen_elapsed = time.time() - wc_start

                n_tags = len(data["tag_records"])
                n_strings = len(data["tag_string_records"])
                n_stops = len(data["stops"])
                print(f"    Generated {n_tags} tags, {n_strings} states, {n_stops} stops in {gen_elapsed:.1f}s")
                print(f"    Production: {data.get('good_parts', 0)} good + {data.get('scrap_parts', 0)} scrap")

                if conn and asset_id is not None:
                    total_tags += insert_tag_values(conn, asset_id, data["tag_records"], args.batch_size)
                    total_tag_strings += insert_tag_string_values(conn, asset_id, data["tag_string_records"], args.batch_size)
                    total_stops += insert_stops(conn, asset_id, data["stops"], args.batch_size)
                print()

    # Summary
    total_elapsed = time.time() - overall_start
    wc_total = len(workcell_list)

    print("  " + "=" * 50)
    print("  SUMMARY")
    print("  " + "=" * 50)
    print(f"  Workcells processed: {wc_total - skipped}/{wc_total}")
    if skipped > 0:
        print(f"  Workcells skipped:   {skipped}")
    if not args.dry_run:
        print(f"  Shifts inserted:     {len(shift_records)}")
        print(f"  Tags inserted:       {total_tags}")
        print(f"  State records:       {total_tag_strings}")
        print(f"  Stops inserted:      {total_stops}")
        print(f"  Orders inserted:     {total_orders}")
    print(f"  Total time:          {total_elapsed:.1f}s")

    # Verification
    if conn:
        try:
            cursor = conn.cursor()
            cursor.execute("SELECT count(*) FROM tag WHERE origin = 'historical-data-generator'")
            tag_count = cursor.fetchone()[0]
            cursor.execute("SELECT count(*) FROM tag_string WHERE origin = 'historical-data-generator'")
            tag_string_count = cursor.fetchone()[0]
            cursor.execute("SELECT count(*) FROM shifts")
            shift_count = cursor.fetchone()[0]
            cursor.execute("SELECT min(timestamp), max(timestamp) FROM tag WHERE origin = 'historical-data-generator'")
            row = cursor.fetchone()
            cursor.close()
            print()
            print("  Verification:")
            print(f"    Total tag rows in DB:        {tag_count}")
            print(f"    Total tag_string rows in DB: {tag_string_count}")
            print(f"    Total shifts in DB:          {shift_count}")
            if row[0]:
                print(f"    Data range: {row[0].strftime('%Y-%m-%d %H:%M')} to {row[1].strftime('%Y-%m-%d %H:%M')}")
        except Exception:
            pass

        conn.close()

    print()
    print("  Historical data generation complete!")


if __name__ == "__main__":
    main()
