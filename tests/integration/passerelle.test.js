// Passerelle Telegram (D-064) : configuration Docker, isolement réseau, et
// tests du service lui-même (dans son image, contre un faux Telegram).
// Exige la pile démarrée avec la passerelle (docker compose up -d).
// Aucune assertion n'affiche de valeur de variable : seulement des noms.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { resolve } from 'node:path';

const VARIABLE = 'TELEGRAM_BOT_TOKEN';
const SERVICE = 'passerelle-telegram';
const docker = (args, options = {}) => spawnSync('docker', ['compose', ...args], { encoding: 'utf8', ...options });

test('le jeton n\'est transmis qu\'au service de la passerelle (configuration Docker)', () => {
  const r = docker(['config', '--format', 'json']);
  assert.equal(r.status, 0, 'docker compose config');
  const services = JSON.parse(r.stdout).services;
  const avecJeton = Object.entries(services).filter(([, s]) => s.environment && VARIABLE in s.environment).map(([nom]) => nom);
  assert.deepEqual(avecJeton, [SERVICE]);
  const avecFichierEnv = Object.entries(services).filter(([, s]) => s.env_file).map(([nom]) => nom);
  assert.deepEqual(avecFichierEnv, [], 'aucun service ne charge un fichier .env entier');
});

test('réseau dédié : seuls n8n et la passerelle rejoignent « canal-telegram »', () => {
  const services = JSON.parse(docker(['config', '--format', 'json']).stdout).services;
  const membres = Object.entries(services).filter(([, s]) => s.networks && 'canal-telegram' in s.networks).map(([nom]) => nom).sort();
  assert.deepEqual(membres, ['n8n', SERVICE]);
  assert.deepEqual(Object.keys(services[SERVICE].networks), ['canal-telegram'], 'la passerelle n\'est pas sur le réseau par défaut');
  assert.equal(services[SERVICE].ports, undefined, 'aucun port publié');
});

test('à l\'exécution : la variable du jeton est absente des autres conteneurs', () => {
  for (const service of ['n8n', 'runners', 'ocr', 'postgres']) {
    const r = docker(['exec', '-T', service, 'printenv', VARIABLE]);
    assert.notEqual(r.status, 0, `${service} ne doit pas connaître ${VARIABLE}`);
  }
});

test('isolement : n8n joint la passerelle ; l\'OCR ne peut même pas résoudre son nom', () => {
  const n8n = docker(['exec', '-T', 'n8n', 'node', '-e',
    `fetch('http://${SERVICE}:8885/sante').then(r => r.json()).then(j => console.log(j.statut))`]);
  assert.equal(n8n.stdout.trim(), 'ok', n8n.stderr);
  const ocr = docker(['exec', '-T', 'ocr', 'python3', '-c',
    `import socket\ntry:\n  socket.gethostbyname('${SERVICE}'); print('joignable')\nexcept OSError:\n  print('introuvable')`]);
  assert.equal(ocr.stdout.trim(), 'introuvable');
});

test('service : relais, liste fermée de méthodes, jeton jamais dans les réponses ni les journaux (tests Python)', () => {
  const fichier = resolve('passerelle-telegram/test_passerelle.py');
  const r = docker(['run', '--rm', '--no-deps', '-e', 'PYTHONDONTWRITEBYTECODE=1', '-e', `${VARIABLE}=`,
    '-v', `${fichier}:/app/test_passerelle.py:ro`, SERVICE, 'python3', '-m', 'unittest', 'test_passerelle'],
  { env: { ...process.env, MSYS_NO_PATHCONV: '1' } });
  assert.equal(r.status, 0, r.stderr.slice(-2000));
  assert.match(r.stderr, /Ran 12 tests/);
});
