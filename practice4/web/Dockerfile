FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1
WORKDIR /app

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt \
    && groupadd --system django \
    && useradd --system --gid django --no-create-home django

COPY manage.py entrypoint.sh ./
COPY labsite/ ./labsite/
COPY notes/ ./notes/

USER django
EXPOSE 8000
ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["gunicorn", "--bind", "0.0.0.0:8000", "--access-logfile", "-", "labsite.wsgi:application"]
