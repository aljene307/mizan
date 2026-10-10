// Création de .env pour la démonstration : aucun « change-me » ne reste,
// secrets aléatoires et distincts, clé Gemini et jeton Telegram vides.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { contenuEnv, secretAleatoire, LAISSES_VIDES } from '../scripts/creer-env.js';

const exemple = readFileSync('.env.example', 'utf8');
const valeurs = (texte) => Object.fromEntries(texte.split(/\r?\n/)
  .map((l) => l.match(/^([A-Z0-9_]+)=(.*)$/)).filter(Boolean).map((m) => [m[1], m[2]]));

test('.env créé depuis .env.example : plus aucun « change-me »', () => {
  const env = valeurs(contenuEnv(exemple));
  assert.ok(Object.values(valeurs(exemple)).includes('change-me'));
  assert.ok(!Object.values(env).includes('change-me'));
  assert.deepEqual(Object.keys(env), Object.keys(valeurs(exemple)));
});

test('secrets : 40 lettres minuscules ou chiffres, distincts', () => {
  const avant = valeurs(exemple);
  const apres = valeurs(contenuEnv(exemple));
  const secrets = Object.keys(avant).filter((k) => avant[k] === 'change-me' && !LAISSES_VIDES.includes(k));
  assert.ok(secrets.includes('POSTGRES_PASSWORD') && secrets.includes('N8N_ENCRYPTION_KEY'));
  for (const k of secrets) assert.match(apres[k], /^[a-z0-9]{40}$/, k);
  assert.equal(new Set(secrets.map((k) => apres[k])).size, secrets.length);
  assert.match(secretAleatoire(12), /^[a-z0-9]{12}$/);
});

test('clé Gemini et jeton Telegram laissés vides ; autres valeurs inchangées', () => {
  const avant = valeurs(exemple);
  const apres = valeurs(contenuEnv(exemple));
  for (const k of LAISSES_VIDES) assert.equal(apres[k], '', k);
  for (const k of Object.keys(avant).filter((k) => avant[k] !== 'change-me')) assert.equal(apres[k], avant[k], k);
});
