// Preuve qu'aucune facture n'est traitée deux fois quand deux exécutions du
// workflow se chevauchent (docs/decisions.md D-038). Deux connexions
// PostgreSQL distinctes, comme deux exécutions n8n, avec le rôle mizan_app.
// Base de test dédiée : mizan_test (recréée par preparer-base.js).
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import pg from 'pg';

if (existsSync('.env')) process.loadEnvFile('.env');
const connexion = () => new pg.Client({
  host: 'localhost',
  port: 5432,
  user: 'mizan_app',
  password: process.env.MIZAN_APP_PASSWORD,
  database: 'mizan_test',
});
const sha = (n) => n.toString(16).padStart(64, '0');

let a;
let b;
before(async () => {
  a = connexion();
  b = connexion();
  await Promise.all([a.connect(), b.connect()]);
});
after(async () => {
  await Promise.all([a.end(), b.end()]);
});

test('réception : un même fichier relu en parallèle n\'est enregistré qu\'une fois', async () => {
  const recevoir = (client) => client.query(
    "SELECT nouvelle FROM enregistrer_reception('dossier', 'para.pdf', 'pdf', 'para.pdf', $1)",
    [sha(1)],
  );
  const reponses = await Promise.all(Array.from({ length: 10 }, (_, i) => recevoir(i % 2 ? a : b)));
  const nouvelles = reponses.filter((r) => r.rows[0].nouvelle === true);
  assert.equal(nouvelles.length, 1, 'une seule réception « nouvelle »');
  const { rows } = await a.query('SELECT count(*)::int AS n FROM factures WHERE fichier_sha256 = $1', [sha(1)]);
  assert.equal(rows[0].n, 1);
});

test('réservation : une facture verrouillée par une exécution est sautée par l\'autre', async () => {
  for (let i = 0; i < 2; i += 1) {
    await a.query("SELECT enregistrer_reception('dossier', $1, 'pdf', $1, $2)", [`verrou-${i}.pdf`, sha(100 + i)]);
  }
  await a.query('BEGIN');
  const premiere = await a.query('SELECT facture_id FROM reserver_facture_a_extraire()');
  // A n'a pas encore validé sa transaction : la facture est verrouillée.
  const seconde = await b.query('SELECT facture_id FROM reserver_facture_a_extraire()');
  await a.query('COMMIT');
  assert.equal(premiere.rows.length, 1);
  assert.equal(seconde.rows.length, 1, 'B n\'est pas bloquée : elle prend une autre facture');
  assert.notEqual(premiere.rows[0].facture_id, seconde.rows[0].facture_id);
});

test('réservation : deux exécutions concurrentes se partagent 30 factures sans doublon', async () => {
  // Vide la file avant ce test (factures restantes des tests précédents).
  await a.query("UPDATE factures SET statut = 'erreur_extraction' WHERE statut IN ('recue', 'en_extraction')");
  const attendues = new Set();
  for (let i = 0; i < 30; i += 1) {
    const { rows } = await a.query(
      "SELECT facture_id FROM enregistrer_reception('dossier', $1, 'pdf', $1, $2)",
      [`lot-${i}.pdf`, sha(1000 + i)],
    );
    attendues.add(String(rows[0].facture_id));
  }
  const vider = async (client) => {
    const prises = [];
    for (;;) {
      const { rows } = await client.query('SELECT facture_id FROM reserver_facture_a_extraire()');
      if (rows.length === 0) return prises;
      prises.push(String(rows[0].facture_id));
    }
  };
  const [parA, parB] = await Promise.all([vider(a), vider(b)]);
  const toutes = [...parA, ...parB];
  assert.equal(new Set(toutes).size, toutes.length, 'aucune facture réservée deux fois');
  assert.deepEqual(new Set(toutes), attendues, 'toutes les factures ont été réservées');
  assert.ok(parA.length > 0 && parB.length > 0, `les deux exécutions ont travaillé (A : ${parA.length}, B : ${parB.length})`);
});
