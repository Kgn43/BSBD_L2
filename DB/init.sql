-- Включаем pgcrypto
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;

-- Включаем pgaudit
CREATE EXTENSION IF NOT EXISTS pgaudit WITH SCHEMA public;



-- Создание схем
CREATE SCHEMA app;
COMMENT ON SCHEMA app IS 'Бизнес-данные';

CREATE SCHEMA ref;
COMMENT ON SCHEMA ref IS 'Справочники';

CREATE SCHEMA audit;
COMMENT ON SCHEMA audit IS 'Аудит';

CREATE SCHEMA stg;
COMMENT ON SCHEMA stg IS 'Временные/обслуживающие';

-- Отнимем права у роли PUBLIC на схемы, зпрещаем создавать новые схемы
REVOKE ALL ON SCHEMA public, app, ref, audit, stg FROM PUBLIC;
REVOKE CREATE ON DATABASE admin FROM PUBLIC;


-- Создание ролей

-- app_owner
CREATE ROLE app_owner WITH 
  NOLOGIN 
  NOINHERIT;
COMMENT ON ROLE app_owner IS 'Роль-владелец для всех объектов';   

ALTER ROLE app_owner WITH BYPASSRLS;

GRANT CONNECT ON DATABASE admin TO app_owner;
GRANT CREATE ON DATABASE admin TO app_owner;
GRANT USAGE ON SCHEMA public TO app_owner;
GRANT EXECUTE ON FUNCTION pgp_sym_encrypt(text, text) TO app_owner;
GRANT EXECUTE ON FUNCTION pgp_sym_decrypt(bytea, text) TO app_owner;

-- Назначение роли владельцем существующих схем
ALTER SCHEMA app OWNER TO app_owner;
ALTER SCHEMA ref OWNER TO app_owner;
ALTER SCHEMA audit OWNER TO app_owner;
ALTER SCHEMA stg OWNER TO app_owner;

-- app_writer
CREATE ROLE app_writer WITH
  LOGIN
  NOINHERIT
  PASSWORD 'app_writer123';

COMMENT ON ROLE app_writer IS 'Роль с правами на чтение/запись';

GRANT CONNECT ON DATABASE admin TO app_writer;

GRANT USAGE ON SCHEMA app, ref, audit TO app_writer;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA app, ref TO app_writer;

ALTER DEFAULT PRIVILEGES FOR ROLE app_owner IN SCHEMA app, ref
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_writer;

ALTER DEFAULT PRIVILEGES FOR ROLE app_owner IN SCHEMA app
  GRANT USAGE, SELECT ON SEQUENCES TO app_writer;
ALTER DEFAULT PRIVILEGES FOR ROLE app_owner IN SCHEMA ref
  GRANT USAGE, SELECT ON SEQUENCES TO app_writer;


-- app_reader
CREATE ROLE app_reader WITH
  LOGIN
  NOINHERIT
  PASSWORD 'app_reader123';

COMMENT ON ROLE app_reader IS 'Роль для чтения данных из схем app и ref';

GRANT CONNECT ON DATABASE admin TO app_reader;
GRANT USAGE ON SCHEMA app, ref, audit TO app_reader;

ALTER DEFAULT PRIVILEGES FOR ROLE app_owner IN SCHEMA app, ref
  GRANT SELECT ON TABLES TO app_reader;

ALTER DEFAULT PRIVILEGES FOR ROLE app_owner IN SCHEMA app, ref
  GRANT SELECT ON SEQUENCES TO app_reader;


-- auditor
CREATE ROLE auditor WITH
  LOGIN
  NOINHERIT
  PASSWORD 'auditor123';

COMMENT ON ROLE auditor IS 'Роль для аудита';

ALTER ROLE auditor WITH BYPASSRLS; -- Позволяет игнорировать политику RLS
GRANT CONNECT ON DATABASE admin TO auditor;
GRANT USAGE ON SCHEMA app, ref, audit, stg TO auditor;

GRANT SELECT ON ALL TABLES IN SCHEMA app, ref, audit, stg TO auditor;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA app, ref, audit, stg TO auditor;

ALTER DEFAULT PRIVILEGES FOR ROLE app_owner IN SCHEMA app, ref, audit, stg
  GRANT SELECT ON TABLES TO auditor;

ALTER DEFAULT PRIVILEGES FOR ROLE app_owner IN SCHEMA app, ref, audit, stg
  GRANT SELECT ON SEQUENCES TO auditor;

-- ddl_admin
CREATE ROLE ddl_admin WITH
  LOGIN
  NOINHERIT
  PASSWORD 'ddl_admin123';

COMMENT ON ROLE ddl_admin IS 'Роль для выполнения DDL-операций';
GRANT app_owner TO ddl_admin;

-- dml_admin
CREATE ROLE dml_admin WITH
  LOGIN
  NOINHERIT
  PASSWORD 'dml_admin123';

COMMENT ON ROLE dml_admin IS 'Роль для выполнения DML-операций';

GRANT USAGE ON SCHEMA app, ref, stg, audit TO dml_admin;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA app, ref, stg TO dml_admin;
GRANT CONNECT ON DATABASE admin TO dml_admin;

ALTER DEFAULT PRIVILEGES FOR ROLE app_owner IN SCHEMA app, ref, stg
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO dml_admin;

ALTER DEFAULT PRIVILEGES FOR ROLE app_owner IN SCHEMA app, ref, stg
  GRANT USAGE ON SEQUENCES TO dml_admin;

-- security_admin
CREATE ROLE security_admin WITH
  LOGIN
  NOINHERIT
  NOCREATEDB
  CREATEROLE
  NOREPLICATION
  PASSWORD 'security_admin123';

COMMENT ON ROLE security_admin IS 'Роль для управления другими ролями';

GRANT CONNECT ON DATABASE admin TO security_admin;
GRANT USAGE ON SCHEMA app, ref, audit TO security_admin;

---------------------------------------------------------------------------------
-- объявление таблиц

SET ROLE app_owner;


-- ref

-- Статусы посылок
CREATE TABLE ref.parcel_statuses (
    id SERIAL PRIMARY KEY,
    status_name VARCHAR(50) NOT NULL UNIQUE
);
COMMENT ON TABLE ref.parcel_statuses IS 'Справочник: Статусы посылок';

-- Типы отделов
CREATE TABLE ref.department_types (
    id SERIAL PRIMARY KEY,
    type_name VARCHAR(100) NOT NULL UNIQUE
);
COMMENT ON TABLE ref.department_types IS 'Справочник: Типы отделов';

-- Должности
CREATE TABLE ref.positions (
    id SERIAL PRIMARY KEY,
    position_name VARCHAR(100) NOT NULL UNIQUE
);
COMMENT ON TABLE ref.positions IS 'Справочник: Должности сотрудников';

-- Статусы сотрудников
CREATE TABLE ref.employee_statuses (
    id SERIAL PRIMARY KEY,
    status_name VARCHAR(50) NOT NULL UNIQUE
);
COMMENT ON TABLE ref.employee_statuses IS 'Справочник: Статусы сотрудников';

--app
-- Клиенты
CREATE TABLE app.clients (
    id SERIAL PRIMARY KEY,
    last_name VARCHAR(100) NOT NULL,
    first_name VARCHAR(100) NOT NULL,
    middle_name VARCHAR(100),
    phone bytea NOT NULL,
    address text NOT NULL
);
COMMENT ON TABLE app.clients IS 'Данные клиентов';

-- Отделы
CREATE TABLE app.departments (
    id SERIAL PRIMARY KEY,
    department_type_id INT NOT NULL REFERENCES ref.department_types(id) ON DELETE RESTRICT,
    zip_code VARCHAR(10) NOT NULL,
    city VARCHAR(200) NOT NULL,
    address TEXT NOT NULL,
    UNIQUE (zip_code, address)
);
COMMENT ON TABLE app.departments IS 'Почтовые отделения, сортировочные центры, склады';



CREATE TABLE ref.segments (
    id SERIAL PRIMARY KEY,
    segment_name VARCHAR(255) NOT NULL UNIQUE,
    department_id INT UNIQUE REFERENCES app.departments(id) ON DELETE SET NULL
);
COMMENT ON TABLE ref.segments IS 'Справочник сегментов для изоляции данных RLS';


-- Сотрудники
CREATE TABLE app.employees (
    id SERIAL PRIMARY KEY,
    last_name VARCHAR(100) NOT NULL,
    first_name VARCHAR(100) NOT NULL,
    middle_name VARCHAR(100),
    department_id INT NOT NULL REFERENCES app.departments(id) ON DELETE RESTRICT,
    segment_id INT NOT NULL REFERENCES ref.segments(id) ON DELETE RESTRICT,
    position_id INT NOT NULL REFERENCES ref.positions(id) ON DELETE RESTRICT,
    status_id INT NOT NULL REFERENCES ref.employee_statuses(id) ON DELETE RESTRICT,
    login VARCHAR(50) NOT NULL UNIQUE,
    password_hash VARCHAR(100) NOT NULL
);
COMMENT ON TABLE app.employees IS 'Сотрудники';


-- Сегменты маршрутов
CREATE TABLE app.route_segments (
    id SERIAL PRIMARY KEY,
    departure_department_id INT NOT NULL REFERENCES app.departments(id) ON DELETE RESTRICT,
    arrival_department_id INT NOT NULL REFERENCES app.departments(id) ON DELETE RESTRICT,
    expected_time INTERVAL,
    CONSTRAINT check_different_departments CHECK (departure_department_id <> arrival_department_id)
);
COMMENT ON TABLE app.route_segments IS 'Сегменты маршрута между отделами';

-- Посылки
CREATE TABLE app.parcels (
    id SERIAL PRIMARY KEY,
    tracking_number VARCHAR(20) NOT NULL UNIQUE,
    sender_client_id INT NOT NULL REFERENCES app.clients(id) ON DELETE RESTRICT,
    recipient_client_id INT NOT NULL REFERENCES app.clients(id) ON DELETE RESTRICT,
    departure_department_id INT NOT NULL REFERENCES app.departments(id) ON DELETE RESTRICT,
    arrival_department_id INT NOT NULL REFERENCES app.departments(id) ON DELETE RESTRICT,
    weight_kg NUMERIC(10, 3) NOT NULL,
    declared_value NUMERIC(12, 2) NOT NULL DEFAULT 0,
    created_at TIMESTAMP NOT NULL DEFAULT now(),
    CONSTRAINT check_weight_positive CHECK (weight_kg > 0),
    CONSTRAINT check_declared_value_non_negative CHECK (declared_value >= 0)
);
COMMENT ON TABLE app.parcels IS 'Информация о посылках';


-- Перемещения посылок
CREATE TABLE app.parcel_movements (
    id SERIAL PRIMARY KEY,
    parcel_id INT NOT NULL REFERENCES app.parcels(id) ON DELETE CASCADE,
    segment_id INT NOT NULL REFERENCES app.route_segments(id) ON DELETE RESTRICT,
    employee_id INT NOT NULL REFERENCES app.employees(id) ON DELETE RESTRICT,
    rls_segment_id INT NOT NULL REFERENCES ref.segments(id) ON DELETE RESTRICT,
    status_id INT NOT NULL REFERENCES ref.parcel_statuses(id) ON DELETE RESTRICT,
    event_timestamp TIMESTAMP NOT NULL DEFAULT now()
);
COMMENT ON TABLE app.parcel_movements IS 'История перемещений посылок';


CREATE INDEX idx_employees_segment_id ON app.employees(segment_id);
CREATE INDEX idx_parcel_movements_rls_segment_id ON app.parcel_movements(rls_segment_id);
CREATE INDEX idx_parcel_movements_parcel_rls_segment ON app.parcel_movements(parcel_id, rls_segment_id);
CREATE INDEX idx_parcels_departure_department_id ON app.parcels(departure_department_id);
CREATE INDEX idx_parcels_arrival_department_id ON app.parcels(arrival_department_id);

RESET ROLE;

-----------------------------------------------------------------------------
-- Заполненеие справочников

INSERT INTO ref.parcel_statuses (status_name) VALUES
('Зарегистрировано'),
('Принято в отделении отправки'),
('В пути'),
('Прошло сортировку'),
('Прибыло в город назначения'),
('Передано курьеру для доставки'),
('Ожидает в пункте выдачи'),
('Вручено получателю'),
('Возвращено отправителю'),
('Утеряно');


INSERT INTO ref.department_types (type_name) VALUES
('Почтовое отделение'),
('Сортировочный центр'),
('Пункт выдачи заказов'),
('Склад');


INSERT INTO ref.positions (position_name) VALUES
('Оператор связи'),
('Сортировщик'),
('Начальник отделения'),
('Специалист по логистике'),
('Курьер'),
('Администратор БД');


INSERT INTO ref.employee_statuses (status_name) VALUES
('Активен'),
('В отпуске'),
('На больничном'),
('Уволен');


----------------------------------------------------------------------------------
-- Заполнение ключевых таблиц

SET session.encryption_key = 'ABOBA';

INSERT INTO app.departments (department_type_id, zip_code, city, address) VALUES
((SELECT id FROM ref.department_types WHERE type_name = 'Почтовое отделение'), '101000', 'Москва', 'ул. Мясницкая, д. 26'),
((SELECT id FROM ref.department_types WHERE type_name = 'Почтовое отделение'), '190000', 'Санкт-Петербург', 'ул. Почтамтская, д. 9'),
((SELECT id FROM ref.department_types WHERE type_name = 'Почтовое отделение'), '620014', 'Екатеринбург', 'просп. Ленина, д. 39'),
((SELECT id FROM ref.department_types WHERE type_name = 'Почтовое отделение'), '630099', 'Новосибирск', 'ул. Советская, д. 33'),
((SELECT id FROM ref.department_types WHERE type_name = 'Сортировочный центр'), '140961', 'Подольск', 'Московский АСЦ'),
((SELECT id FROM ref.department_types WHERE type_name = 'Сортировочный центр'), '630960', 'Новосибирск', 'Новосибирский МСЦ'),
((SELECT id FROM ref.department_types WHERE type_name = 'Пункт выдачи заказов'), '125009', 'Москва', 'ул. Тверская, д. 4'),
((SELECT id FROM ref.department_types WHERE type_name = 'Пункт выдачи заказов'), '191025', 'Санкт-Петербург', 'Невский просп., д. 71'),
((SELECT id FROM ref.department_types WHERE type_name = 'Почтовое отделение'), '420111', 'Казань', 'ул. Кремлевская, д. 8'),
((SELECT id FROM ref.department_types WHERE type_name = 'Сортировочный центр'), '420300', 'Казань', 'ЛПЦ Внуково-Казанский Приволжский');


INSERT INTO ref.segments (segment_name, department_id)
SELECT CONCAT(city, ', ', address), id FROM app.departments;


INSERT INTO app.clients (last_name, first_name, middle_name, phone, address) VALUES
('Иванов', 'Иван', 'Иванович', pgp_sym_encrypt('89161234567', current_setting('session.encryption_key')), pgp_sym_encrypt('г. Москва, ул. Ленина, д. 1, кв. 10', current_setting('session.encryption_key'))),
('Петрова', 'Анна', 'Сергеевна', pgp_sym_encrypt('89267654321', current_setting('session.encryption_key')), pgp_sym_encrypt('г. Москва, ул. Тверская, д. 5, кв. 25', current_setting('session.encryption_key'))),
('Сидоров', 'Петр', 'Николаевич', pgp_sym_encrypt('89031112233', current_setting('session.encryption_key')), pgp_sym_encrypt('г. Санкт-Петербург, Невский пр-т, д. 100, кв. 1', current_setting('session.encryption_key'))),
('Смирнова', 'Ольга', 'Владимировна', pgp_sym_encrypt('89119876543', current_setting('session.encryption_key')), pgp_sym_encrypt('г. Санкт-Петербург, ул. Садовая, д. 22, кв. 44', current_setting('session.encryption_key'))),
('Кузнецов', 'Дмитрий', 'Алексеевич', pgp_sym_encrypt('89995556677', current_setting('session.encryption_key')), pgp_sym_encrypt('г. Екатеринбург, ул. Малышева, д. 80, кв. 12', current_setting('session.encryption_key'))),
('Васильева', 'Екатерина', 'Игоревна', pgp_sym_encrypt('89823334455', current_setting('session.encryption_key')), pgp_sym_encrypt('г. Екатеринбург, ул. 8 Марта, д. 5, кв. 3', current_setting('session.encryption_key'))),
('Попов', 'Михаил', 'Юрьевич', pgp_sym_encrypt('89051239876', current_setting('session.encryption_key')), pgp_sym_encrypt('г. Новосибирск, Красный пр-т, д. 65, кв. 56', current_setting('session.encryption_key'))),
('Лебедева', 'Мария', 'Павловна', pgp_sym_encrypt('89135551122', current_setting('session.encryption_key')), pgp_sym_encrypt('г. Новосибирск, ул. Вокзальная магистраль, д. 1, кв. 8', current_setting('session.encryption_key'))),
('Козлов', 'Артем', 'Викторович', pgp_sym_encrypt('89257778899', current_setting('session.encryption_key')), pgp_sym_encrypt('г. Казань, ул. Баумана, д. 40, кв. 2', current_setting('session.encryption_key'))),
('Новикова', 'Алиса', 'Денисовна', pgp_sym_encrypt('89172345678', current_setting('session.encryption_key')), pgp_sym_encrypt('г. Казань, ул. Петербургская, д. 9, кв. 7', current_setting('session.encryption_key'))),
('Федоров', 'Роман', 'Григорьевич', pgp_sym_encrypt('89261122334', current_setting('session.encryption_key')), pgp_sym_encrypt('г. Москва, ул. Арбат, д. 15, кв. 99', current_setting('session.encryption_key')));


INSERT INTO app.employees (last_name, first_name, department_id, segment_id, position_id, status_id, login, password_hash) VALUES
('Максимова', 'Марина', 1, 1, 1, 1, 'marina.m', crypt('password123', gen_salt('bf'))),
('Соколов', 'Сергей', 1, 1, 3, 1, 'sergey.s', crypt('password123', gen_salt('bf'))),
('Волков', 'Владимир', 2, 2, 1, 1, 'vladimir.v', crypt('password123', gen_salt('bf'))),
('Зайцева', 'Дарья', 5, 5, 2, 1, 'daria.z', crypt('password123', gen_salt('bf'))),
('Орлов', 'Олег', 5, 5, 4, 1, 'oleg.o', crypt('password123', gen_salt('bf'))),
('Белова', 'Виктория', 3, 3, 1, 1, 'victoria.b', crypt('password123', gen_salt('bf'))),
('Давыдов', 'Денис', 4, 4, 1, 1, 'denis.d', crypt('password123', gen_salt('bf'))),
('Тихонова', 'Татьяна', 6, 6, 2, 1, 'tatiana.t', crypt('password123', gen_salt('bf'))),
('Степанов', 'Станислав', 9, 9, 1, 1, 'stanislav.s', crypt('password123', gen_salt('bf'))),
('Романова', 'Регина', 10, 10, 2, 1, 'regina.r', crypt('password123', gen_salt('bf')));

INSERT INTO app.route_segments (departure_department_id, arrival_department_id, expected_time) VALUES
-- Москва -> Подольск СЦ
((SELECT id FROM app.departments WHERE zip_code = '101000'), (SELECT id FROM app.departments WHERE zip_code = '140961'), '8 hours'),
-- Подольск СЦ -> СПб
((SELECT id FROM app.departments WHERE zip_code = '140961'), (SELECT id FROM app.departments WHERE zip_code = '190000'), '1 day'),
-- СПб -> Подольск СЦ
((SELECT id FROM app.departments WHERE zip_code = '190000'), (SELECT id FROM app.departments WHERE zip_code = '140961'), '1 day'),
-- Подольск СЦ -> Новосибирск СЦ
((SELECT id FROM app.departments WHERE zip_code = '140961'), (SELECT id FROM app.departments WHERE zip_code = '630960'), '3 days'),
-- Новосибирск СЦ -> Новосибирск Отделение
((SELECT id FROM app.departments WHERE zip_code = '630960'), (SELECT id FROM app.departments WHERE zip_code = '630099'), '6 hours'),
-- Новосибирск Отделение -> Новосибирск СЦ
((SELECT id FROM app.departments WHERE zip_code = '630099'), (SELECT id FROM app.departments WHERE zip_code = '630960'), '6 hours'),
-- Подольск СЦ -> Екатеринбург
((SELECT id FROM app.departments WHERE zip_code = '140961'), (SELECT id FROM app.departments WHERE zip_code = '620014'), '2 days'),
-- Екатеринбург -> Подольск СЦ
((SELECT id FROM app.departments WHERE zip_code = '620014'), (SELECT id FROM app.departments WHERE zip_code = '140961'), '2 days'),
-- Подольск СЦ -> Казань СЦ
((SELECT id FROM app.departments WHERE zip_code = '140961'), (SELECT id FROM app.departments WHERE zip_code = '420300'), '18 hours'),
-- Казань СЦ -> Казань Отделение
((SELECT id FROM app.departments WHERE zip_code = '420300'), (SELECT id FROM app.departments WHERE zip_code = '420111'), '4 hours');


INSERT INTO app.parcels (tracking_number, sender_client_id, recipient_client_id, departure_department_id, arrival_department_id, weight_kg, declared_value, created_at) VALUES
('RR000000001RU', 1, 3, 1, 2, 1.5, 1000, '2025-01-10 10:00:00'), 
('RR000000002RU', 4, 1, 2, 1, 0.8, 500,  '2025-02-15 12:30:00'),
('RR000000003RU', 2, 7, 1, 4, 5.2, 15000, '2025-03-20 09:15:00'), 
('RR000000004RU', 8, 5, 4, 3, 2.1, 2500,  '2025-04-05 14:00:00'),
('RR000000005RU', 6, 9, 3, 9, 0.5, 300,   '2025-05-12 11:45:00'), 
('RR000000006RU', 10, 1, 9, 1, 10.0, 50000, '2025-06-25 16:20:00'),
('RR000000007RU', 1, 8, 1, 4, 3.0, 7000,  '2025-07-30 08:10:00'), 
('RR000000008RU', 3, 6, 2, 3, 1.2, 1200,  '2025-08-14 13:50:00'),
('RR000000009RU', 5, 2, 3, 1, 0.9, 900,   '2025-09-02 17:05:00'), 
('RR000000010RU', 7, 10, 4, 9, 4.5, 4500, '2025-10-18 10:30:00');

INSERT INTO app.parcel_movements (parcel_id, segment_id, employee_id, rls_segment_id, status_id, event_timestamp) VALUES
(1, 1, 1, (SELECT segment_id FROM app.employees WHERE id = 1), 1, now() - interval '3 days'),
(1, 1, 1, (SELECT segment_id FROM app.employees WHERE id = 1), 2, now() - interval '2 days 12 hours'),
(1, 2, 4, (SELECT segment_id FROM app.employees WHERE id = 4), 3, now() - interval '2 days'),
(1, 2, 5, (SELECT segment_id FROM app.employees WHERE id = 5), 5, now() - interval '1 day'),
(3, 1, 2, (SELECT segment_id FROM app.employees WHERE id = 2), 1, now() - interval '5 days'),
(3, 1, 1, (SELECT segment_id FROM app.employees WHERE id = 1), 2, now() - interval '5 days'),
(3, 4, 4, (SELECT segment_id FROM app.employees WHERE id = 4), 3, now() - interval '4 days'),
(3, 4, 8, (SELECT segment_id FROM app.employees WHERE id = 8), 4, now() - interval '2 days'),
(3, 5, 8, (SELECT segment_id FROM app.employees WHERE id = 8), 5, now() - interval '1 day'),
(5, 8, 6, (SELECT segment_id FROM app.employees WHERE id = 6), 1, now() - interval '4 days'),
(5, 8, 6, (SELECT segment_id FROM app.employees WHERE id = 6), 2, now() - interval '4 days'),
(5, 9, 5, (SELECT segment_id FROM app.employees WHERE id = 5), 3, now() - interval '2 days'),
(5, 10, 10, (SELECT segment_id FROM app.employees WHERE id = 10), 5, now() - interval '1 day');


GRANT CREATE ON SCHEMA audit TO auditor;
SET ROLE auditor;

CREATE TABLE audit.login_log (
    log_id BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
    login_time TIMESTAMPTZ NOT NULL DEFAULT now(),
    session_user_name TEXT NOT NULL,
    current_user_name TEXT NOT NULL,
    client_ip INET
);
COMMENT ON TABLE audit.login_log IS 'Журнал входов пользователей в систему';


CREATE OR REPLACE FUNCTION audit.log_user_connection()
RETURNS event_trigger AS $$
BEGIN
    INSERT INTO audit.login_log (session_user_name, current_user_name, client_ip)
    VALUES (session_user, current_user, inet_client_addr()); 
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

RESET ROLE;

CREATE EVENT TRIGGER login_trigger ON login
  EXECUTE FUNCTION audit.log_user_connection();

REVOKE ALL ON audit.login_log FROM PUBLIC;
GRANT EXECUTE ON FUNCTION audit.log_user_connection() TO app_reader, app_writer, ddl_admin, dml_admin, security_admin;

------------------------------------------------
--Включение RLS
-- ENABLE ROW LEVEL SECURITY - активирует RLS.
-- FORCE ROW LEVEL SECURITY - применяет RLS даже для владельца таблицы.

ALTER TABLE app.employees ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.employees NO FORCE ROW LEVEL SECURITY;

ALTER TABLE app.parcels ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.parcels FORCE ROW LEVEL SECURITY;

ALTER TABLE app.parcel_movements ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.parcel_movements FORCE ROW LEVEL SECURITY;

ALTER TABLE app.clients ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.clients FORCE ROW LEVEL SECURITY;

SET ROLE app_owner;

--Создание функции для идентификации сегмента пользователя

CREATE OR REPLACE FUNCTION app.get_current_segment_id()
RETURNS INT AS $$
DECLARE
    segment_id INT;
    val text;
BEGIN
    -- Считываем как текст, чтобы избежать ошибки конвертации сразу
    BEGIN
        val := current_setting('app.current_segment_id', true);
        
        -- Если пустая строка или NULL -> NULL, иначе -> INT
        IF val = '' OR val IS NULL THEN
            segment_id := NULL;
        ELSE
            segment_id := val::INT;
        END IF;
    EXCEPTION WHEN OTHERS THEN
        -- При любой ошибке считаем, что контекста нет
        segment_id := NULL;
    END;
    
    RETURN segment_id;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

COMMENT ON FUNCTION app.get_current_segment_id() IS
'Возвращает ID сегмента для текущего пользователя из переменной сессии';


--Политика для таблицы Перемещений
CREATE POLICY parcel_movements_isolation_policy ON app.parcel_movements
FOR ALL
USING (
    current_user = 'auditor' OR
    rls_segment_id = app.get_current_segment_id()
)
WITH CHECK (
    current_user = 'auditor' OR
    rls_segment_id = app.get_current_segment_id()
);

--Политика для таблицы Посылок
CREATE POLICY parcels_visibility_policy ON app.parcels
FOR ALL
USING (
  current_user = 'auditor' OR 
    (
        EXISTS (
            SELECT 1 FROM ref.segments s
            WHERE s.id = app.get_current_segment_id() AND s.department_id = departure_department_id
        )
    ) OR (
        EXISTS (
            SELECT 1 FROM ref.segments s
            WHERE s.id = app.get_current_segment_id() AND s.department_id = arrival_department_id
        )
    )
)
WITH CHECK (
    current_user = 'auditor' OR
    EXISTS (
        SELECT 1 FROM ref.segments s
        WHERE s.id = app.get_current_segment_id() AND s.department_id = departure_department_id
    )
);

--Политика для таблицы Клиентов
CREATE POLICY clients_visibility_policy ON app.clients
FOR SELECT
USING (
    current_user = 'auditor' OR
    EXISTS (
        SELECT 1 FROM app.parcels p
        WHERE p.sender_client_id = id OR p.recipient_client_id = id
    )
);

--Политика для таблицы Сотрудников
CREATE POLICY employees_visibility_policy ON app.employees
FOR SELECT
USING (
  current_user = 'auditor' OR
    (segment_id = app.get_current_segment_id())
    OR
    (EXISTS (
        SELECT 1
        FROM app.parcel_movements pm
        JOIN app.parcels p ON pm.parcel_id = p.id
        WHERE pm.employee_id = employees.id
    ))
);


---------------------------------------------------------------------------------

SET ROLE app_owner;

CREATE OR REPLACE FUNCTION app.set_session_ctx(p_actor_id INT, p_segment_id INT)
RETURNS VOID AS $$
DECLARE
    is_authorized BOOLEAN;
BEGIN
    SET LOCAL row_security = off;
    SELECT EXISTS (
        SELECT 1
        FROM app.employees
        WHERE id = p_actor_id
          AND login = session_user
          AND segment_id = p_segment_id
    ) INTO is_authorized;
    IF is_authorized THEN
        PERFORM set_config('app.current_segment_id', p_segment_id::TEXT, true);
        PERFORM set_config('app.current_actor_id', p_actor_id::TEXT, true);
    ELSE
        RAISE EXCEPTION 'Authorization failed: User "%" is not permitted to act as actor ID % in segment ID %.',
            session_user, p_actor_id, p_segment_id;
    END IF;

END;
$$ LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = app, ref, audit, public;

GRANT EXECUTE ON FUNCTION app.set_session_ctx(INT, INT) TO app_writer, app_reader;

RESET ROLE;

SELECT 'Function app.set_session_ctx has been patched for FORCE RLS conflict.' as status;


-------------------------------------------------------------------------
CREATE ROLE "marina.m" WITH LOGIN PASSWORD 'password123';
CREATE ROLE "victoria.b" WITH LOGIN PASSWORD 'password123';

GRANT app_writer TO "marina.m";
GRANT app_writer TO "victoria.b";
--------------------------------------------------------------------------

RESET ROLE;


----------------------------------------------------------------------------

SET ROLE app_owner;

CREATE OR REPLACE VIEW app.v_parcels_lightweight AS
SELECT 
    id,
    tracking_number,
    departure_department_id,
    arrival_department_id,
    weight_kg,
    created_at
FROM app.parcels
WHERE weight_kg <= 10.0
WITH CHECK OPTION;

COMMENT ON VIEW app.v_parcels_lightweight IS 'Представление для операторов: только посылки до 10кг.';


GRANT SELECT, UPDATE, INSERT ON app.v_parcels_lightweight TO app_writer;
GRANT SELECT ON app.v_parcels_lightweight TO app_reader;
-------------------------------------

CREATE OR REPLACE VIEW app.v_dept_financial_stats 
WITH (security_barrier = true)
AS
SELECT 
    d.city || ', ' || d.address AS department_name,
    COUNT(p.id) AS parcels_count,
    COALESCE(SUM(p.declared_value), 0) AS total_declared_value
FROM app.parcels p
JOIN app.departments d ON p.departure_department_id = d.id
GROUP BY d.city, d.address;

COMMENT ON VIEW app.v_dept_financial_stats IS 'Финансовая статистика по отделениям.';

GRANT SELECT ON app.v_dept_financial_stats TO app_reader;
GRANT SELECT ON app.v_dept_financial_stats TO app_writer;
GRANT SELECT ON app.v_dept_financial_stats TO auditor;


SELECT 'Step 1: Secure Views created successfully' as status;
--------------------------------------------------------------------------

--создание таблицы аудита
CREATE TABLE IF NOT EXISTS audit.row_change_log (
    log_id BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
    table_schema TEXT NOT NULL,
    table_name TEXT NOT NULL,
    record_id TEXT,            
    operation TEXT NOT NULL,    
    changed_by TEXT NOT NULL DEFAULT session_user, 
    change_time TIMESTAMPTZ NOT NULL DEFAULT now(), 
    old_data JSONB,              
    new_data JSONB               
);

COMMENT ON TABLE audit.row_change_log IS 'Аудит изменений данных с маскированием чувствительных полей';

REVOKE ALL ON audit.row_change_log FROM PUBLIC;
GRANT SELECT ON audit.row_change_log TO auditor; 

--Создание таблицы архива логов
CREATE TABLE IF NOT EXISTS audit.row_change_log_archive (
    LIKE audit.row_change_log INCLUDING ALL
);

COMMENT ON TABLE audit.row_change_log_archive IS 'Архив журнала изменений (старые записи)';

REVOKE ALL ON audit.row_change_log_archive FROM PUBLIC;
GRANT SELECT ON audit.row_change_log_archive TO auditor;

-------------------------------------------------------------------------------
--Триггерная функция
CREATE OR REPLACE FUNCTION audit.trg_log_changes()
RETURNS TRIGGER AS $$
DECLARE
    v_old_data JSONB;
    v_new_data JSONB;
    v_record_id TEXT;
BEGIN
    IF TG_OP = 'DELETE' THEN
        v_record_id := OLD.id::TEXT;
        v_old_data := to_jsonb(OLD);
        v_new_data := NULL;
    ELSE
        v_record_id := NEW.id::TEXT;
        v_old_data := to_jsonb(OLD);
        v_new_data := to_jsonb(NEW);
    END IF;
  
    IF TG_TABLE_NAME = 'clients' THEN
        IF v_old_data IS NOT NULL THEN
            v_old_data := v_old_data || '{"phone": "***MASKED***", "address": "***MASKED***"}';
        END IF;
        IF v_new_data IS NOT NULL THEN
            v_new_data := v_new_data || '{"phone": "***MASKED***", "address": "***MASKED***"}';
        END IF;
    END IF;
    IF TG_TABLE_NAME = 'employees' THEN
        IF v_old_data IS NOT NULL THEN
            v_old_data := v_old_data - 'password_hash';
        END IF;
        IF v_new_data IS NOT NULL THEN
            v_new_data := v_new_data - 'password_hash';
        END IF;
    END IF;
    INSERT INTO audit.row_change_log (
        table_schema, table_name, record_id, operation, old_data, new_data
    )
    VALUES (
        TG_TABLE_SCHEMA, TG_TABLE_NAME, v_record_id, TG_OP, v_old_data, v_new_data
    );

    RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

--Назначение триггерной ф-ции
CREATE TRIGGER audit_parcels_changes
AFTER UPDATE OR DELETE ON app.parcels
FOR EACH ROW EXECUTE FUNCTION audit.trg_log_changes();

CREATE TRIGGER audit_clients_changes
AFTER UPDATE OR DELETE ON app.clients
FOR EACH ROW EXECUTE FUNCTION audit.trg_log_changes();

CREATE TRIGGER audit_employees_changes
AFTER UPDATE OR DELETE ON app.employees
FOR EACH ROW EXECUTE FUNCTION audit.trg_log_changes();


RESET ROLE;


-------------------------------------------------------------
CREATE OR REPLACE FUNCTION audit.backup_audit_logs(days_interval INT)
RETURNS TEXT AS $$
DECLARE
    v_moved_count INT;
BEGIN
    
    WITH moved_rows AS (
        DELETE FROM audit.row_change_log
        WHERE change_time < (now() - (days_interval || ' days')::INTERVAL)
        RETURNING * -- Возвращаем удаленные строки для вставки
    )
    INSERT INTO audit.row_change_log_archive
    SELECT * FROM moved_rows;

    -- Получаем количество обработанных строк
    GET DIAGNOSTICS v_moved_count = ROW_COUNT;

    RETURN format('Успешно перенесено %s записей старше %s дней.', v_moved_count, days_interval);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION audit.backup_audit_logs(INT) IS 'Переносит старые логи в архив и удаляет их из основной таблицы';
--------------------------------------------------------------
--Таблица логов временных привилегий
CREATE TABLE audit.temp_access_log (
    request_id BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
    request_time TIMESTAMPTZ NOT NULL DEFAULT now(), 
    caller_role TEXT NOT NULL,                       
    operation TEXT NOT NULL,                         
    expires_at TIMESTAMPTZ NOT NULL                  
);
COMMENT ON TABLE audit.temp_access_log IS 'История запросов временных привилегий';

REVOKE ALL ON audit.temp_access_log FROM PUBLIC;
GRANT SELECT ON audit.temp_access_log TO auditor;

---------------------------------------------------------
-- Триггер для проверки JIT привилегии при удалении посылок
CREATE OR REPLACE FUNCTION app.check_jit_privilege()
RETURNS TRIGGER AS $$
DECLARE
    v_expires_str TEXT;
    v_operation_str TEXT;
BEGIN
    v_expires_str := current_setting('app.jit_expires_at', true);
    v_operation_str := current_setting('app.jit_operation', true);

    IF v_expires_str IS NULL OR v_operation_str IS NULL THEN
        RAISE EXCEPTION 'JIT Error: Нет активной временной привилегии. Запросите доступ через request_temp_privilege().';
    END IF;

    IF v_operation_str <> 'DELETE_PARCEL' THEN
         RAISE EXCEPTION 'JIT Error: Текущая привилегия выдана для другой операции (%).', v_operation_str;
    END IF;

    IF v_expires_str::TIMESTAMPTZ < now() THEN
        RAISE EXCEPTION 'JIT Error: Срок действия временной привилегии истек (был до %).', v_expires_str;
    END IF;

    RETURN OLD;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_jit_guard_parcels ON app.parcels;
CREATE TRIGGER trg_jit_guard_parcels
BEFORE DELETE ON app.parcels
FOR EACH ROW EXECUTE FUNCTION app.check_jit_privilege();
---------------------------------------------------------
-- Функция запроса временной привилегии
CREATE OR REPLACE FUNCTION app.request_temp_privilege(p_operation TEXT, p_duration_min INT)
RETURNS TEXT AS $$
DECLARE
    v_expires_at TIMESTAMPTZ;
BEGIN
    IF NOT pg_has_role(session_user, 'app_writer', 'MEMBER') THEN
        RAISE EXCEPTION 'Access Denied: Запрашивать временные права может только роль app_writer (Ваша роль: %)', session_user;
    END IF;
    IF p_operation <> 'DELETE_PARCEL' THEN
        RAISE EXCEPTION 'Операция % недоступна для JIT-запроса.', p_operation;
    END IF;
    v_expires_at := now() + (p_duration_min || ' minutes')::INTERVAL;
    INSERT INTO audit.temp_access_log (caller_role, operation, expires_at)
    VALUES (session_user, p_operation, v_expires_at);
    --Установка переменных сессии
    PERFORM set_config('app.jit_expires_at', v_expires_at::TEXT, false);
    PERFORM set_config('app.jit_operation', p_operation, false);

    RETURN format('Привилегия %s выдана до %s', p_operation, v_expires_at);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION app.request_temp_privilege(TEXT, INT) TO app_writer;
GRANT DELETE ON app.parcels TO app_writer;

---------------------------------------------------------
--Патчи
SET ROLE app_owner;

SET row_security = on;
GRANT EXECUTE ON FUNCTION app.set_session_ctx(INT, INT) TO app_writer, app_reader;

RESET ROLE;


CREATE OR REPLACE FUNCTION app.set_session_ctx(p_actor_id INT, p_segment_id INT)
RETURNS VOID
SECURITY DEFINER
SET search_path = app, ref, audit, public
SET row_security = off
AS $$
DECLARE
    is_authorized BOOLEAN;
    v_real_user TEXT;
BEGIN
    v_real_user := session_user; 

    SELECT EXISTS (
        SELECT 1
        FROM app.employees
        WHERE id = p_actor_id
          AND (login = v_real_user OR v_real_user IN ('app_owner', 'postgres', 'admin'))
          AND segment_id = p_segment_id
    ) INTO is_authorized;

    IF is_authorized THEN
        PERFORM set_config('app.current_segment_id', p_segment_id::TEXT, true);
        PERFORM set_config('app.current_actor_id', p_actor_id::TEXT, true);
    ELSE
        RAISE EXCEPTION 'Authorization failed: User "%" is not permitted to act as actor ID % in segment ID %.',
            v_real_user, p_actor_id, p_segment_id;
    END IF;
END;
$$ LANGUAGE plpgsql;
---------------------------------------------------------


-- Сообщаем об успешном завершении скрипта
SELECT 'Initial setup script completed successfully' AS status;

