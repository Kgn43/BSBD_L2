--обновление таблиц для новых полей
ALTER TABLE app.parcels 
ADD COLUMN expected_delivery_period DATERANGE;

ALTER TABLE app.parcels ADD COLUMN tags TEXT[];
COMMENT ON COLUMN app.parcels.tags IS 'Теги характеристик посылки (например: "хрупкое", "срочно", "не_кантовать")';


--наполнение БД синтетическими данными
SELECT setval(
    pg_get_serial_sequence('app.clients', 'id'), 
    (SELECT MAX(id) FROM app.clients)
);

WITH init_data AS (
    SELECT 
        ARRAY(SELECT id FROM app.clients) as client_ids,
        ARRAY(SELECT id FROM app.departments) as dept_ids,
        ARRAY[
            '{"хрупкое"}',
            '{"срочно"}',
            '{"не_кантовать"}',
            '{"хрупкое","срочно"}',
            '{"жидкость","осторожно"}',
            '{"документы","срочно"}',
            '{"опасный_груз","тяжелое"}',
            '{}'
        ]::text[] as tag_sets
)
INSERT INTO app.parcels (
    tracking_number, 
    sender_client_id, 
    recipient_client_id, 
    departure_department_id, 
    arrival_department_id, 
    weight_kg, 
    declared_value, 
    created_at,
    expected_delivery_period, 
    tags                   
)
SELECT 
    'RR' || lpad(s.id::text, 10, '0') || 'RU',
    init_data.client_ids[floor(random() * array_length(init_data.client_ids, 1) + 1)],
    init_data.client_ids[floor(random() * array_length(init_data.client_ids, 1) + 1)],
    init_data.dept_ids[floor(random() * array_length(init_data.dept_ids, 1) + 1)],
    init_data.dept_ids[floor(random() * array_length(init_data.dept_ids, 1) + 1)],
    (random() * 24.9 + 0.1)::numeric(10,3),
    (random() * 49900 + 100)::numeric(12,2),
    
    gen_date.c_at,

    daterange(gen_start.start_date, gen_end.end_date, '[]'),
    
    (init_data.tag_sets[floor(random() * array_length(init_data.tag_sets, 1) + 1)])::text[]

FROM generate_series(1, 100000) AS s(id)
CROSS JOIN init_data
CROSS JOIN LATERAL (
    SELECT timestamp '2025-01-01' + random() * (timestamp '2026-02-28' - timestamp '2025-01-01') AS c_at
) as gen_date
CROSS JOIN LATERAL (
    SELECT (gen_date.c_at)::date + floor(random() * 8 + 2)::int AS start_date
) as gen_start
CROSS JOIN LATERAL (
    SELECT gen_start.start_date + floor(random() * 4 + 1)::int AS end_date
) as gen_end;

/*

-- 1. B-Tree: поиск всех посылок клиента
EXPLAIN ANALYZE SELECT * FROM app.parcels WHERE sender_client_id = 500;
-- 2. Hash: посылки в конкретное отделение
EXPLAIN ANALYZE SELECT * FROM app.parcels WHERE arrival_department_id = 5;
-- 3. GiST: пересечение диапазонов дат
EXPLAIN ANALYZE SELECT count(*) FROM app.parcels 
WHERE expected_delivery_period && daterange('2025-06-01', '2025-06-02', '[]');
-- 4. SP-GiST: поиск по маске телефона (регион/оператор)
EXPLAIN ANALYZE SELECT * FROM app.clients WHERE phone_plain LIKE '8916%';
-- 5. BRIN: поиск по дате создания
EXPLAIN ANALYZE SELECT * FROM app.parcels 
WHERE created_at BETWEEN '2025-01-01' AND '2025-01-05';
-- 6. GIN: поиск по метке в массиве
EXPLAIN ANALYZE SELECT count(*) FROM app.parcels WHERE tags @> ARRAY['хрупкое'];
*/




--индексы
CREATE INDEX idx_parcels_sender_btree ON app.parcels USING btree(sender_client_id);
CREATE INDEX idx_parcels_arrival_hash ON app.parcels USING hash(arrival_department_id);
CREATE INDEX idx_parcels_range_gist ON app.parcels USING gist(expected_delivery_period);
CREATE INDEX idx_clients_phone_spgist ON app.clients USING spgist(phone_plain);
CREATE INDEX idx_parcels_created_brin ON app.parcels USING brin(created_at);
CREATE INDEX idx_parcels_tags_gin ON app.parcels USING gin(tags);


ALTER TABLE app.route_segments ADD COLUMN discount_rate NUMERIC(5,2) DEFAULT 0;
ALTER TABLE app.clients ADD COLUMN personal_discount NUMERIC(5,2) DEFAULT 0;

/*
CREATE OR REPLACE FUNCTION app.fn_sync_client_discounts()
RETURNS TRIGGER AS $$
BEGIN
    IF (OLD.personal_discount IS DISTINCT FROM NEW.personal_discount) THEN
        UPDATE app.parcels
        SET declared_value = declared_value * (1 - NEW.personal_discount / 100)
        WHERE sender_client_id = NEW.id
          AND id NOT IN (
              SELECT parcel_id 
              FROM app.parcel_movements 
              WHERE status_id IN (8, 9, 10)
          );
        RAISE NOTICE 'Скидка клиента % изменена. Пересчитаны только активные посылки.', NEW.id;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_apply_personal_discount
AFTER UPDATE OF personal_discount ON app.clients
FOR EACH ROW
EXECUTE FUNCTION app.fn_sync_client_discounts();
*/

/*
SET ROLE app_owner;

CREATE TABLE IF NOT EXISTS audit.delete_tracking (
    user_name TEXT NOT NULL,
    event_time TIMESTAMP NOT NULL DEFAULT now()
);

COMMENT ON TABLE audit.delete_tracking IS 'Лог для отслеживания частоты удалений (защита от аномалий)';

SET ROLE app_owner;

CREATE OR REPLACE FUNCTION app.fn_guard_mass_deletion()
RETURNS TRIGGER AS $$
DECLARE
    v_delete_count INT;
    v_limit INT := 5; -- Лимит удалений
    v_interval INTERVAL := '1 minute'; -- Промежуток времени
BEGIN
    -- 1. Записываем текущую попытку удаления
    INSERT INTO audit.delete_tracking (user_name) VALUES (session_user);

    -- 2. Считаем, сколько раз этот пользователь удалял записи за последнюю минуту
    SELECT COUNT(*) INTO v_delete_count
    FROM audit.delete_tracking
    WHERE user_name = session_user
      AND event_time > now() - v_interval;

    -- 3. Если лимит превышен — блокируем транзакцию
    IF v_delete_count > v_limit THEN
        RAISE EXCEPTION 'АНОМАЛЬНАЯ АКТИВНОСТЬ: Пользователь % превысил лимит удалений (% за %). Операция заблокирована. Сообщение отправлено в отдел безопасности.', 
            session_user, v_limit, v_interval;
    END IF;

    -- Периодическая очистка старых логов (чтобы таблица не разрасталась)
    -- Удаляем записи старше 1 часа
    DELETE FROM audit.delete_tracking WHERE event_time < now() - interval '1 hour';

    RETURN OLD;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER trg_guard_mass_deletion
BEFORE DELETE ON app.parcels
FOR EACH ROW
EXECUTE FUNCTION app.fn_guard_mass_deletion();

COMMENT ON TRIGGER trg_guard_mass_deletion ON app.parcels IS 'Блокировка массового удаления данных (защита от саботажа)';
*/


/*
SET ROLE app_owner;

CREATE OR REPLACE FUNCTION app.fn_refresh_timestamp()
RETURNS TRIGGER AS $$
BEGIN
    NEW.event_timestamp := now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_refresh_time
BEFORE INSERT OR UPDATE ON app.parcel_movements
FOR EACH ROW
EXECUTE FUNCTION app.fn_refresh_timestamp();



*/

/*
SET ROLE app_owner;

CREATE OR REPLACE FUNCTION app.fn_guard_employee_passwords()
RETURNS TRIGGER AS $$
DECLARE
    v_permission TEXT;
BEGIN
    IF (OLD.password_hash IS DISTINCT FROM NEW.password_hash) THEN
        v_permission := current_setting('app.allow_password_change', true);
        IF v_permission IS NULL OR v_permission <> 'true' THEN
            RAISE EXCEPTION 'ДОСТУП ЗАПРЕЩЕН: Изменение паролей заблокировано.';
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_guard_passwords
BEFORE UPDATE ON app.employees
FOR EACH ROW
EXECUTE FUNCTION app.fn_guard_employee_passwords();


*/