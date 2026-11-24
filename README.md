# Практика №4. Миграция Mattermost с MySQL на PostgreSQL

Исходный стенд — Mattermost 9.5.2 и MySQL 8.0. Целевой — Mattermost 12.0.1 и PostgreSQL 15. Оба Compose-файла используют проект `devops-practice4-mattermost`. Сервисы БД и pgloader соединяются в его bridge-сети. Веб-порт 8065 доступен с Mac, базы используют внутренние адреса. Оба образа Mattermost монтируют один том в `/mattermost/data`.

## Что выполняет GitHub Actions

1. Проверяет файл `.migration_completed` в постоянном каталоге ранера. Если файл уже есть, пропускает резервное копирование и перенос.
2. Проверяет исходный набор данных через API, останавливает приложение и делает согласованный дамп MySQL. SQL-дамп остаётся в закрытом каталоге ранера.
3. Копирует источник официальным образом Mattermost pgloader в промежуточную БД с `include drop`. Сравнивает количество строк в таблицах команды, канала, сообщений, пользователей и файлов.
4. Подготавливает нативную схему PostgreSQL через Mattermost 9.5.2 и переносит строки pgloader в режиме `data only`. Снова сверяет количество строк. Последовательно применяет миграции схемы 10.11.20, 11.7.8 и 12.0.1.
5. Проверяет HTTP, приватность канала, идентификаторы и порядок четырёх сообщений, роль администратора и SHA-256 вложения и аватара. После проверки сохраняет флаг, удаляет старый контейнер через `--remove-orphans` и сверяет исходный дамп по SHA-256.

Промежуточная БД изолирует `include drop` от нативных индексов, ограничений и типов Mattermost. Если первый перенос прервётся, повторный запуск пересоздаст его таблицы и заново подготовит целевую БД этого учебного стенда. После успешного прогона повторная работа проверяет уже существующий PostgreSQL. MySQL-том и SQL-дамп сохраняются.

## Демонстрация

- [Приватный канал «Проверка миграции»](http://127.0.0.1:8065/devops-practice4/channels/migration-check)
- Логин `admin@mattermost.example`. Значение `MM_DEMO_PASSWORD` хранится в `~/.local/share/devops-practice4-mattermost/credentials.env` с правами владельца.
- Откройте канал и покажите четыре сообщения с контрольным вложением. В Actions откройте два запуска со статусом **Success**. В повторном запуске шаги резервного копирования и pgloader имеют статус **Skipped**.
- В артефакте Actions есть отчёт проверки, метаданные исходных сообщений и хеши. SQL-дамп и диагностические логи остаются в каталоге ранера.

## Подготовка чистого стенда

1. На self-hosted ранере должен работать Docker. Создайте каталог `~/.local/share/devops-practice4-mattermost` и в нём защищённый файл `credentials.env`. Задайте отдельные случайные значения из `openssl rand -hex 24` для `DB_MYSQL_ROOT_PASSWORD`, `DB_MYSQL_PASSWORD`, `DB_POSTGRES_PASSWORD` и `MM_DEMO_PASSWORD`. Те же значения запишите в GitHub Actions Secrets.
2. Запустите исходный стек и создайте тестовый набор через HTTP API.

   ```bash
   state="$HOME/.local/share/devops-practice4-mattermost"
   set -a
   source "$state/credentials.env"
   set +a
   docker compose -f legacy/docker-compose.yml up -d --wait
   python3 scripts/demo.py seed "$state/legacy-fixture.json"
   python3 scripts/demo.py verify "$state/legacy-fixture.json"
   ```

3. Push в ветку `migration` запускает `.github/workflows/migration.yml`. После завершения выберите **Re-run all jobs** и проверьте статус бэкапа и переноса во втором проходе.

Документация: [миграция Mattermost на PostgreSQL](https://docs.mattermost.com/administration-guide/manage/admin/postgres-migration), [параметры pgloader](https://pgloader.readthedocs.io/en/latest/ref/mysql.html).
