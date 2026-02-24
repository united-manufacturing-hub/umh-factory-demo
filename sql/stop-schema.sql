-- =============================================================================
-- STOP REASONS & MACHINE STOPS SCHEMA
-- Standard schema for stop classification and tracking
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Table: stop_reasons
-- Specific stop reasons with category as text
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stop_reasons (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL UNIQUE,
    category VARCHAR(50) DEFAULT 'Unknown',
    description TEXT,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    updated_by VARCHAR(100)
);

-- Default stop reasons
INSERT INTO stop_reasons (id, name, category, description) VALUES
    (1, 'Unspecified', 'Unknown', 'Default reason - pending classification'),
    (2, 'Material shortage', 'External', 'Waiting for raw materials or components'),
    (3, 'Tool change', 'Planned', 'Scheduled tool replacement or adjustment'),
    (4, 'Operator break', 'Planned', 'Scheduled operator break or shift change'),
    (5, 'Maintenance', 'Planned', 'Scheduled preventive maintenance'),
    (6, 'Quality issue', 'Unplanned', 'Quality problem requiring investigation'),
    (7, 'Setup/changeover', 'Planned', 'Product changeover or setup time'),
    (8, 'Waiting for parts', 'External', 'Waiting for upstream machine output'),
    (9, 'Equipment failure', 'Unplanned', 'Unplanned machine breakdown'),
    (10, 'Other', 'Unknown', 'Other reason - requires manual entry')
ON CONFLICT (id) DO UPDATE SET
    name = EXCLUDED.name,
    category = EXCLUDED.category,
    description = EXCLUDED.description;

-- -----------------------------------------------------------------------------
-- Table: machine_stops
-- Individual stop events on machines
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS machine_stops (
    id SERIAL PRIMARY KEY,
    asset_id INTEGER NOT NULL,
    start_time TIMESTAMPTZ NOT NULL,
    end_time TIMESTAMPTZ,                          -- NULL = stop is ongoing
    state_value INTEGER,                           -- Machine state value when stop was detected
    stop_reason_id INTEGER REFERENCES stop_reasons(id) DEFAULT 1,
    notes TEXT,                                    -- Operator notes
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    updated_by VARCHAR(100),                       -- Who classified the stop

    CONSTRAINT machine_stops_time_check CHECK (end_time IS NULL OR end_time > start_time)
);

-- Add state_value column if table already exists without it
DO $$ BEGIN
    ALTER TABLE machine_stops ADD COLUMN IF NOT EXISTS state_value INTEGER;
EXCEPTION WHEN duplicate_column THEN NULL;
END $$;

-- Indexes for common queries
CREATE INDEX IF NOT EXISTS idx_machine_stops_asset_time
    ON machine_stops(asset_id, start_time DESC);
CREATE INDEX IF NOT EXISTS idx_machine_stops_open
    ON machine_stops(asset_id) WHERE end_time IS NULL;
CREATE INDEX IF NOT EXISTS idx_machine_stops_reason
    ON machine_stops(stop_reason_id);
CREATE INDEX IF NOT EXISTS idx_machine_stops_timerange
    ON machine_stops(start_time, end_time);

-- -----------------------------------------------------------------------------
-- View: machine_stops_with_details
-- Convenient view joining stops with reason and category info
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW machine_stops_with_details AS
SELECT
    ms.id,
    ms.asset_id,
    ms.start_time,
    ms.end_time,
    EXTRACT(EPOCH FROM (COALESCE(ms.end_time, NOW()) - ms.start_time)) AS duration_seconds,
    ms.notes,
    ms.updated_at,
    ms.updated_by,
    sr.id AS reason_id,
    sr.name AS reason_name,
    sr.category AS category_name
FROM machine_stops ms
LEFT JOIN stop_reasons sr ON ms.stop_reason_id = sr.id;

-- -----------------------------------------------------------------------------
-- Table: shifts
-- Shift schedule for availability calculations
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS shifts (
    id SERIAL PRIMARY KEY,
    shift_name VARCHAR(50) NOT NULL,
    start_time TIMESTAMPTZ NOT NULL,
    end_time TIMESTAMPTZ NOT NULL,
    asset_id INTEGER,  -- NULL = applies to all assets
    created_at TIMESTAMPTZ DEFAULT NOW(),

    CONSTRAINT shifts_time_check CHECK (end_time > start_time),
    UNIQUE (asset_id, shift_name, start_time)
);

CREATE INDEX IF NOT EXISTS idx_shifts_time ON shifts(start_time, end_time);
CREATE INDEX IF NOT EXISTS idx_shifts_asset ON shifts(asset_id);

-- -----------------------------------------------------------------------------
-- Table: production_orders
-- Production order tracking for OEE by order
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS production_orders (
    id SERIAL PRIMARY KEY,
    order_id VARCHAR(255) NOT NULL,
    asset_id INTEGER NOT NULL,
    customer VARCHAR(100),
    part_number VARCHAR(50),
    part_description TEXT,
    quantity INTEGER NOT NULL DEFAULT 0,
    quantity_completed INTEGER NOT NULL DEFAULT 0,
    quantity_scrap INTEGER NOT NULL DEFAULT 0,
    priority INTEGER DEFAULT 0,                      -- Required by erp-order-bridge
    status VARCHAR(20) NOT NULL DEFAULT 'PENDING',  -- PENDING, IN_PROGRESS, COMPLETED
    started_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    due_date TIMESTAMPTZ,
    timestamp TIMESTAMPTZ DEFAULT NOW(),  -- Required by erp-order-bridge
    planned_cycle_time_ms NUMERIC,            -- Ideal cycle time for OEE performance calc
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Add planned_cycle_time_ms for ideal/planned cycle time (used in OEE performance calculation)
ALTER TABLE production_orders ADD COLUMN IF NOT EXISTS planned_cycle_time_ms NUMERIC;

CREATE INDEX IF NOT EXISTS idx_production_orders_asset ON production_orders(asset_id);
CREATE INDEX IF NOT EXISTS idx_production_orders_status ON production_orders(status);
CREATE INDEX IF NOT EXISTS idx_production_orders_started ON production_orders(started_at DESC);
CREATE UNIQUE INDEX IF NOT EXISTS idx_production_orders_asset_order ON production_orders(asset_id, order_id);

-- -----------------------------------------------------------------------------
-- Table: part_scrap_costs
-- Per-part material cost for scrap loss calculations
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS part_scrap_costs (
    part_number VARCHAR(50) PRIMARY KEY,
    cost_per_unit NUMERIC(10,2) NOT NULL DEFAULT 0,
    description TEXT,
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Part scrap costs are seeded from line template YAMLs via generate-historical-data.py

-- -----------------------------------------------------------------------------
-- Table: line_downtime_costs
-- Per-line downtime cost for margin calculations
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS line_downtime_costs (
    line_name VARCHAR(100) PRIMARY KEY,
    cost_per_hour NUMERIC(10,2) NOT NULL DEFAULT 0,
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Line downtime costs are seeded from line template YAMLs via generate-historical-data.py

-- Success message
DO $$ BEGIN RAISE NOTICE 'Stop schema created successfully'; END $$;
