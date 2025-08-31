# 프로젝트 설정 및 실행 가이드

## 프로젝트 클론 및 초기 설정

1. **프로젝트 클론**
   ```bash
   git clone <repository-url>
   cd redfin_airflow3
   ```

2. **환경 변수 설정**
   - `.env.example` 파일을 참고하여 `.env` 파일을 생성하고 필요한 환경 변수를 설정합니다.

## Docker를 사용한 실행

1. **Docker 이미지 빌드**
   ```bash
   docker compose build --no-cache
   ```

2. **Airflow 초기화 및 실행**
   ```bash
   docker compose up --rm airflow-init && docker compose up -d
   ```

3. **Airflow 웹 인터페이스 접속**
   - 웹 브라우저에서 [http://localhost:${AIRFLOW_WEB_PORT:-18080}](http://localhost:${AIRFLOW_WEB_PORT:-18080})에 접속하여 Airflow 대시보드에 접근합니다.

## 권한 설정

프로젝트를 클론한 후, 파일 및 디렉터리의 소유권을 확인하고 필요한 경우 권한을 설정합니다.

1. **파일 및 디렉터리 소유권 확인**
   ```bash
   ls -lR /home/user/workspace/redfin/redfin_airflow3
   ```

   - `data` 및 `logs` 디렉터리는 `root` 소유로 되어 있으므로, 필요에 따라 소유권을 변경해야 할 수 있습니다.

2. **소유권 변경 (필요한 경우)**
   ```bash
   sudo chown -R user:user /home/user/workspace/redfin/redfin_airflow3/data
   sudo chown -R user:user /home/user/workspace/redfin/redfin_airflow3/logs
   ```

3. **명령어 히스토리 확인**
   ```bash
   history
   ```

   - 이전에 실행된 명령어를 참고하여 필요한 권한 설정을 추가로 수행할 수 있습니다.

이 과정을 통해 프로젝트의 파일 및 디렉터리 권한을 적절히 설정할 수 있습니다.
