DO $$ BEGIN 
IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'login_reader') THEN CREATE ROLE login_reader WITH LOGIN PASSWORD 'reader_password'; GRANT app_reader TO login_reader; END IF;
IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'login_writer') THEN CREATE ROLE login_writer WITH LOGIN PASSWORD 'writer_password'; GRANT app_writer TO login_writer; END IF;
END $$;
COMMIT;

-- Кейс 1 (Позитив): app_reader может читать разрешенную ТАБЛИЦУ app.parcels
DO $$ 
BEGIN 
    SET ROLE login_reader; 
    PERFORM tracking_number 
    FROM app.parcels LIMIT 1; 
    RAISE INFO '[OK] Тест 1: app_reader УСПЕШНО прочитал данные из app.parcels.'; 
    RESET ROLE; 
    EXCEPTION 
    WHEN OTHERS 
        THEN RAISE EXCEPTION '[FAIL] Тест 1: app_reader не смог прочитать из разрешенной таблицы.'; 
END $$;

-- Кейс 2 (Негатив): app_reader не может писать в схему audit
DO $$ 
BEGIN 
    SET ROLE login_reader; 
    INSERT INTO audit.login_log(session_user_name, current_user_name) 
    VALUES ('hacker', 'hacker'); 
    RAISE EXCEPTION '[FAIL] Тест 2: app_reader смог вставить данные в audit.login_log!'; 
    RESET ROLE; 
    EXCEPTION WHEN insufficient_privilege 
        THEN RAISE INFO '[OK] Тест 2: Попытка app_reader выполнить DML в схеме audit ПРОВАЛИЛАСЬ, как и ожидалось.'; 
        RESET ROLE; 
END $$;

-- Кейс 3 (Негатив): app_reader не может вызвать register_parcel
DO $$ 
BEGIN 
    SET ROLE login_reader; 
    PERFORM app.register_parcel('marina.m', 'A','A','1','1','B','B','2','2',1,2,1.0,1); 
    RAISE EXCEPTION '[FAIL] Тест 3: app_reader смог вызвать register_parcel!'; 
    RESET ROLE; 
    EXCEPTION WHEN insufficient_privilege 
        THEN RAISE INFO '[OK] Тест 3: Попытка app_reader вызвать register_parcel ПРОВАЛИЛАСЬ, как и ожидалось.'; 
        RESET ROLE; 
END $$;

-- Кейс 4 (Позитив): app_writer успешно вызывает register_parcel с валидными данными
BEGIN;
SET CONSTRAINTS ALL IMMEDIATE;
DO $$
DECLARE
    v_track TEXT;
BEGIN
    SET ROLE login_writer;
    v_track := app.register_parcel('marina.m', 'Тестов', 'Тест', '+79001112233', 'г. Тестовый', 'Петров', 'Петр', '+79004445566', 'г. Петровский', 1, 2, 1.0, 100);
    RAISE INFO '[OK] Тест 4: app_writer УСПЕШНО зарегистрировал посылку (Трек: %).', v_track;
    RESET ROLE;
END $$;
ROLLBACK;

-- Кейс 5 (Негатив): app_writer вызывает register_parcel с невалидными данными (отрицательный вес)
DO $$ 
BEGIN 
    SET ROLE login_writer; 
    PERFORM app.register_parcel('marina.m', 'A','A','1','1','B','B','2','2',1,2,-1.0,1); 
    RAISE EXCEPTION '[FAIL] Тест 5: register_parcel отработала с невалидными данными!'; 
    RESET ROLE; 
    EXCEPTION WHEN raise_exception 
        THEN RAISE INFO '[OK] Тест 5: вызов register_parcel с невалидными данными ПРОВАЛИЛСЯ, как и ожидалось.'; 
        RESET ROLE; 
END $$;


-- Кейс 6 (Позитив): app_writer успешно вызывает change_parcel_status с валидными данными
BEGIN;
DO $$ 
BEGIN 
    SET ROLE login_writer; 
    PERFORM app.change_parcel_status('RR000000001RU', 'В пути', 'marina.m', 1); 
    RAISE INFO '[OK] Тест 6: app_writer УСПЕШНО изменил статус посылки.'; 
    RESET ROLE; 
END $$;
ROLLBACK;

-- Кейс 7 (Негатив): app_writer вызывает change_parcel_status с несуществующим трекинг-номером
DO $$ 
BEGIN 
    SET ROLE login_writer; 
    PERFORM app.change_parcel_status('FAKE123', 'В пути', 'marina.m', 1); 
    RAISE EXCEPTION '[FAIL] Тест 7: change_parcel_status отработала с неверным трекингом!'; 
    RESET ROLE; 
    EXCEPTION WHEN raise_exception 
        THEN RAISE INFO '[OK] Тест 7: вызов change_parcel_status с неверным трекингом ПРОВАЛИЛСЯ, как и ожидалось.'; 
        RESET ROLE; 
END $$;

-- Кейс 8 (Негатив): app_writer вызывает change_parcel_status с несуществующим ID сегмента
DO $$ 
BEGIN 
    SET ROLE login_writer; 
    PERFORM app.change_parcel_status('RR000000001RU', 'В пути', 'marina.m', 9999); 
    RAISE EXCEPTION '[FAIL] Тест 8: change_parcel_status отработала с неверным сегментом!'; 
    RESET ROLE; 
    EXCEPTION WHEN raise_exception 
        THEN RAISE INFO '[OK] Тест 8: вызов change_parcel_status с неверным сегментом ПРОВАЛИЛСЯ, как и ожидалось.'; 
        RESET ROLE; 
END $$;

-- Кейс 9 (Негатив): app_writer пытается изменить статус уже врученной посылки
DO $$ 
BEGIN 
    SET ROLE login_writer; 
    PERFORM app.change_parcel_status('RR000000008RU', 'В пути', 'vladimir.v', 2); 
    RAISE EXCEPTION '[FAIL] Тест 9: change_parcel_status смогла изменить статус врученной посылки!'; 
    RESET ROLE; 
    EXCEPTION WHEN raise_exception 
        THEN RAISE INFO '[OK] Тест 9: попытка изменить статус врученной посылки ПРОВАЛИЛАСЬ, как и ожидалось.'; 
        RESET ROLE; 
END $$;

-- Кейс 10 (Негатив): app_writer пытается установить тот же самый статус
DO $$ 
BEGIN 
    SET ROLE login_writer; 
    PERFORM app.change_parcel_status('RR000000002RU', 'Принято в отделении отправки', 'vladimir.v', 2); 
    RAISE EXCEPTION '[FAIL] Тест 10: change_parcel_status смогла установить дублирующий статус!'; 
    RESET ROLE; 
    EXCEPTION WHEN raise_exception 
        THEN RAISE INFO '[OK] Тест 10: попытка установить дублирующий статус ПРОВАЛИЛАСЬ, как и ожидалось.'; 
        RESET ROLE; 
END $$;

-- Кейс 11 (Негатив): app_writer не может писать в схему audit
DO $$ 
BEGIN 
    SET ROLE login_writer; 
    INSERT INTO audit.login_log(session_user_name, current_user_name) 
    VALUES ('hacker', 'hacker'); 
    RAISE EXCEPTION '[FAIL] Тест 11: app_writer смог вставить данные в audit.login_log!'; 
    RESET ROLE; 
    EXCEPTION WHEN insufficient_privilege 
        THEN RAISE INFO '[OK] Тест 11: Попытка app_writer выполнить DML в схеме audit ПРОВАЛИЛАСЬ, как и ожидалось.'; 
        RESET ROLE; 
END $$;