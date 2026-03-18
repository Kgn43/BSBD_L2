DO $$
DECLARE
    rec record;
    start_ts timestamptz;
BEGIN
    start_ts := clock_timestamp();
    FOR rec IN
        WITH data_source AS (
            SELECT
                i,
                (random() * 9 + 1)::int as d_id
            FROM generate_series(1, 10000) as s(i)
        )
        SELECT
            d_id AS departure_department_id,
            CASE
                WHEN i <= 3334 THEN d_id
                ELSE (d_id % 10) + 1
            END AS arrival_department_id,
            '1 hour'::interval AS expected_time
        FROM data_source
    LOOP
        BEGIN
            INSERT INTO app.route_segments (departure_department_id, arrival_department_id, expected_time)
            VALUES (rec.departure_department_id, rec.arrival_department_id, rec.expected_time);
        EXCEPTION
            WHEN check_violation THEN
        END;

    END LOOP;
    RAISE INFO 'Затраченное время: %', (clock_timestamp() - start_ts);
    ROLLBACK;
END $$;

---------------------------------
ALTER TABLE app.route_segments DROP CONSTRAINT IF EXISTS check_different_departments;

ALTER TABLE app.route_segments
ADD CONSTRAINT check_different_departments CHECK (departure_department_id <> arrival_department_id);

--------------------------------
--Триггер
CREATE OR REPLACE FUNCTION app.validate_different_departments()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.departure_department_id = NEW.arrival_department_id THEN
        RAISE EXCEPTION 'ID отдела отправления и прибытия не могут совпадать. Нарушение для ID: %', NEW.departure_department_id;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_check_different_departments
BEFORE INSERT ON app.route_segments
FOR EACH ROW
EXECUTE FUNCTION app.validate_different_departments();



--Для триггера
DO $$
DECLARE
    rec record;
    start_ts timestamptz;
BEGIN
    start_ts := clock_timestamp();
    FOR rec IN
        WITH data_source AS (
            SELECT
                i,
                (random() * 9 + 1)::int as d_id
            FROM generate_series(1, 10000) as s(i)
        )
        SELECT
            d_id AS departure_department_id,
            CASE
                WHEN i <= 3334 THEN d_id
                ELSE (d_id % 10) + 1
            END AS arrival_department_id,
            '1 hour'::interval AS expected_time
        FROM data_source
    LOOP
        BEGIN
            INSERT INTO app.route_segments (departure_department_id, arrival_department_id, expected_time)
            VALUES (rec.departure_department_id, rec.arrival_department_id, rec.expected_time);
        EXCEPTION
            WHEN raise_exception THEN
        END;

    END LOOP;
    RAISE INFO 'Затраченное время: %', (clock_timestamp() - start_ts);
    ROLLBACK;
END $$;
