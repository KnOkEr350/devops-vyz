# Практика №4. Dockerfile и Docker Compose

Контейнер `web` запускает Django через Gunicorn. Контейнер `db` хранит записи в PostgreSQL. Django подключается к БД по DNS-имени `db` в bridge-сети Compose. PostgreSQL не публикует порт на хост, веб доступен на loopback.

```sh
cd practice4
./scripts/init-env.sh
docker compose config --quiet
docker compose up -d --build --wait
```

Откройте <http://127.0.0.1:8004>, добавьте заметку и посмотрите состояние сервисов.

```sh
docker compose ps
curl -fsS http://127.0.0.1:8004/health/
./scripts/smoke.sh
```

| Что показать | Где посмотреть |
| --- | --- |
| Сборка образа | `web/Dockerfile` задаёт базовый образ, установку зависимостей, порт, пользователя и команду запуска |
| Два сервиса и порядок запуска | `docker-compose.yml` ждёт готовности PostgreSQL, затем Django применяет миграции |
| Переменные среды | `scripts/init-env.sh` генерирует значения в локальный `.env` |
| Постоянное хранение | `smoke.sh` создаёт заметку через HTTP, проверяет, что контейнер БД сменился, и находит заметку после пересоздания обоих сервисов |
| Автоматическая проверка | [GitHub Actions](https://github.com/KnOkEr350/devops-vyz/actions/workflows/docker-practice4.yml) запускает проверку на существующем self-hosted ранере и прикладывает журнал |

`docker compose down` останавливает этот стенд с сохранением тома. Следующий `docker compose up -d --wait` поднимает его с теми же записями.
