// Workflow « Import et rapprochement du relevé » (D-065), et préparation des
// notifications de rapprochement : structure, et exécution du code GÉNÉRÉ des
// nœuds Code sur le vrai relevé synthétique.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const lire = (chemin) => JSON.parse(readFileSync(chemin, 'utf8'));
const releve = lire('workflows/releve-rapprochement.json');
const envoi = lire('workflows/notifications-telegram.json');
const noeud = (wf, nom) => wf.nodes.find((n) => n.name === nom);

async function executer(wf, nom, { entrees, sorties = {} }) {
  const elements = entrees.map((json, i) => ({ json, pairedItem: { item: i } }));
  const contexte = vm.createContext({
    $input: { first: () => elements[0], all: () => elements },
    $: (cible) => ({ all: () => sorties[cible].map((json) => ({ json })), first: () => ({ json: sorties[cible][0] }) }),
    $execution: { id: 'exec-test' }, $runIndex: 0, Date,
  });
  const r = await vm.runInContext(`(async () => {\n${noeud(wf, nom).parameters.jsCode}\n})()`, contexte);
  return JSON.parse(JSON.stringify(r)).map((x) => x.json);
}

test('relevé : dossier data/entrant/releves, lecture texte UTF-8 en gardant le nom du fichier', () => {
  assert.match(noeud(releve, 'Lister les relevés déposés').parameters.fileSelector, /^\/data\/entrant\/releves\//);
  const texte = noeud(releve, 'Lire le texte du relevé');
  assert.equal(texte.typeVersion, 1.1);
  assert.deepEqual([texte.parameters.operation, texte.parameters.destinationKey, texte.parameters.options.keepSource], ['text', 'texte', 'json']);
});

test('relevé : empreinte calculée par la base, une requête par élément, rien enregistré sans nouveauté', () => {
  assert.match(noeud(releve, 'Enregistrer le relevé').parameters.query, /enregistrer_releve\(\$1::jsonb \|\| jsonb_build_object\('fichier_sha256', encode\(sha256/);
  for (const nom of ['Enregistrer le relevé', 'Contexte du rapprochement', 'Enregistrer le rapprochement']) {
    assert.equal(noeud(releve, nom).parameters.options.queryBatching, 'independently', nom);
  }
  assert.deepEqual(releve.connections['Quelque chose à enregistrer ?'].main.map((s) => s.map((l) => l.node)), [['Enregistrer le rapprochement']],
    'sortie « faux » vide : pas de rapproche_le mis à jour, donc pas de synthèse renvoyée à chaque passage');
});

test('relevé : le code généré lit le vrai relevé synthétique et prépare l\'import', async () => {
  const csv = readFileSync('data/synthetic/releve/releve-2026-01-01_2026-09-30.csv', 'utf8');
  const [sortie] = await executer(releve, 'Préparer l\'import', { entrees: [{ texte: csv, fileName: 'releve-2026-01-01_2026-09-30.csv' }] });
  const attendu = lire('data/synthetic/releve/appariements-attendus.json');
  assert.equal(sortie.payload.lignes.length, 103);
  assert.deepEqual([sortie.payload.solde_initial, sortie.payload.solde_final], [attendu.solde_initial, attendu.solde_final]);
  assert.deepEqual([sortie.payload.rib_compte, sortie.payload.fichier_nom, sortie.payload.execution_n8n_id],
    [attendu.compte.rib, 'releve-2026-01-01_2026-09-30.csv', 'exec-test']);
  assert.equal(sortie.texte, csv, 'le texte suit, pour l\'empreinte calculée en base');
});

test('relevé : le code généré apparie (exact automatique, chèque proposé, loyer rangé, sortie inconnue signalée)', async () => {
  const contexte = {
    lignes: [
      { id: 1, numero_ligne: 1, date_operation: '2026-03-20', libelle: 'VIR EMIS X FACT F-1', debit: 100, credit: 0 },
      { id: 2, numero_ligne: 2, date_operation: '2026-03-21', libelle: 'CHEQUE N 1', debit: 200, credit: 0 },
      { id: 3, numero_ligne: 3, date_operation: '2026-03-22', libelle: 'PRLV LOYER LOCAUX', debit: 50, credit: 0 },
      { id: 4, numero_ligne: 4, date_operation: '2026-03-23', libelle: 'VIR EMIS INCONNU', debit: 7, credit: 0 }],
    factures: [
      { id: 10, statut: 'conforme', type_document: 'facture', numero: 'F-1', devise: 'TND', montant_ttc: 100, date_facture: '2026-03-01', raison_sociale: 'X', deja_paye: 0 },
      { id: 11, statut: 'validee', type_document: 'facture', numero: 'F-2', devise: 'TND', montant_ttc: 200, date_facture: '2026-03-01', raison_sociale: 'Y', deja_paye: 0 }],
    rejetees: [], categories: [{ code: 'loyer', sens: 'debit', motif: '^PRLV LOYER\\b' }],
    parametres: { 'rapprochement.tolerance_ecart': 5, 'rapprochement.fenetre_jours': 180 },
  };
  const [sortie] = await executer(releve, 'Apparier', { entrees: [{ contexte }], sorties: { 'Enregistrer le relevé': [{ releve_id: 9, nouveau: true }] } });
  assert.equal(sortie.a_enregistrer, true);
  assert.equal(sortie.payload.releve_id, 9);
  assert.deepEqual(sortie.payload.propositions.map((p) => [p.ligne_releve_id, p.auto]), [[1, true], [2, false]]);
  assert.deepEqual(sortie.payload.categories, [{ ligne_releve_id: 3, categorie: 'loyer' }]);
  assert.deepEqual(sortie.payload.signalements.map((s) => [s.ligne_releve_id, s.type]), [[4, 'sortie_sans_facture']]);
  const [rien] = await executer(releve, 'Apparier', { entrees: [{ contexte: { ...contexte, lignes: [] } }], sorties: { 'Enregistrer le relevé': [{ releve_id: 9 }] } });
  assert.equal(rien.a_enregistrer, false, 'relevé déjà traité : rien à enregistrer');
});

test('notifications : le code généré prépare aussi propositions, signalements et synthèses', async () => {
  const candidat = (objet, role) => ({ canal: 'telegram', objet, utilisateur_id: 3, role, adresse: '555', releve_id: 9, proposition_id: 4, signalement_id: 5 });
  const ligne = { date_operation: '2026-04-02', libelle: 'CHEQUE N 1', debit: 200 };
  const sorties = await executer(envoi, 'Préparer les notifications', { entrees: [
    { donnees: { candidat: candidat('rapprochement', 'validateur'), proposition: { id: 4, cas: 'ecart', ecart: -2, raisons: ['x'], ligne,
      affectations: [{ numero: 'F-2', montant: 202, montant_ttc: 202, role: 'reglement' }] } } },
    { donnees: { candidat: candidat('signalement', 'responsable'), facture: null,
      signalement: { id: 5, type: 'sortie_sans_facture', message: 'sortie sans facture', ligne } } },
    { donnees: { candidat: candidat('synthese', 'validateur'), synthese: { releve: { fichier_nom: 'r.csv', date_debut: 'a', date_fin: 'b', lignes: 1 },
      bilan: {}, en_attente: { propositions: 1, signalements: 1 }, factures_en_retard: 0 } } },
    // Rapprochement manuel : le code généré doit disposer de fournisseurDansLibelle (src/rapprochement/appariement.js).
    { donnees: { candidat: candidat('ligne_a_rapprocher', 'validateur'), ligne_a_rapprocher: {
      ligne: { id: 40, date_operation: '2026-04-02', libelle: 'VIR EMIS TRANS-CAP LOGISTIQUE', debit: 200 },
      candidats: [{ facture_id: 1, numero: 'A-1', raison_sociale: 'Autre', a_payer: 200 },
        { facture_id: 2, numero: 'T-2', raison_sociale: 'Trans-Cap Logistique', a_payer: 900 }] } } },
  ] });
  assert.deepEqual(sorties.map((s) => [s.notification.objet, s.notification.actions.length, s.adresse]),
    [['rapprochement', 6, '555'], ['signalement', 1, '555'], ['synthese', 0, '555'], ['ligne_a_rapprocher', 4, '555']]);
  assert.equal(sorties[3].notification.actions[0].params.facture_id, 2, 'fournisseur reconnu dans le libellé : en premier');
  assert.equal(sorties[0].notification.proposition_id, 4);
});
