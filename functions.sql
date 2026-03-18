--Регистрация нового отправления
BEGIN;
SET ROLE app_owner;
CREATE OR REPLACE FUNCTION app.register_parcel(
	p_employee_login TEXT,
    -- Данные отправителя
    p_sender_last_name TEXT,
    p_sender_first_name TEXT,
    p_sender_phone TEXT,
    p_sender_address TEXT,
    -- Данные получателя
    p_recipient_last_name TEXT,
    p_recipient_first_name TEXT,
    p_recipient_phone TEXT,
    p_recipient_address TEXT,
    -- Данные посылки
    p_departure_dept_id INT,
    p_arrival_dept_id INT,
    p_weight_kg NUMERIC,
    p_declared_value NUMERIC
)
RETURNS TEXT AS $$

DECLARE
    v_log_id INT;
	v_employee_id BIGINT;
    v_sender_id BIGINT;
    v_recipient_id BIGINT;
    v_new_parcel_id BIGINT;
    v_tracking_number TEXT;
    v_encryption_key TEXT := 'ABOBA';
BEGIN
    INSERT INTO audit.function_calls (function_name, caller_role, input_params)
    VALUES (
        'app.register_parcel',
        current_user,
        jsonb_build_object(
            'p_employee_login', p_employee_login,
            'p_sender_last_name', p_sender_last_name,
            'p_sender_first_name', p_sender_first_name,
            'p_sender_phone', p_sender_phone,
            'p_sender_address', p_sender_address,
            'p_recipient_last_name', p_recipient_last_name,
            'p_recipient_first_name', p_recipient_first_name,
            'p_recipient_phone', p_recipient_phone,
            'p_recipient_address', p_recipient_address,
            'p_departure_dept_id', p_departure_dept_id,
            'p_arrival_dept_id', p_arrival_dept_id,
            'p_weight_kg', p_weight_kg,
            'p_declared_value', p_declared_value
        )
    ) RETURNING id INTO v_log_id; 

    --Валидация входных данных
    IF p_weight_kg <= 0 OR p_declared_value < 0 THEN
        RAISE EXCEPTION 'Вес должен быть положительным, а стоимость неотрицательной.';
    END IF;
    IF p_sender_phone IS NULL OR p_recipient_phone IS NULL THEN
        RAISE EXCEPTION 'Номер телефона отправителя и получателя обязательны.';
    END IF;
	
	SELECT id INTO v_employee_id FROM app.employees WHERE login = p_employee_login;
    IF v_employee_id IS NULL THEN
        RAISE EXCEPTION 'Сотрудник с логином "%" не найден. Регистрация невозможна.', p_employee_login;
    END IF;

    --Работа с отправителем
    SELECT id INTO v_sender_id FROM app.clients
    WHERE last_name = p_sender_last_name AND first_name = p_sender_first_name
      AND pgp_sym_decrypt(phone, v_encryption_key)::TEXT = p_sender_phone;

    IF v_sender_id IS NULL THEN
        INSERT INTO app.clients(last_name, first_name, phone, address)
        VALUES (p_sender_last_name, p_sender_first_name,
                pgp_sym_encrypt(p_sender_phone, v_encryption_key),
                pgp_sym_encrypt(p_sender_address, v_encryption_key))
        RETURNING id INTO v_sender_id;
    END IF;

    -- Работа с получателем
    SELECT id INTO v_recipient_id FROM app.clients
    WHERE last_name = p_recipient_last_name AND first_name = p_recipient_first_name
      AND pgp_sym_decrypt(phone, v_encryption_key)::TEXT = p_recipient_phone;

    IF v_recipient_id IS NULL THEN
        INSERT INTO app.clients(last_name, first_name, phone, address)
        VALUES (p_recipient_last_name, p_recipient_first_name,
                pgp_sym_encrypt(p_recipient_phone, v_encryption_key),
                pgp_sym_encrypt(p_recipient_address, v_encryption_key))
        RETURNING id INTO v_recipient_id;
    END IF;
    
    --Создание посылки
    --Генерация трекинг-номера
    v_tracking_number := 'RR' || to_char(now(), 'YYMMDDHH24MISS') || 'RU';

    INSERT INTO app.parcels (
        tracking_number, sender_client_id, recipient_client_id,
        departure_department_id, arrival_department_id,
        weight_kg, declared_value
    )
    VALUES (
        v_tracking_number, v_sender_id, v_recipient_id,
        p_departure_dept_id, p_arrival_dept_id,
        p_weight_kg, p_declared_value
    )
    RETURNING id INTO v_new_parcel_id;

	INSERT INTO app.parcel_movements(parcel_id, segment_id, employee_id, status_id)
    VALUES (
        v_new_parcel_id,
        p_departure_dept_id,
        v_employee_id,
        (SELECT id FROM ref.parcel_statuses WHERE status_name = 'Зарегистрировано')
    );

    UPDATE audit.function_calls SET success = true WHERE id = v_log_id;

    RETURN v_tracking_number;

    EXCEPTION
    WHEN OTHERS THEN
        UPDATE audit.function_calls
        SET success = false
        WHERE id = v_log_id;
        RAISE;

END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = app, ref, audit, public;

RESET ROLE;
COMMIT;

-------------------------------------------------------
--Обновление статуса
BEGIN;
SET ROLE app_owner;
CREATE OR REPLACE FUNCTION app.change_parcel_status(
    p_tracking_number TEXT,
    p_new_status_name TEXT,
    p_employee_login TEXT,
    p_segment_id INT
)
RETURNS TEXT AS $$
DECLARE
    v_log_id INT;
    v_parcel_id BIGINT;
    v_employee_id BIGINT;
    v_new_status_id INT;
    v_current_status_id INT;
    v_current_status_name TEXT;
BEGIN
    INSERT INTO audit.function_calls (function_name, caller_role, input_params)
    VALUES (
        'app.change_parcel_status',
        current_user,
        jsonb_build_object(
            'p_tracking_number', p_tracking_number, 'p_new_status_name', p_new_status_name,
            'p_employee_login', p_employee_login, 'p_segment_id', p_segment_id
        )
    ) RETURNING id INTO v_log_id; 

    --Найти ID посылки по трекинг-номеру.
    SELECT id INTO v_parcel_id
    FROM app.parcels WHERE tracking_number = p_tracking_number;
    IF v_parcel_id IS NULL THEN
        RAISE EXCEPTION 'Посылка с трекинг-номером % не найдена.', p_tracking_number;
    END IF;

    --Найти последний статус этой посылки в таблице перемещений.
    SELECT status_id INTO v_current_status_id
    FROM app.parcel_movements
    WHERE parcel_id = v_parcel_id
    ORDER BY event_timestamp DESC
    LIMIT 1;

    --Валидация
    SELECT id INTO v_employee_id FROM app.employees WHERE login = p_employee_login;
    IF v_employee_id IS NULL THEN
        RAISE EXCEPTION 'Сотрудник с логином % не найден.', p_employee_login;
    END IF;

    SELECT id INTO v_new_status_id FROM ref.parcel_statuses WHERE status_name = p_new_status_name;
    IF v_new_status_id IS NULL THEN
        RAISE EXCEPTION 'Статус "%" не существует.', p_new_status_name;
    END IF;

	IF NOT EXISTS (SELECT 1 FROM app.route_segments WHERE id = p_segment_id) THEN
        RAISE EXCEPTION 'Сегмент маршрута с ID % не найден. Операция отменена.', p_segment_id;
    END IF;

    SELECT status_name INTO v_current_status_name FROM ref.parcel_statuses WHERE id = v_current_status_id;
    --Бизнес-правила
    IF v_current_status_name IN ('Вручено получателю', 'Возвращено отправителю', 'Утеряно') THEN
        RAISE EXCEPTION 'Нельзя изменить конечный статус "%". Операция отменена.', v_current_status_name;
    END IF;
	
    IF v_current_status_id = v_new_status_id THEN
        RAISE EXCEPTION 'Посылка уже находится в статусе "%".', v_current_status_name;
    END IF;

    --Обновляем текущий статус посылки
     INSERT INTO app.parcel_movements(parcel_id, segment_id, employee_id, status_id)
    VALUES (v_parcel_id, p_segment_id, v_employee_id, v_new_status_id);

    RETURN 'Новый статус "' || p_new_status_name || '" для посылки ' || p_tracking_number || ' успешно зарегистрирован.';

    --Обновляем статус в таблице аудита вызова функций
    UPDATE audit.function_calls SET success = true WHERE id = v_log_id;
    RETURN v_result_text;
EXCEPTION
    WHEN OTHERS THEN
        UPDATE audit.function_calls
        SET success = false
        WHERE id = v_log_id;
        RAISE;

END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = app, ref, audit, public;

RESET ROLE;
COMMIT;

------------------------------------------
--Выдаем права на выполнение
REVOKE EXECUTE ON FUNCTION app.register_parcel(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,INT,INT,NUMERIC,NUMERIC) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION app.change_parcel_status(TEXT,TEXT,TEXT,INT) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION app.register_parcel(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,INT,INT,NUMERIC,NUMERIC) TO app_writer;
GRANT EXECUTE ON FUNCTION app.change_parcel_status(TEXT,TEXT,TEXT,INT) TO app_writer;