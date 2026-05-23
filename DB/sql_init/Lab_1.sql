--Создание таблицы, повторяющей структуру app.parcels
SET ROLE app_owner;

CREATE TABLE app.parcels_partitioned (
    id INT NOT NULL,
    tracking_number VARCHAR(20) NOT NULL,
    sender_client_id INT NOT NULL,
    recipient_client_id INT NOT NULL,
    departure_department_id INT NOT NULL,
    arrival_department_id INT NOT NULL,
    weight_kg NUMERIC(10, 3) NOT NULL,
    declared_value NUMERIC(12, 2) NOT NULL DEFAULT 0,
    created_at TIMESTAMP NOT NULL DEFAULT now(),
    CONSTRAINT pk_parcels_partitioned PRIMARY KEY (id, created_at)
) PARTITION BY RANGE (created_at);

COMMENT ON TABLE app.parcels_partitioned IS 'Секционированная таблица посылок';

--Реализация структуры секций

--До 1 февраля
CREATE TABLE app.parcels_archive PARTITION OF app.parcels_partitioned
    FOR VALUES FROM (MINVALUE) TO ('2026-02-01 00:00:00');

--С 1 февраля по 1 марта 
CREATE TABLE app.parcels_current PARTITION OF app.parcels_partitioned
    FOR VALUES FROM ('2026-02-01 00:00:00') TO ('2026-03-01 00:00:00');

--Создание 100 пользователей
SET session.encryption_key = 'ABOBA';
INSERT INTO app.clients (last_name, first_name, middle_name, phone, address)
SELECT 
    (ARRAY['Иванов', 'Петров', 'Сидоров', 'Кузнецов', 'Попов', 'Васильев', 'Павлов', 'Смирнов', 'Михайлов', 'Новиков'])[floor(random() * 10 + 1)],
    (ARRAY['Александр', 'Дмитрий', 'Сергей', 'Андрей', 'Алексей', 'Максим', 'Евгений', 'Иван', 'Михаил', 'Николай'])[floor(random() * 10 + 1)],
    'Иванович',
   '89' || (100000000 + floor(random() * 900000000))::text,
    pgp_sym_encrypt('г. Почтовый, ул. Примерная, д. ' || floor(random() * 150 + 1)::text, current_setting('session.encryption_key'))
FROM generate_series(1, 100000);
/*
--Создание 10 000 посылок
WITH ids AS (
    SELECT 
        ARRAY(SELECT id FROM app.clients) as client_ids,
        ARRAY(SELECT id FROM app.departments) as dept_ids
)
INSERT INTO app.parcels (
    tracking_number, 
    sender_client_id, 
    recipient_client_id, 
    departure_department_id, 
    arrival_department_id, 
    weight_kg, 
    declared_value, 
    created_at
)
SELECT 
    'RR' || lpad(s.id::text, 10, '0') || 'RU',
    client_ids[floor(random() * array_length(client_ids, 1) + 1)],
    client_ids[floor(random() * array_length(client_ids, 1) + 1)],
    dept_ids[floor(random() * array_length(dept_ids, 1) + 1)],
    dept_ids[floor(random() * array_length(dept_ids, 1) + 1)],
    (random() * 24.9 + 0.1)::numeric(10,3),
    (random() * 49900 + 100)::numeric(12,2),
    timestamp '2025-01-01' + random() * (timestamp '2026-02-28' - timestamp '2025-01-01')
FROM generate_series(1, 10000) AS s(id), ids;

*/
--Копирование данных
INSERT INTO app.parcels_partitioned (
    id, tracking_number, sender_client_id, recipient_client_id, 
    departure_department_id, arrival_department_id, 
    weight_kg, declared_value, created_at
)
SELECT 
    id, tracking_number, sender_client_id, recipient_client_id, 
    departure_department_id, arrival_department_id, 
    weight_kg, declared_value, created_at 
FROM app.parcels;
/*
--Начало задачи 2

--LTV
WITH client_ltv AS (
    SELECT 
        sender_client_id,
        SUM(declared_value) as total_sum,
        MIN(created_at) as first_order,
        MAX(created_at) as last_order
    FROM app.parcels_partitioned
    GROUP BY sender_client_id
)
SELECT 
    c.id,
    c.first_name || ' ' || c.last_name as client_name,
    cl.total_sum as ltv
FROM app.clients c
JOIN client_ltv cl ON c.id = cl.sender_client_id
ORDER BY ltv DESC


--AOV
WITH client_stats AS (
    -- Считаем количество заказов и общую сумму для каждого клиента
    SELECT 
        sender_client_id,
        COUNT(*) as orders_count,
        SUM(declared_value) as total_revenue
    FROM app.parcels_partitioned
    GROUP BY sender_client_id
),
averages AS (
    -- Рассчитываем средний чек (AOV)
    SELECT 
        sender_client_id,
        total_revenue / orders_count as aov
    FROM client_stats
)
SELECT 
    c.id,
    c.first_name || ' ' || c.last_name as client_name,
    ROUND(a.aov, 2) as average_order_value
FROM app.clients c
JOIN averages a ON c.id = a.sender_client_id
ORDER BY average_order_value DESC
LIMIT 5;


--ARPU
WITH current_revenue AS (
    --Считаем выручку только за февраль
    SELECT SUM(declared_value) as total_revenue
    FROM app.parcels_partitioned
    WHERE created_at >= '2026-02-01' AND created_at < '2026-03-01'
),
total_clients_ever AS (
    --Считаем всех клиентов за всё время
    SELECT COUNT(DISTINCT sender_client_id) as total_count
    FROM app.parcels_partitioned
)
SELECT 
    ROUND(r.total_revenue / c.total_count, 2) as arpu
FROM current_revenue r, total_clients_ever c;

--ARPPU
WITH february_arppu AS (
    SELECT 
        SUM(declared_value) as revenue,
        COUNT(DISTINCT sender_client_id) as paying_clients_count
    FROM app.parcels_partitioned
    WHERE created_at >= '2026-02-01' AND created_at < '2026-03-01'
)
SELECT 
    ROUND(revenue / paying_clients_count, 2) as arppu
FROM february_arppu

--топ 3
WITH route_stats AS (
    SELECT 
        departure_department_id, 
        arrival_department_id, 
        COUNT(*) as usage_count
    FROM app.parcels_partitioned
    WHERE created_at >= '2026-02-01' AND created_at < '2026-03-01'
    GROUP BY departure_department_id, arrival_department_id
)
SELECT 
    d1.city || ' (' || d1.address || ') -> ' || 
    d2.city || ' (' || d2.address || ')' as service_route,
    rs.usage_count as total_orders
FROM route_stats rs
JOIN app.departments d1 ON rs.departure_department_id = d1.id
JOIN app.departments d2 ON rs.arrival_department_id = d2.id
ORDER BY total_orders ASC
LIMIT 3;

-------------------
--Задача 3
-------------------
--Первое изменение (скидка на непопул маршруты)
-- Добавляем столбец
ALTER TABLE app.route_segments ADD COLUMN discount_rate NUMERIC(5,2) DEFAULT 0;
-- Устанавливаем скидку 15% для 3-х самых непопулярных маршрутов (где были заказы)
WITH route_popularity AS (
    SELECT 
        rs.id AS segment_id,
        COUNT(p.id) AS orders_count
    FROM app.route_segments rs
    LEFT JOIN app.parcels_partitioned p ON 
        rs.departure_department_id = p.departure_department_id AND 
        rs.arrival_department_id = p.arrival_department_id AND
        p.created_at >= '2026-02-01' AND p.created_at < '2026-03-01'
    GROUP BY rs.id
    ORDER BY orders_count ASC
    LIMIT 3
)
UPDATE app.route_segments
SET discount_rate = 15.00
WHERE id IN (SELECT segment_id FROM route_popularity);

--Второе (персон. скидка) 
--Добавляем колонку персональной скидки
ALTER TABLE app.clients ADD COLUMN personal_discount NUMERIC(5,2) DEFAULT 0;
--ТОП-20
WITH financial_heavyweights AS (
    SELECT 
        sender_client_id, 
        SUM(declared_value) as total_revenue
    FROM app.parcels_partitioned
    WHERE created_at >= '2026-02-01' AND created_at < '2026-03-01'
    GROUP BY sender_client_id
    ORDER BY total_revenue DESC
    LIMIT 20
)
UPDATE app.clients
SET personal_discount = 20.00
WHERE id IN (SELECT sender_client_id FROM financial_heavyweights);

--3-е (возврат клиентов)
ALTER TABLE app.clients ADD COLUMN reactivation_bonus_rub NUMERIC(10,2) DEFAULT 0;
WITH 
-- Клиенты, которые были активны в прошлом (до февраля 2026)
past_active_clients AS (
    SELECT DISTINCT sender_client_id
    FROM app.parcels_partitioned
    WHERE created_at < '2026-02-01'
),
-- Клиенты, которые УЖЕ совершили заказы в феврале 2026
currently_active_clients AS (
    SELECT DISTINCT sender_client_id
    FROM app.parcels_partitioned
    WHERE created_at >= '2026-02-01' AND created_at < '2026-03-01'
),
-- Итоговый список
churned_clients AS (
    SELECT p.sender_client_id
    FROM past_active_clients p
    LEFT JOIN currently_active_clients c ON p.sender_client_id = c.sender_client_id
    WHERE c.sender_client_id IS NULL
)
-- Начисляем бонус
UPDATE app.clients
SET reactivation_bonus_rub = 500.00
WHERE id IN (SELECT sender_client_id FROM churned_clients);

*/