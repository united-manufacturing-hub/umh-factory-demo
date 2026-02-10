-- Asset Helper Functions for Grafana Dashboards
-- These functions provide flexible asset_id lookup for dashboard queries
--
-- Usage in Grafana:
--   SELECT * FROM tag WHERE asset_id IN (SELECT get_asset_ids_stable('Enterprise', 'Site', 'Area', 'Line', 'Workcell'))
--
-- Run with: docker compose exec timescaledb psql -U postgres -d umh -f /sql/init-functions.sql

-- Get single asset_id (exact match, returns NULL if not found)
CREATE OR REPLACE FUNCTION get_asset_id(
    _enterprise text,
    _site text DEFAULT '',
    _area text DEFAULT '',
    _line text DEFAULT '',
    _workcell text DEFAULT '',
    _origin_id text DEFAULT ''
) RETURNS integer AS $func$
DECLARE
    result_id integer;
BEGIN
    SELECT id INTO result_id FROM asset
    WHERE enterprise = _enterprise
    AND site = _site
    AND area = _area
    AND line = _line
    AND workcell = _workcell
    AND origin_id = _origin_id
    LIMIT 1;
    RETURN result_id;
END;
$func$ LANGUAGE plpgsql;

-- Get single asset_id (exact match, STABLE, throws error if not found)
CREATE OR REPLACE FUNCTION get_asset_id_stable(
    _enterprise text,
    _site text DEFAULT '',
    _area text DEFAULT '',
    _line text DEFAULT '',
    _workcell text DEFAULT '',
    _origin_id text DEFAULT ''
) RETURNS integer AS $func$
DECLARE
    result_id integer;
BEGIN
    SELECT id INTO result_id FROM asset
    WHERE enterprise = _enterprise
    AND site = _site
    AND area = _area
    AND line = _line
    AND workcell = _workcell
    AND origin_id = _origin_id
    LIMIT 1;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No asset found with the given parameters';
    END IF;
    RETURN result_id;
END;
$func$ LANGUAGE plpgsql STABLE;

-- Get single asset_id (exact match, IMMUTABLE, throws error if not found)
CREATE OR REPLACE FUNCTION get_asset_id_immutable(
    _enterprise text,
    _site text DEFAULT '',
    _area text DEFAULT '',
    _line text DEFAULT '',
    _workcell text DEFAULT '',
    _origin_id text DEFAULT ''
) RETURNS integer AS $func$
DECLARE
    result_id integer;
BEGIN
    SELECT id INTO result_id FROM asset
    WHERE enterprise = _enterprise
    AND site = _site
    AND area = _area
    AND line = _line
    AND workcell = _workcell
    AND origin_id = _origin_id
    LIMIT 1;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No asset found with the given parameters';
    END IF;
    RETURN result_id;
END;
$func$ LANGUAGE plpgsql IMMUTABLE;

-- Get multiple asset_ids (flexible filtering, empty string = match all)
CREATE OR REPLACE FUNCTION get_asset_ids(
    _enterprise text,
    _site text DEFAULT '',
    _area text DEFAULT '',
    _line text DEFAULT '',
    _workcell text DEFAULT '',
    _origin_id text DEFAULT ''
)
RETURNS SETOF integer AS $func$
BEGIN
    RETURN QUERY
    SELECT id FROM asset
    WHERE enterprise = _enterprise
    AND (_site = '' OR site = _site)
    AND (_area = '' OR area = _area)
    AND (_line = '' OR line = _line)
    AND (_workcell = '' OR workcell = _workcell)
    AND (_origin_id = '' OR origin_id = _origin_id);
END;
$func$ LANGUAGE plpgsql;

-- Get multiple asset_ids (STABLE version - better for query optimization)
CREATE OR REPLACE FUNCTION get_asset_ids_stable(
    _enterprise text,
    _site text DEFAULT '',
    _area text DEFAULT '',
    _line text DEFAULT '',
    _workcell text DEFAULT '',
    _origin_id text DEFAULT ''
)
RETURNS SETOF integer AS $func$
BEGIN
    RETURN QUERY
    SELECT id FROM asset
    WHERE enterprise = _enterprise
    AND (_site = '' OR site = _site)
    AND (_area = '' OR area = _area)
    AND (_line = '' OR line = _line)
    AND (_workcell = '' OR workcell = _workcell)
    AND (_origin_id = '' OR origin_id = _origin_id);
END;
$func$ LANGUAGE plpgsql STABLE;

-- Grant execute permissions (grafanareader role may not exist yet, ignore errors)
DO $$ BEGIN
    EXECUTE 'GRANT EXECUTE ON FUNCTION get_asset_id(text, text, text, text, text, text) TO grafanareader';
EXCEPTION WHEN undefined_object THEN NULL;
END $$;

DO $$ BEGIN
    EXECUTE 'GRANT EXECUTE ON FUNCTION get_asset_id_stable(text, text, text, text, text, text) TO grafanareader';
EXCEPTION WHEN undefined_object THEN NULL;
END $$;

DO $$ BEGIN
    EXECUTE 'GRANT EXECUTE ON FUNCTION get_asset_id_immutable(text, text, text, text, text, text) TO grafanareader';
EXCEPTION WHEN undefined_object THEN NULL;
END $$;

DO $$ BEGIN
    EXECUTE 'GRANT EXECUTE ON FUNCTION get_asset_ids(text, text, text, text, text, text) TO grafanareader';
EXCEPTION WHEN undefined_object THEN NULL;
END $$;

DO $$ BEGIN
    EXECUTE 'GRANT EXECUTE ON FUNCTION get_asset_ids_stable(text, text, text, text, text, text) TO grafanareader';
EXCEPTION WHEN undefined_object THEN NULL;
END $$;

-- Output success message
DO $$
BEGIN
    RAISE NOTICE 'Asset helper functions created successfully';
    RAISE NOTICE 'Functions available: get_asset_id, get_asset_id_stable, get_asset_id_immutable, get_asset_ids, get_asset_ids_stable';
END $$;
