// Contenu et actions des notifications, et messages de réponse (D-062) :
// indépendants du canal.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { notificationFacture, notificationDemande, messageReponse } from '../src/decisions/notifications.js';
import { formaterMontant, enMillimes } from '../src/montants.js';

const deps = { formaterMontant, enMillimes };
const REGLES = [
  { regle: 'changement_rib', derogeable: false }, { regle: 'coherence_tva', derogeable: true },
  { regle: 'fournisseur_inconnu', derogeable: true }, { regle: 'devise', derogeable: true },
  { regle: 'seuil_validation', derogeable: true }, { regle: 'matricule_suffixe', derogeable: true },
];
const RIB_REFERENTIEL = '99001000000000000165';
const RIB_FACTURE = '99003000000000000269';
const facture = (modif = {}) => ({
  id: 7, statut: 'a_valider', type_document: 'facture', numero: 'FA-2026-0007', date_facture: '2026-03-01',
  date_echeance: '2026-03-31', devise: 'TND', montant_ttc: 35701.5, matricule_fiscal_lu: '9912377K/A/M/000',
  raison_sociale_lue: 'Fournisseur Canal', rib_facture: RIB_FACTURE, ...modif,
});
const fournisseur = { raison_sociale: 'Fournisseur Canal', matricule_fiscal: '9912377K', rib_actif: RIB_REFERENTIEL };
const candidat = (role = 'validateur') => ({ canal: 'telegram', utilisateur_id: 3, role, passage_controle: 12 });
const resultat = (regle, gravite, message, detail = {}) => ({ regle, resultat: 'anomalie', gravite, message, detail });
const codes = (n) => n.actions.map((a) => a.code);
const champ = (n, libelle) => n.contenu.champs.find(([l]) => l === libelle)?.[1];

test('facture à valider, validateur : valider ou rejeter ; RIB de paiement = RIB du référentiel (D-058)', () => {
  const n = notificationFacture({ candidat: candidat(), facture: facture(), fournisseur,
    resultats: [resultat('seuil_validation', 'validation', 'TTC au-dessus du seuil')], regles: REGLES }, deps);
  assert.deepEqual(codes(n), ['valider', 'rejeter']);
  assert.equal(n.statut_facture, 'a_valider');
  assert.equal(n.passage_controle, 12);
  assert.match(champ(n, 'RIB de paiement'), new RegExp(`^${RIB_REFERENTIEL}`));
  assert.ok(!JSON.stringify(n.contenu.champs).includes(RIB_FACTURE), 'le RIB lu n\'est jamais présenté comme RIB de paiement');
  assert.equal(champ(n, 'Montant TTC').replace(/\s/g, ' '), '35 701,500 TND', 'séparateur des milliers insécable');
});

test('un responsable peut aussi renvoyer aux contrôles', () => {
  const n = notificationFacture({ candidat: candidat('responsable'), facture: facture(), fournisseur, resultats: [], regles: REGLES }, deps);
  assert.deepEqual(codes(n), ['valider', 'rejeter', 'renvoyer_aux_controles']);
});

test('bloquée par un changement de RIB (non dérogeable) : pas de « valider », demande de changement proposée', () => {
  const n = notificationFacture({ candidat: candidat('responsable'), facture: facture({ statut: 'bloquee' }), fournisseur,
    resultats: [resultat('changement_rib', 'bloquant', 'RIB différent du RIB actif', { rib_facture: RIB_FACTURE, rib_actif: RIB_REFERENTIEL, propositions: [] })],
    regles: REGLES }, deps);
  assert.deepEqual(codes(n), ['rejeter', 'demander_changement_rib', 'renvoyer_aux_controles']);
  assert.deepEqual(n.actions[1].params, { rib: RIB_FACTURE });
  assert.match(n.contenu.note, /non dérogeable/);
  assert.match(champ(n, 'RIB de paiement'), new RegExp(`^${RIB_REFERENTIEL}`), 'le paiement reste sur le RIB du référentiel');
});

test('règle de Mohamed (D-053) : RIB vide mais proposition → le changement demandé porte sur le RIB proposé', () => {
  const n = notificationFacture({ candidat: candidat('responsable'), facture: facture({ statut: 'bloquee', rib_facture: null }), fournisseur,
    resultats: [resultat('changement_rib', 'bloquant', 'RIB trouvé dans le texte', { rib_facture: null, propositions: [RIB_FACTURE] })],
    regles: REGLES }, deps);
  assert.deepEqual(n.actions.find((a) => a.code === 'demander_changement_rib').params, { rib: RIB_FACTURE });
});

test('bloquée par une règle dérogeable : « Valider malgré l\'anomalie » pour un responsable', () => {
  const n = notificationFacture({ candidat: candidat('responsable'), facture: facture({ statut: 'bloquee' }), fournisseur,
    resultats: [resultat('coherence_tva', 'bloquant', 'TVA fausse')], regles: REGLES }, deps);
  assert.equal(n.actions[0].code, 'valider');
  assert.equal(n.actions[0].libelle, 'Valider malgré l\'anomalie');
});

test('fournisseur probable (C1) : bouton de confirmation, jamais de rattachement sans décision', () => {
  const probable = { id: 2, raison_sociale: 'Médina Connect Télécom', matricule_fiscal: '9917566L', par: ['rib'] };
  const n = notificationFacture({ candidat: candidat('responsable'), facture: facture({ statut: 'bloquee', matricule_fiscal_lu: '991756L/A/M/000' }),
    fournisseur: null, resultats: [resultat('fournisseur_inconnu', 'bloquant', 'non identifié', { forme_courte: null, fournisseurs_probables: [probable] })],
    regles: REGLES }, deps);
  const confirmer = n.actions.find((a) => a.code === 'confirmer_fournisseur');
  assert.deepEqual(confirmer.params, { fournisseur_id: 2 });
  assert.ok(!codes(n).includes('demander_creation_fournisseur'), 'un fournisseur probable existe : pas de création');
  // Constat du 2026-10-08 (D008, D011) : « Valider » était proposé sans fournisseur rattaché,
  // alors que la base refuse toute validation sans fournisseur (D-021).
  assert.ok(!codes(n).includes('valider'), 'pas de validation sans fournisseur rattaché');
  const sansNumero = notificationFacture({ candidat: candidat('responsable'), facture: facture({ numero: null }), fournisseur,
    resultats: [], regles: REGLES }, deps);
  assert.ok(!codes(sansNumero).includes('valider'), 'pas de validation sans numéro');
  assert.match(champ(n, 'RIB de paiement'), /^aucun/);
});

test('fournisseur inconnu sans probable, matricule valide : demande de création proposée', () => {
  const n = notificationFacture({ candidat: candidat('responsable'), facture: facture({ statut: 'bloquee', raison_sociale_lue: 'Djerba Express' }),
    fournisseur: null, resultats: [resultat('fournisseur_inconnu', 'bloquant', 'absent du référentiel', { forme_courte: '9900001A', fournisseurs_probables: [] })],
    regles: REGLES }, deps);
  assert.deepEqual(n.actions.find((a) => a.code === 'demander_creation_fournisseur').params,
    { raison_sociale: 'Djerba Express', matricule_fiscal: '9900001A', rib: RIB_FACTURE });
});

test('alertes : bloquant, puis avertissement, puis validation ; « info » et « ok » exclus', () => {
  const n = notificationFacture({ candidat: candidat('responsable'), facture: facture({ statut: 'bloquee' }), fournisseur,
    resultats: [resultat('seuil_validation', 'validation', 'seuil'), resultat('devise', 'avertissement', 'EUR'),
      resultat('coherence_tva', 'bloquant', 'TVA'), resultat('matricule_suffixe', 'info', 'suffixe'),
      { regle: 'dates', resultat: 'ok', gravite: 'info', message: 'ok' }], regles: REGLES }, deps);
  assert.deepEqual(n.contenu.alertes.map((a) => a.regle), ['coherence_tva', 'devise', 'seuil_validation']);
});

test('demande de changement de RIB : une approbation par méthode de vérification, et refuser', () => {
  const methodes = [
    { code: 'rib_rappel_contact_connu', type_demande: 'changement_rib', libelle: 'Rappel' },
    { code: 'rib_attestation_bancaire', type_demande: 'changement_rib', libelle: 'Attestation' },
    { code: 'creation_contact_independant', type_demande: 'creation_fournisseur', libelle: 'Contact' },
  ];
  const n = notificationDemande({ candidat: candidat('responsable'),
    demande: { id: 4, type_demande: 'changement_rib', facture_id: 7, donnees: { rib: RIB_FACTURE }, rib_actuel: RIB_REFERENTIEL,
      demande_par_nom: 'Mohamed', justification: 'Nouveau RIB sur la facture' },
    fournisseur, facture: { numero: 'FA-2026-0007' }, methodes });
  assert.deepEqual(n.actions.map((a) => [a.code, a.params?.methode_verification ?? null]),
    [['approuver', 'rib_rappel_contact_connu'], ['approuver', 'rib_attestation_bancaire'], ['refuser', null]]);
  assert.equal(champ(n, 'RIB actuel (référentiel)'), RIB_REFERENTIEL);
  assert.equal(champ(n, 'Nouveau RIB demandé'), RIB_FACTURE);
  assert.equal(n.objet, 'demande');
  assert.equal(n.demande_id, 4);
});

test('les codes d\'action produits sont ceux qu\'accepte la base (creer_notification)', () => {
  const migration = readFileSync('db/migrations/20261008090000_canaux_notifications.sql', 'utf8');
  const liste = migration.match(/WHERE a ->> 'code' NOT IN \(([^)]*)\)/)[1];
  const acceptes = [...liste.matchAll(/'([a-z_]+)'/g)].map((m) => m[1]).sort();
  const source = readFileSync('src/decisions/notifications.js', 'utf8');
  const produits = [...new Set([...source.matchAll(/code: '([a-z_]+)'/g)].map((m) => m[1]))].sort();
  assert.deepEqual(produits, acceptes);
});

test('réponses : une par résultat ; rien pour un événement déjà traité ; motif de refus lisible', () => {
  assert.equal(messageReponse({ code: 'deja_traite' }), null);
  const j = messageReponse({ code: 'justification_demandee', action: { libelle: 'Valider' }, contenu: { titre: 'Facture X' }, delai_minutes: 10 });
  assert.equal(j.attendJustification, true);
  assert.match(j.lignes.join(' '), /10 minutes/);
  assert.match(messageReponse({ code: 'decision_refusee', erreur: 'MZ015', motif: '…' }).lignes[0], /non dérogeable/);
  assert.match(messageReponse({ code: 'decision_refusee', erreur: 'XX000', motif: 'autre' }).lignes[0], /autre/);
  assert.match(messageReponse({ code: 'decision_enregistree', action: { code: 'demander_changement_rib' } }).lignes[0], /autre responsable/);
  assert.match(messageReponse({ code: 'pas_destinataire' }).lignes[0], /pas destinée/);
  assert.match(messageReponse({ code: 'quelque_chose' }).lignes[0], /comprends/);
});
