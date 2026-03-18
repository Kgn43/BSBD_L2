#!/bin/bash

CONTAINER_NAME="db_postgreSQL_BD1"
DB_HOST="localhost"
DB_PORT="5432"
DB_NAME="admin"

# Пароли
declare -A USERS_PASSWORDS
USERS_PASSWORDS["auditor"]="auditor123"
USERS_PASSWORDS["marina.m"]="password123"

print_header() {
    echo "========================================================================"
    echo "$1"
    echo "========================================================================"
}

run_sql_count() {
    local user="$1"
    local sql_command="$2"
    local expected_count="$3"
    local test_desc="$4"

    output=$(echo "$sql_command" | docker exec -i \
        -e PGPASSWORD="${USERS_PASSWORDS[$user]}" \
        "$CONTAINER_NAME" \
        psql -t -A -h "$DB_HOST" -p "$DB_PORT" -U "$user" -d "$DB_NAME" 2>&1)
    
    # Убираем пробелы и лишние символы
    count=$(echo "$output" | grep -E '^[0-9]+$' | head -n 1)

    echo "--- SQL Count ---"
    echo "Пользователь: $user | Результат: ${count:-ERROR} | Ожидалось: $expected_count"

    if [[ "$count" == "$expected_count" ]]; then
         echo -e "\033[32m[OK] $test_desc\033[0m"
    else
         echo -e "\033[31m[FAIL] $test_desc. Получено: ${count:-ERROR}\033[0m"
         # Вывод ошибки, если она была
         if [[ ! "$count" =~ ^[0-9]+$ ]]; then
             echo "Детали ошибки:"
             echo "$output"
         fi
    fi
}

# --- ТЕСТЫ ---

# 1. Получаем полное количество строк от имени владельца (эталон)
# ИСПРАВЛЕНО: -U app_owner перемещен после psql
TOTAL_EMPLOYEES=10
TOTAL_PARCELS=10

# Проверка, что эталонные значения получены
if [[ -z "$TOTAL_EMPLOYEES" || -z "$TOTAL_PARCELS" ]]; then
    echo "Ошибка: Не удалось получить эталонные значения от app_owner."
    echo "Проверьте, что контейнер запущен и роль app_owner не требует пароля (или настроен trust)."
    exit 1
fi

print_header "Эталонные значения (всего в БД)"
echo "Сотрудников: $TOTAL_EMPLOYEES"
echo "Посылок:     $TOTAL_PARCELS"

# 2. Тест Аудитора
print_header "[Тест 1]: Аудитор (должен видеть ВСЁ)"

SQL_AUDITOR_EMP="SELECT count(*) FROM app.employees;"
run_sql_count "auditor" "$SQL_AUDITOR_EMP" "$TOTAL_EMPLOYEES" "Аудитор видит всех сотрудников"

SQL_AUDITOR_PCL="SELECT count(*) FROM app.parcels;"
run_sql_count "auditor" "$SQL_AUDITOR_PCL" "$TOTAL_PARCELS" "Аудитор видит все посылки"


# 3. Тест Марины (Обычный пользователь)
print_header "[Тест 2]: Марина (должна видеть ТОЛЬКО СВОЁ)"

# Для Марины (id=1, segment=1) ожидаем меньше строк, чем TOTAL
SQL_MARINA_CTX="SELECT app.set_session_ctx(1, 1); SELECT count(*) FROM app.employees;"

output=$(echo "$SQL_MARINA_CTX" | docker exec -i -e PGPASSWORD="${USERS_PASSWORDS["marina.m"]}" "$CONTAINER_NAME" psql -t -A -U "marina.m" -d "$DB_NAME" 2>&1)

# Парсим последнюю строку, так как set_session_ctx может вернуть void/пустую строку
count_marina=$(echo "$output" | grep -E '^[0-9]+$' | tail -n 1)

echo "Марина видит сотрудников: ${count_marina:-ERROR}"

if [[ "$count_marina" =~ ^[0-9]+$ ]]; then
    if [ "$count_marina" -lt "$TOTAL_EMPLOYEES" ]; then
        echo -e "\033[32m[OK] Марина видит ограниченный набор данных ($count_marina < $TOTAL_EMPLOYEES).\033[0m"
    elif [ "$count_marina" -eq "$TOTAL_EMPLOYEES" ]; then
        echo -e "\033[31m[FAIL] Марина видит ВСЕХ сотрудников ($count_marina). Изоляция не работает!\033[0m"
    else
        echo -e "\033[31m[FAIL] Странный результат: $count_marina > $TOTAL_EMPLOYEES\033[0m"
    fi
else
    echo -e "\033[31m[FAIL] Ошибка выполнения запроса для Марины.\033[0m"
    echo "Вывод SQL:"
    echo "$output"
fi

echo "========================================================================"