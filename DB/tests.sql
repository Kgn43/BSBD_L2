-- ===== 0. Подготовка ролей и тестовых пользователей =====
DO $$
BEGIN
-- === Создаем тестовых пользователей (логин-роли) ===
    CREATE ROLE login_reader WITH LOGIN PASSWORD 'reader_password';
    GRANT app_reader TO login_reader;

    CREATE ROLE login_writer WITH LOGIN PASSWORD 'writer_password';
    GRANT app_writer TO login_writer;

    CREATE ROLE login_auditor WITH LOGIN PASSWORD 'auditor_password';
    GRANT auditor TO login_auditor;

    CREATE ROLE login_ddl WITH LOGIN PASSWORD 'ddl_password';
    GRANT ddl_admin TO login_ddl;

    CREATE ROLE login_dml WITH LOGIN PASSWORD 'dml_password';
    GRANT dml_admin TO login_dml;

    CREATE ROLE login_security WITH LOGIN PASSWORD 'security_password';
    GRANT security_admin TO login_security;
END $$;


-- =================================================================
-- СЦЕНАРИЙ 1: Роль app_reader
-- =================================================================
-- Тест 1.1: Успешное чтение
DO $$ BEGIN 
    SET ROLE login_reader; 
    PERFORM id FROM app.parcels LIMIT 1; 
    RAISE INFO '[OK] app_reader: Успешно прочитал данные из app.parcels.'; 
    RESET ROLE; 
    EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION '[FAIL] app_reader: Не смог прочитать данные.'; 
END $$;

-- Тест 1.2: Попытка изменения (UPDATE, ЗАПРЕЩЕНО)
DO $$ BEGIN 
    SET ROLE login_reader; 
    UPDATE app.parcels 
    SET weight_kg = 999 
    WHERE id=1; 
    RAISE EXCEPTION '[FAIL] app_reader: Смог обновить данные!'; 
    RESET ROLE; 
    EXCEPTION WHEN insufficient_privilege 
    THEN RAISE INFO '[OK] app_reader: Попытка UPDATE провалилась, как и ожидалось.'; 
    RESET ROLE; 
END $$;

-- =================================================================
-- СЦЕНАРИЙ 2: Роль app_writer
-- =================================================================
-- Тест 2.1: Успешное изменение (UPDATE)
DO $$ BEGIN 
    SET ROLE login_writer; 
    UPDATE app.parcels 
    SET weight_kg = 1.5 
    WHERE id=1; 
    RAISE INFO '[OK] app_writer: Успешно обновил данные в app.parcels.'; 
    RESET ROLE; 
    EXCEPTION WHEN OTHERS 
    THEN RAISE EXCEPTION '[FAIL] app_writer: Не смог обновить данные.'; 
END $$;

-- Тест 2.2: Попытка массового удаления (TRUNCATE, ЗАПРЕЩЕНО)
DO $$ BEGIN 
    SET ROLE login_writer; 
    TRUNCATE app.parcels; 
    RAISE EXCEPTION '[FAIL] app_writer: Смог выполнить TRUNCATE!'; 
    RESET ROLE; 
    EXCEPTION WHEN insufficient_privilege 
    THEN RAISE INFO '[OK] app_writer: Попытка TRUNCATE провалилась, как и ожидалось.'; 
    RESET ROLE; 
END $$;

-- =================================================================
-- СЦЕНАРИЙ 3: Роль auditor
-- =================================================================
-- Тест 3.1: Успешное чтение из схемы audit
DO $$ BEGIN
    CREATE VIEW audit.test_log_view AS SELECT 'test action' as action;
    GRANT SELECT ON audit.test_log_view TO auditor;
    SET ROLE login_auditor;
    PERFORM action FROM audit.test_log_view;
    RAISE INFO '[OK] auditor: Успешно прочитал данные из VIEW в схеме audit.';
    RESET ROLE;
    DROP VIEW audit.test_log_view;
END $$;

-- Тест 3.2: Попытка чтения из схемы app
DO $$ 
    BEGIN SET ROLE login_auditor; 
    PERFORM id FROM app.parcels LIMIT 1; 
    RAISE INFO '[OK] auditor: Смог прочитать данные из app.parcels.'; 
    RESET ROLE; 
    EXCEPTION WHEN insufficient_privilege 
    THEN RAISE EXCEPTION '[FAIL] auditor: Попытка чтения из app.parcels провалилась.'; 
    RESET ROLE; 
END $$;


GRANT USAGE, CREATE ON SCHEMA app, ref, stg TO ddl_admin;
-- =================================================================
-- СЦЕНАРИЙ 4: Роль ddl_admin
-- =================================================================
-- Тест 4.1: Успешное изменение структуры (ALTER TABLE)
DO $$ BEGIN
    SET ROLE login_ddl;
	SET ROLE app_owner;
    ALTER TABLE app.parcels ADD COLUMN temp_test_col TEXT;
    RAISE INFO '[OK] ddl_admin: Успешно добавил колонку в app.parcels.';
    ALTER TABLE app.parcels DROP COLUMN temp_test_col;
    RAISE INFO '[OK] ddl_admin: Успешно удалил тестовую колонку.';
    RESET ROLE;
END $$;

-- =================================================================
-- СЦЕНАРИЙ 5: Роль dml_admin (Массовые операции с данными)
-- =================================================================
-- Тест 5.1: Успешное выполнение TRUNCATE в схеме stg
DO $$ BEGIN
    CREATE TABLE stg.temp_for_truncate (id int);
    GRANT ALL ON stg.temp_for_truncate TO dml_admin; -- Даем права на таблицу
    SET ROLE login_dml;
    TRUNCATE stg.temp_for_truncate;
    RAISE INFO '[OK] dml_admin: Успешно выполнил TRUNCATE в схеме stg.';
    RESET ROLE;
    DROP TABLE stg.temp_for_truncate;
END $$;

-- =================================================================
-- СЦЕНАРИЙ 6: Роль security_admin
-- =================================================================
-- Тест 6.1: Успешная попытка создания роли
DO $$ 
DECLARE
    role_name TEXT := 'test_new_role_security_admin_can';
BEGIN
    SET ROLE security_admin;
    EXECUTE 'CREATE ROLE ' || quote_ident(role_name);
    RAISE INFO '[OK] security_admin: Успешно создал роль "%".', role_name;
    EXECUTE 'DROP ROLE ' || quote_ident(role_name); 
    RAISE INFO '[OK] security_admin: Успешно удалил роль "%".', role_name;
EXCEPTION
    WHEN insufficient_privilege THEN
        RAISE EXCEPTION '[FAIL] security_admin: Получил ошибку "insufficient_privilege" при попытке создать роль. Необходимо право CREATEROLE.';
    WHEN OTHERS THEN
        RAISE EXCEPTION '[FAIL] security_admin: Получил неожиданную ошибку при попытке создать/удалить роль: %', SQLERRM;
        
END $$;
RESET ROLE;


-- ===== Очистка =====
DROP ROLE login_reader, login_writer, login_auditor, login_ddl, login_dml, login_security;