# Service OCR de Mizan : Tesseract (français) + poppler, API HTTP minimale.
FROM debian:trixie-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends tesseract-ocr tesseract-ocr-fra poppler-utils python3 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --create-home ocr

WORKDIR /app
COPY serveur.py .
USER ocr

EXPOSE 8884
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD python3 -c "import urllib.request; urllib.request.urlopen('http://localhost:8884/sante', timeout=3)"
CMD ["python3", "serveur.py"]
