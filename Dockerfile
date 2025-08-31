# Airflow 3.0 공식 이미지 기반
FROM apache/airflow:3.0.0-python3.12

USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential curl jq vim tini \
 && rm -rf /var/lib/apt/lists/*

USER airflow
ARG AIRFLOW_VERSION=3.0.0
ARG PYTHON_VERSION=3.12
ARG CONSTRAINT_URL="https://raw.githubusercontent.com/apache/airflow/constraints-${AIRFLOW_VERSION}/constraints-${PYTHON_VERSION}.txt"
COPY requirements.txt /requirements.txt
RUN pip install --no-cache-dir -r /requirements.txt -c "${CONSTRAINT_URL}"

# 디렉토리(볼륨 마운트로 대체되지만, 미리 존재하도록 생성)
RUN mkdir -p /opt/airflow/{dags,logs,plugins,config}

# 기본 작업 디렉토리
WORKDIR /opt/airflow
