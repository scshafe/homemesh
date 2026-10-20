# homemesh: the backend plus the built front end. Data is never in the image:
# mount the data directory and set HOMEMESH_DATA to it.
FROM node:22-slim AS web
WORKDIR /w
COPY web/package.json web/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY web/ ./
RUN npm run build

FROM python:3.13-slim
WORKDIR /app
COPY requirements.lock ./
RUN pip install --no-cache-dir -r requirements.lock
COPY homemesh ./homemesh
COPY --from=web /w/dist ./web/dist
RUN useradd --system --uid 10001 homemesh
USER homemesh
ENV HOMEMESH_DATA=/data HOMEMESH_WEB_DIST=/app/web/dist
EXPOSE 8000
CMD ["python", "-m", "uvicorn", "--factory", "homemesh.api:app_factory", "--host", "0.0.0.0", "--port", "8000"]
