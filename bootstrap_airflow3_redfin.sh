#!/usr/bin/env bash
set -euo pipefail

# 프로젝트 루트
PRJ_DIR="${PWD}"
mkdir -p "${PRJ_DIR}"/{dags,plugins,logs,data,config}

# -----------------------------
# .env (필수 환경)
# -----------------------------
cat > .env <<'EOF'
# ===== 공통 =====
TZ=Asia/Seoul
COMPOSE_PROJECT_NAME=redfin_airflow3

# ===== 호스트 UID/GID (WSL2 또는 리눅스 호스트 사용자 값으로 교체 권장) =====
AIRFLOW_UID=1002
AIRFLOW_GID=1002

# ===== Airflow Core =====
AIRFLOW__CORE__EXECUTOR=LocalExecutor
AIRFLOW__CORE__FERNET_KEY=CHANGE_ME__use_openssl_or_python_to_generate
AIRFLOW__CORE__LOAD_EXAMPLES=false
AIRFLOW__CORE__DAGS_ARE_PAUSED_AT_CREATION=true
AIRFLOW__SCHEDULER__STANDALONE_DAG_PROCESSOR=true
AIRFLOW__WEBSERVER__SECRET_KEY=CHANGE_ME_web_secret

# ===== Airflow 3.0 신규(권장) =====
# 참고: 3.0부터 단일 schedule 필드 / Assets 모델 사용. 여기선 런타임 플래그 예시만.
AIRFLOW__DEBUG__SQLALCHEMY_ECHO=false

# ===== Postgres (메타DB) =====
POSTGRES_USER=airflow
POSTGRES_PASSWORD=airflow
POSTGRES_DB=airflow

# ===== 포트 =====
AIRFLOW_WEB_PORT=18080
POSTGRES_PORT=15432

# ===== Redfin 외부 시스템 예시 (옵션) =====
# MONGO_URI=mongodb://redfin:password@mongodb:27017/redfin?authSource=admin
# QDRANT_URL=http://qdrant:6333
EOF

# -----------------------------
# Dockerfile (Airflow 3.0 커스텀)
# -----------------------------
cat > Dockerfile <<'EOF'
# Airflow 3.0 공식 이미지 기반
FROM apache/airflow:3.0.0-python3.12

USER root
# 빌드에 필요한 OS 패키지(예: lxml, gcc 등 필요시 추가)
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential curl jq vim tini \
 && rm -rf /var/lib/apt/lists/*

USER airflow
# 파이썬 의존성(플러그인/연결용 라이브러리 포함)
# Airflow 제약사항을 따르기 위해 constraints 사용 권장
ARG AIRFLOW_VERSION=3.0.0
ARG PYTHON_VERSION=3.12
ARG CONSTRAINT_URL="https://raw.githubusercontent.com/apache/airflow/constraints-${AIRFLOW_VERSION}/constraints-${PYTHON_VERSION}.txt"

COPY requirements.txt /requirements.txt
RUN pip install --no-cache-dir -r /requirements.txt -c "${CONSTRAINT_URL}"

# 디렉토리(볼륨 마운트로 대체되지만, 미리 존재하도록 생성)
RUN mkdir -p /opt/airflow/{dags,logs,plugins,config}

# 기본 작업 디렉토리
WORKDIR /opt/airflow
EOF

# -----------------------------
# requirements.txt
# -----------------------------
cat > requirements.txt <<'EOF'
# Airflow Providers
apache-airflow-providers-postgres
apache-airflow-providers-http
apache-airflow-providers-common-sql
apache-airflow-providers-cncf-kubernetes ; python_version<"3.13"  # 필요 시
apache-airflow-providers-mongo

# Redfin 파이프라인 유틸
pymongo
requests
beautifulsoup4
yake
readability-lxml
lxml
tqdm
python-dateutil
pendulum
EOF

# -----------------------------
# docker-compose.yml
# -----------------------------
cat > docker-compose.yml <<'EOF'
version: "3.8"

x-airflow-common:
  &airflow-common
  build:
    context: .
    dockerfile: Dockerfile
  image: redfin/airflow3:local
  restart: unless-stopped
  env_file: .env
  environment:
    &airflow-env
    TZ: ${TZ}
    AIRFLOW__CORE__EXECUTOR: ${AIRFLOW__CORE__EXECUTOR}
    AIRFLOW__CORE__FERNET_KEY: ${AIRFLOW__CORE__FERNET_KEY}
    AIRFLOW__CORE__DAGS_ARE_PAUSED_AT_CREATION: ${AIRFLOW__CORE__DAGS_ARE_PAUSED_AT_CREATION}
    AIRFLOW__CORE__LOAD_EXAMPLES: ${AIRFLOW__CORE__LOAD_EXAMPLES}
    AIRFLOW__SCHEDULER__STANDALONE_DAG_PROCESSOR: ${AIRFLOW__SCHEDULER__STANDALONE_DAG_PROCESSOR}
    AIRFLOW__WEBSERVER__SECRET_KEY: ${AIRFLOW__WEBSERVER__SECRET_KEY}
    _AIRFLOW_WWW_USER_USERNAME: admin
    _AIRFLOW_WWW_USER_PASSWORD: admin
    # 데이터베이스 연결(기본 Postgres)
    AIRFLOW__DATABASE__SQL_ALCHEMY_CONN: postgresql+psycopg2://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres/${POSTGRES_DB}
  user: "${AIRFLOW_UID}:${AIRFLOW_GID}"
  volumes:
    - ./dags:/opt/airflow/dags
    - ./plugins:/opt/airflow/plugins
    - ./logs:/opt/airflow/logs
    - ./config:/opt/airflow/config
    - ./data:/opt/airflow/data
  depends_on:
    postgres:
      condition: service_healthy

services:
  postgres:
    image: postgres:16
    container_name: ${COMPOSE_PROJECT_NAME}-postgres
    restart: unless-stopped
    env_file: .env
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
      TZ: ${TZ}
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 5s
      timeout: 5s
      retries: 30
    ports:
      - "${POSTGRES_PORT}:5432"
    volumes:
      - pgdata:/var/lib/postgresql/data

  airflow-init:
    <<: *airflow-common
    container_name: ${COMPOSE_PROJECT_NAME}-airflow-init
    entrypoint: ["/bin/bash", "-c"]
    command:
      - |
        set -e
        airflow db migrate
        airflow users create \
          --username "$$_AIRFLOW_WWW_USER_USERNAME" \
          --password "$$_AIRFLOW_WWW_USER_PASSWORD" \
          --firstname Admin --lastname User \
          --role Admin --email admin@example.com
        echo "Airflow DB migrated and admin user created."

  airflow-webserver:
    <<: *airflow-common
    container_name: ${COMPOSE_PROJECT_NAME}-airflow-webserver
    command: webserver
    ports:
      - "${AIRFLOW_WEB_PORT}:8080"
    healthcheck:
      test: ["CMD", "curl", "--fail", "http://localhost:8080/health"]
      interval: 10s
      timeout: 10s
      retries: 30

  airflow-scheduler:
    <<: *airflow-common
    container_name: ${COMPOSE_PROJECT_NAME}-airflow-scheduler
    command: scheduler

  airflow-dag-processor:
    <<: *airflow-common
    container_name: ${COMPOSE_PROJECT_NAME}-airflow-dag-processor
    command: dag-processor

volumes:
  pgdata:
EOF

# -----------------------------
# 샘플 폴더/파일 (필수 아님)
# -----------------------------
mkdir -p dags/ingestion plugins/utils config
cat > dags/README.md <<'EOF'
# Place your Airflow 3.0 DAGs here.
# - Airflow 3.0는 단일 `schedule` 필드와 Asset(구 Dataset) 사용 권장.
EOF

cat > plugins/utils/README.md <<'EOF'
유틸 모듈 배치 위치. (예: rss_ops.py, mongo.py 등)
EOF

# -----------------------------
# .gitignore
# -----------------------------
cat > .gitignore <<'EOF'
logs/
pgdata/
__pycache__/
*.pyc
.env
.DS_Store
EOF

echo "done."
echo "다음 순서로 실행하세요:"
echo "  1) ./bootstrap_airflow3_redfin.sh   # 이 스크립트 자체"
echo "  2) docker compose build --no-cache"
echo "  3) docker compose up airflow-init && docker compose up -d"
echo "  4) http://localhost:${AIRFLOW_WEB_PORT:-18080} 접속 (admin/admin)"

