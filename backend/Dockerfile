FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

COPY requirements.txt .
RUN python -m pip install --no-cache-dir --upgrade pip==26.1.2 \
    && pip install --no-cache-dir -r requirements.txt

RUN groupadd --gid 10001 oblix \
    && useradd --uid 10001 --gid 10001 --no-create-home --shell /usr/sbin/nologin oblix

COPY --chown=10001:10001 . .

# Runtime writes are limited to the separately mounted uploads directory.
RUN mkdir -p uploads && chown 10001:10001 uploads && chmod 700 uploads

EXPOSE 8000

USER 10001:10001

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
