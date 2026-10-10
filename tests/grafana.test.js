// Tableau de bord Grafana (D-068, D-070) : fichiers du dépôt. Le fichier JSON
// est celui du générateur ; une seule source de données, en mizan_lecture,
// mot de passe venu de l'environnement ; requêtes en lecture des vues de
// restitution seulement.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { tableauDeBord, SOURCE } from '../scripts/construire-tableau-de-bord.js';

const fichier = JSON.parse(readFileSync('grafana/dashboards/mizan-restitution.json', 'utf8'));
const VUES = ['a_traiter', 'echeancier', 'ordres_paiement', 'paiements', 'releves', 'tresorerie_prevue', 'tva_factures'];

test('le tableau de bord du dépôt est celui du générateur (aucune modification à la main)', () => {
  assert.deepEqual(fichier, JSON.parse(JSON.stringify(tableauDeBord())));
});

test('chaque requête : source mizan-lecture, mode code, lecture seule des vues de restitution', () => {
  const requetes = fichier.panels.flatMap((p) => p.targets.map((t) => ({ titre: p.title, ...t })));
  assert.ok(requetes.length >= 10);
  for (const r of requetes) {
    assert.deepEqual(r.datasource, SOURCE, r.titre);
    assert.equal(r.editorMode, 'code', r.titre);
    assert.equal(r.rawQuery, true, r.titre);
    assert.match(r.rawSql, /^SELECT\b/, r.titre);
    assert.doesNotMatch(r.rawSql, /\b(INSERT|UPDATE|DELETE|DROP|ALTER|CREATE|GRANT|TRUNCATE|COPY)\b|;|\bpublic\./i, r.titre);
    const lues = [...r.rawSql.matchAll(/\bFROM\s+([a-z_]+)/gi)].map((m) => m[1]);
    assert.ok(lues.length && lues.every((v) => VUES.includes(v)), `${r.titre} : ${lues}`);
  }
  assert.equal(fichier.editable, false);
});

test('provisionnement : une seule source, mizan_lecture, mot de passe pris dans l\'environnement, non modifiable', () => {
  const sources = readdirSync('grafana/provisioning/datasources');
  assert.deepEqual(sources, ['mizan.yaml']);
  const yaml = readFileSync('grafana/provisioning/datasources/mizan.yaml', 'utf8');
  assert.equal(yaml.match(/^\s*- name:/gm).length, 1);
  assert.match(yaml, /^\s+user: mizan_lecture$/m);
  assert.match(yaml, /^\s+password: \$MIZAN_LECTURE_PASSWORD$/m);
  assert.match(yaml, /^\s+uid: mizan-lecture$/m);
  assert.match(yaml, /^\s+editable: false$/m);
  const tableaux = readFileSync('grafana/provisioning/dashboards/mizan.yaml', 'utf8');
  assert.match(tableaux, /allowUiUpdates: false/);
});
