#!/bin/bash

# ====================================================================================
# ЕДИНЫЙ СКРИПТ ДЛЯ ТЕСТИРОВАНИЯ RLS В POSTGRESQL ЧЕРЕЗ DOCKER EXEC
# ====================================================================================

# --- КОНФИГУРАЦИЯ ---
# Отредактируйте эти переменные в соответствии с вашими настройками
CONTAINER_NAME="db_postgreSQL_BD1"
DB_HOST="localhost"   # Обычно localhost, так как psql выполняется внутри контейнера
DB_PORT="5432"
DB_NAME="admin"       # Убедитесь, что это имя вашей БД

# --- ДАННЫЕ ТЕСТОВЫХ ПОЛЬЗОВАТЕЛЕЙ ---
declare -A USERS_PASSWORDS
USERS_PASSWORDS["marina.m"]="password123"
USERS_PASSWORDS["victoria.b"]="password123"

declare -A USERS_ACTOR_IDS
USERS_ACTOR_IDS["marina.m"]=1
USERS_ACTOR_IDS["victoria.b"]=6

declare -A USERS_SEGMENT_IDS
USERS_SEGMENT_IDS["marina.m"]=1
USERS_SEGMENT_IDS["victoria.b"]=3

# --- ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ---

# Функция для вывода заголовка теста
print_header() {
    echo "========================================================================"
    echo "$1"
    echo "========================================================================"
}

# --- ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ---

# Функция 1: Ожидаем УСПЕШНОЕ выполнение (Exit Code 0)
# Используем для SELECT (даже пустого) и разрешенных INSERT/UPDATE
run_sql_expect_success() {
    local user="$1"
    local sql_command="$2"
    local test_name="$3"

    # -v ON_ERROR_STOP=1 : Прерывает выполнение при первой SQL ошибке и возвращает exit code != 0
    output=$(echo "$sql_command" | docker exec -i \
        -e PGPASSWORD="${USERS_PASSWORDS[$user]}" \
        "$CONTAINER_NAME" \
        psql -h "$DB_HOST" -p "$DB_PORT" -U "$user" -d "$DB_NAME" 2>&1)
    
    local exit_code=$?

    echo "--- SQL Вывод ---"
    echo "$output"
    echo "-----------------"

    if [ $exit_code -eq 0 ]; then
        echo -e "\033[32m[OK] Тест '$test_name' прошел успешно.\033[0m"
        return 0
    else
        echo -e "\033[31m[FAIL] Тест '$test_name' провален.\033[0m"
        echo "Ожидался успех, но произошла ошибка (код $exit_code)."
        return 1
    fi
}

# Функция 2: Ожидаем ОШИБКУ (Exit Code != 0)
# Используем для запрещенных действий (INSERT в чужой сегмент и т.д.)
run_sql_expect_failure() {
    local user="$1"
    local sql_command="$2"
    local test_name="$3"

    output=$(echo "$sql_command" | docker exec -i \
        -e PGPASSWORD="${USERS_PASSWORDS[$user]}" \
        "$CONTAINER_NAME" \
        psql -v ON_ERROR_STOP=1 -h "$DB_HOST" -p "$DB_PORT" -U "$user" -d "$DB_NAME" 2>&1)
    
    local exit_code=$?

    echo "--- SQL Вывод ---"
    echo "$output"
    echo "-----------------"

    if [ $exit_code -ne 0 ]; then
        echo -e "\033[32m[OK] Тест '$test_name' прошел успешно (получена ожидаемая ошибка).\033[0m"
        return 0
    else
        echo -e "\033[31m[FAIL] Тест '$test_name' провален.\033[0m"
        echo "Ожидалась ошибка, но запрос выполнился успешно."
        return 1
    fi
}

# --- ОБНОВЛЕННЫЕ ВЫЗОВЫ ТЕСТОВ ---

test_1_read_foreign_employee() {
    print_header "[Тест 1]: Чтение «чужого» сотрудника"
    echo "Цель: Убедиться, что marina.m не видит victoria.b (пустой результат, без ошибок SQL)."
    
    local user="marina.m"
    local actor_id=${USERS_ACTOR_IDS[$user]}
    local segment_id=${USERS_SEGMENT_IDS[$user]}
    
    SQL=$(cat <<EOF
BEGIN;
SELECT app.set_session_ctx(${actor_id}, ${segment_id});
SELECT * FROM app.employees WHERE login = 'victoria.b';
ROLLBACK;
EOF
)
    run_sql_expect_success "$user" "$SQL" "Чтение чужого сотрудника"
}

test_2_read_foreign_movements() {
    print_header "[Тест 2]: Чтение «чужих» перемещений"
    
    local user="marina.m"
    local actor_id=${USERS_ACTOR_IDS[$user]}
    local segment_id=${USERS_SEGMENT_IDS[$user]}

    SQL=$(cat <<EOF
BEGIN;
SELECT app.set_session_ctx(${actor_id}, ${segment_id});
SELECT * FROM app.parcel_movements WHERE employee_id = 6;
ROLLBACK;
EOF
)
    run_sql_expect_success "$user" "$SQL" "Чтение чужих перемещений"
}

test_3_insert_foreign_segment() {
    print_header "[Тест 3]: Вставка сотрудника в «чужой» сегмент"
    echo "Цель: Должна произойти ошибка нарушения политики."
    
    local user="marina.m"
    local actor_id=${USERS_ACTOR_IDS[$user]}
    local segment_id=${USERS_SEGMENT_IDS[$user]}

    SQL=$(cat <<EOF
BEGIN;
SELECT app.set_session_ctx(${actor_id}, ${segment_id});
INSERT INTO app.employees (last_name, first_name, department_id, segment_id, position_id, status_id, login, password_hash)
VALUES ('Тестов', 'Тест', 3, 3, 1, 1, 'test.t', 'somehash');
ROLLBACK;
EOF
)
    # Ожидаем ошибку
    run_sql_expect_failure "$user" "$SQL" "Вставка в чужой сегмент"
}

test_4_update_foreign_parcel() {
    print_header "[Тест 4]: Обновление посылки с неверным ID"
    
    local user="marina.m"
    local actor_id=${USERS_ACTOR_IDS[$user]}
    local segment_id=${USERS_SEGMENT_IDS[$user]}

    SQL=$(cat <<EOF
BEGIN;
SELECT app.set_session_ctx(${actor_id}, ${segment_id});
UPDATE app.parcels SET departure_department_id = 3 WHERE id = 1;
ROLLBACK;
EOF
)
    # Ожидаем ошибку
    run_sql_expect_failure "$user" "$SQL" "Обновление чужой посылки"
}

test_5_correct_insert() {
    print_header "[Тест 5]: Корректная вставка в своём сегменте"
    
    local user="marina.m"
    local actor_id=${USERS_ACTOR_IDS[$user]}
    local segment_id=${USERS_SEGMENT_IDS[$user]}
    
    SQL=$(cat <<EOF
BEGIN;
SELECT app.set_session_ctx(${actor_id}, ${segment_id});
INSERT INTO app.parcel_movements(parcel_id, segment_id, employee_id, rls_segment_id, status_id)
VALUES (1, 1, 1, 1, 3);
ROLLBACK;
EOF
)
    # Ожидаем успех
    run_sql_expect_success "$user" "$SQL" "Корректная вставка"
}

test_6_read_related_employee() {
    print_header "[Тест 6]: Проверка гибкой политики"
    
    local user="marina.m"
    local actor_id=${USERS_ACTOR_IDS[$user]}
    local segment_id=${USERS_SEGMENT_IDS[$user]}

    SQL=$(cat <<EOF
BEGIN;
SELECT app.set_session_ctx(${actor_id}, ${segment_id});
SELECT e.first_name FROM app.parcel_movements pm
JOIN app.employees e ON pm.employee_id = e.id
WHERE pm.parcel_id = 1;
ROLLBACK;
EOF
)
    run_sql_expect_success "$user" "$SQL" "Чтение связанных сотрудников"
}

test_7_set_ctx_success() {
    print_header "[Тест 7]: Успешный вызов set_session_ctx()"
    
    local user="marina.m"
    local actor_id=${USERS_ACTOR_IDS[$user]}
    local segment_id=${USERS_SEGMENT_IDS[$user]}

    SQL=$(cat <<EOF
BEGIN;
SELECT app.set_session_ctx(${actor_id}, ${segment_id});
ROLLBACK;
EOF
)
    run_sql_expect_success "$user" "$SQL" "Установка контекста"
}

test_8_set_ctx_fail() {
    print_header "[Тест 8]: Ошибочный вызов set_session_ctx()"
    
    local user="marina.m"
    local actor_id=${USERS_ACTOR_IDS[$user]}
    local foreign_segment_id=3

    SQL=$(cat <<EOF
BEGIN;
SELECT app.set_session_ctx(${actor_id}, ${foreign_segment_id});
ROLLBACK;
EOF
)
    # Ожидаем ошибку (RAISE EXCEPTION в функции)
    run_sql_expect_failure "$user" "$SQL" "Некорректная установка контекста"
}

test_9_read_related_clients() {
    print_header "[Тест 9]: Видимость клиентов"
    
    local user="victoria.b"
    local actor_id=${USERS_ACTOR_IDS[$user]}
    local segment_id=${USERS_SEGMENT_IDS[$user]}
    
    SQL=$(cat <<EOF
BEGIN;
SELECT app.set_session_ctx(${actor_id}, ${segment_id});
SELECT id, last_name FROM app.clients;
ROLLBACK;
EOF
)
    run_sql_expect_success "$user" "$SQL" "Чтение клиентов"
}


# --- ГЛАВНЫЙ БЛОК ВЫПОЛНЕНИЯ ---

main() {
    # Проверка наличия docker
    if ! command -v docker &> /dev/null
    then
        echo "Ошибка: команда docker не найдена. Убедитесь, что Docker установлен и запущен."
        exit 1
    fi
    # Проверка, что контейнер запущен
    if ! docker ps --filter "name=$CONTAINER_NAME" --format "{{.Names}}" | grep -q "^$CONTAINER_NAME$"; then
        echo "Ошибка: контейнер с именем '$CONTAINER_NAME' не найден или не запущен."
        exit 1
    fi
    
    test_1_read_foreign_employee
    read -p "Нажмите Enter для следующего теста..."
    
    test_2_read_foreign_movements
    read -p "Нажмите Enter для следующего теста..."
    
    test_3_insert_foreign_segment
    read -p "Нажмите Enter для следующего теста..."
    
    test_4_update_foreign_parcel
    read -p "Нажмите Enter для следующего теста..."
    
    test_5_correct_insert
    read -p "Нажмите Enter для следующего теста..."
    
    test_6_read_related_employee
    read -p "Нажмите Enter для следующего теста..."
    
    test_7_set_ctx_success
    read -p "Нажмите Enter для следующего теста..."
    
    test_8_set_ctx_fail
    read -p "Нажмите Enter для следующего теста..."
    
    test_9_read_related_clients
    
    print_header "Все тесты завершены."
}

# Запускаем выполнение
main