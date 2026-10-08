# Passerelle Telegram de Mizan (D-064) : seul détenteur du jeton du bot.
FROM debian:trixie-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --create-home passerelle

WORKDIR /app
COPY serveur.py .
USER passerelle

EXPOSE 8885
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD python3 -c "import urllib.request; urllib.request.urlopen('http://localhost:8885/sante', timeout=3)"
CMD ["python3", "serveur.py"]
