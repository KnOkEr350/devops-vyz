# Практика №5. Пакет SysPulse в Nexus APT

Ветка `release` запускает [GitHub Actions](https://github.com/KnOkEr350/devops-vyz/actions/workflows/publish-deb.yml) на ранере `macbook-runner`. Пайплайн собирает статический ELF для Linux amd64, создаёт пакет `syspulse_1.2.0_amd64.deb`, публикует его в hosted APT и устанавливает с нуля в новом контейнере Ubuntu 22.04.

- Версия берётся из `main.go`. Архив проверяется командами `dpkg -I` и `dpkg -c`.
- Nexus использует дистрибутив `stable`, компонент `main` и разрешает повторную публикацию той же версии (`ALLOW`). Загрузка идёт через HTTP POST по HTTPS.
- APT проверяет подпись метаданных по `keys/syspulse-archive.asc` через `signed-by`. Клиент проверяет TLS по `keys/nexus-ca.crt`. Здесь хранятся публичные ключ и сертификат.
- Установка проверяет версию и архитектуру по данным dpkg, вывод `syspulse --version` и чтение `/proc`.
- В артефакте `syspulse-deb` остаются пакет, SHA-256, подписанные метаданные и журналы сборки и установки.

## Стенд на Mac

Nexus 3 работает в контейнере `devops-practice5-nexus` с постоянным томом `devops-practice5-nexus-data`. Его UI доступен на <http://localhost:8081>. Контейнер Nginx `devops-practice5-https` обслуживает HTTPS на 18443 и передаёт запросы Nexus. Контейнер проверки обращается к нему по имени `nexus.syspulse.test` в сети `devops-practice5`. Конфигурация прокси находится в `nexus/nginx.conf`.

Для повторного запуска ранеру нужны Docker Desktop, запущенные Nexus и Nginx, а также Actions Secrets `NEXUS_HOST`, `NEXUS_USER`, `NEXUS_PASSWORD`. На этом стенде `NEXUS_HOST` указывает на IPv4 loopback Mac. Учётная запись публикации имеет права на репозиторий `syspulse`. Используйте **Re-run all jobs** в Actions для проверки повторного прогона.
