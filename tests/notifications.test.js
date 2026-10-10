// Contenu et actions des notifications, et messages de réponse (D-062) :
// indépendants du canal.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import {
  notificationFacture, notificationDemande, notificationRapprochement, notificationSignalement, notificationSynthese,
  notificationLot, notificationLigneARapprocher, notificationChoixAnnulation, notificationDemandeAnnulation, messageReponse,
} from '../src/decisions/notifications.js';
import { fournisseurDansLibelle } from '../src/rapprochement/appariement.js';
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
  // Version en vigueur de creer_notification : la plus récente migration qui la définit (partie « up »).
  const [migration] = readdirSync('db/migrations').sort().reverse()
    .map((f) => readFileSync(`db/migrations/${f}`, 'utf8').split('-- migrate:down')[0])
    .filter((up) => /FUNCTION creer_notification/.test(up));
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
  // Erreur interne : jamais le message technique de la base (défaut du 2026-10-10).
  const interne = messageReponse({ code: 'decision_refusee', erreur: 'interne', reference: 42,
    motif: 'duplicate key value violates unique constraint "rapprochements_paire_uk"' }).lignes.join(' ');
  assert.match(interne, /incident technique n° 42, enregistré au journal d'audit/);
  assert.doesNotMatch(interne, /duplicate|constraint|rapprochements_paire_uk/);
  assert.doesNotMatch(messageReponse({ code: 'decision_refusee', erreur: '23505', motif: 'duplicate key' }).lignes.join(' '), /duplicate/);
  assert.match(messageReponse({ code: 'decision_enregistree', action: { code: 'demander_changement_rib' } }).lignes[0], /autre responsable/);
  assert.match(messageReponse({ code: 'pas_destinataire' }).lignes[0], /pas destinée/);
  assert.match(messageReponse({ code: 'quelque_chose' }).lignes[0], /comprends/);
});

// --- Rapprochement bancaire (D-065) ------------------------------------------------------
const candidatRappr = (role) => ({ canal: 'telegram', utilisateur_id: 3, role, releve_id: 5 });
const ligneReleve = { date_operation: '2026-04-02', libelle: 'VIR EMIS INFOSAHEL SYSTEMES FACT ISS260280 DED AV AV-2026-001', debit: 12788.644 };

test('proposition sans écart : « Confirmer » et « Rejeter » ; factures et avoir détaillés', () => {
  const n = notificationRapprochement({ candidat: candidatRappr('validateur'), proposition: {
    id: 11, cas: 'net_avoir', ecart: 0, raisons: ['numéro ISS260280 dans le libellé', 'avoir AV-2026-001 déduit'], ligne: ligneReleve,
    affectations: [{ numero: 'ISS260280', raison_sociale: 'InfoSahel Systèmes', montant: 13110.111, montant_ttc: 13110.111, role: 'reglement' },
      { numero: 'AV-2026-001', montant: 321.467, role: 'imputation_avoir' }] } }, deps);
  assert.deepEqual([n.objet, n.proposition_id, n.releve_id], ['rapprochement', 11, 5]);
  assert.deepEqual(codes(n), ['confirmer_rapprochement', 'rejeter_rapprochement']);
  assert.ok(champ(n, 'Facture ISS260280'));
  assert.ok(champ(n, 'Avoir AV-2026-001'));
  assert.match(champ(n, 'Cas'), /net d'un avoir/);
});

test('proposition avec écart : un bouton « Confirmer » par motif (le motif est obligatoire)', () => {
  const n = notificationRapprochement({ candidat: candidatRappr('validateur'), proposition: {
    id: 12, cas: 'ecart', ecart: -2, raisons: ['écart de -2 TND'], ligne: { ...ligneReleve, debit: 6460.081 },
    affectations: [{ numero: 'ISS260268', montant: 6462.081, montant_ttc: 6462.081, role: 'reglement' }] } }, deps);
  assert.deepEqual(n.actions.filter((a) => a.code === 'confirmer_rapprochement').map((a) => a.params.motif_ecart),
    ['frais_bancaires', 'arrondi', 'retenue_source', 'escompte', 'autre']);
  assert.equal(n.actions.at(-1).code, 'rejeter_rapprochement');
  assert.match(n.contenu.note, /Aucun taux de retenue/);
});

test('signalement : un seul bouton « Classer » ; synthèse : aucun bouton', () => {
  const s = notificationSignalement({ candidat: candidatRappr('responsable'), facture: { id: 9, numero: '2026/153', statut: 'anomalie' },
    signalement: { id: 4, type: 'payee_non_approuvee', message: 'paiement de la facture n° 2026/153, au statut « anomalie »', ligne: ligneReleve } }, deps);
  assert.deepEqual([s.objet, s.signalement_id, s.facture_id, codes(s)], ['signalement', 4, 9, ['classer_signalement']]);
  assert.equal(s.contenu.titre, 'Paiement d\'une facture non approuvée');
  const y = notificationSynthese({ candidat: candidatRappr('validateur'), synthese: {
    releve: { fichier_nom: 'releve.csv', date_debut: '2026-01-05', date_fin: '2026-09-30', lignes: 103 },
    bilan: { confirmees_auto: 12, categorisees: 70 }, en_attente: { propositions: 13, signalements: 8 }, factures_en_retard: 2 } });
  assert.deepEqual(y.actions, []);
  assert.equal(champ(y, 'Propositions à confirmer'), '13');
  assert.equal(champ(y, 'Confirmées automatiquement'), '12');
});

test('réponses du rapprochement : confirmations et motifs de refus lisibles', () => {
  assert.equal(messageReponse({ code: 'decision_enregistree', action: { code: 'confirmer_rapprochement' } }).lignes[0], 'Rapprochement confirmé.');
  assert.match(messageReponse({ code: 'decision_refusee', erreur: 'MZ043' }).lignes[0], /motif/);
  assert.match(messageReponse({ code: 'decision_refusee', erreur: 'MZ041' }).lignes[0], /n'est plus approuvée/);
});

test('lot d\'ordres : approuver ou refuser ; RIB du référentiel, total en millimes, liste limitée', () => {
  const ordre = (k) => ({ reference: `FACT F-${k}`, beneficiaire: 'Fournisseur Canal', rib: RIB_REFERENTIEL,
    montant: 0.1, date_echeance: '2026-10-05' });
  const lot = (n) => ({ id: 5, echeances_jusqu_au: '2026-10-16', ordres: Array.from({ length: n }, (_, k) => ordre(k + 1)) });
  const n = notificationLot({ candidat: candidatRappr('responsable'), lot: lot(3) }, deps);
  assert.deepEqual([n.objet, n.lot_id, codes(n)], ['lot_paiement', 5, ['approuver_lot', 'refuser_lot']]);
  assert.equal(champ(n, 'Total'), '0,300 TND', 'somme en millimes : 0,1 + 0,1 + 0,1 sans erreur d\'arrondi');
  assert.match(champ(n, 'FACT F-1'), new RegExp(`RIB ${RIB_REFERENTIEL}`));
  assert.match(n.contenu.note, /jamais celui lu sur la facture/);
  const grand = notificationLot({ candidat: candidatRappr('responsable'), lot: lot(18) }, deps);
  assert.equal(champ(grand, 'Ordres'), '18');
  assert.equal(grand.contenu.champs.filter(([l]) => l.startsWith('FACT ')).length, 15);
  assert.match(champ(grand, '…'), /3 autre\(s\) ordre\(s\)/);
});

test('réponses des ordres : approbation, refus et lot périmé lisibles', () => {
  assert.equal(messageReponse({ code: 'decision_enregistree', action: { code: 'approuver_lot' } }).lignes[0], 'Lot d\'ordres de paiement approuvé.');
  assert.match(messageReponse({ code: 'decision_refusee', erreur: 'MZ051' }).lignes[0], /refusez ce lot/);
});

test('ligne à rapprocher : 5 candidates (fournisseur du libellé d\'abord, puis montant le plus proche), autre facture, aucune facture', () => {
  const c = (id, numero, raison_sociale, a_payer) => ({ facture_id: id, numero, raison_sociale, a_payer, date_echeance: '2026-09-30' });
  const n = notificationLigneARapprocher({ candidat: candidatRappr('validateur'), ligne_a_rapprocher: {
    ligne: { id: 40, date_operation: '2026-04-02', libelle: 'VIR EMIS TRANS-CAP LOGISTIQUE REF 88', debit: 1000 },
    candidats: [c(1, 'A-1', 'Autre Fournisseur', 1000), c(2, 'T-2', 'Trans-Cap Logistique', 1500), c(3, 'A-3', 'Autre Fournisseur', 999),
      c(4, 'A-4', 'Autre Fournisseur', 1200), c(5, 'A-5', 'Autre Fournisseur', 700), c(6, 'A-6', 'Autre Fournisseur', 5000)] } },
  { ...deps, fournisseurDansLibelle });
  assert.deepEqual([n.objet, n.ligne_releve_id], ['ligne_a_rapprocher', 40]);
  assert.deepEqual(n.actions.filter((a) => a.code === 'rapprocher_facture').map((a) => a.params.facture_id), [2, 1, 3, 4, 5]);
  assert.deepEqual(n.actions.slice(-2).map((a) => a.code), ['rapprocher_autre', 'signaler_sans_facture']);
  assert.ok(n.actions.every((a) => a.libelle.length <= 64), 'libellés de bouton courts');
});

test('réponses du rapprochement manuel : consigne du numéro, refus lisibles', () => {
  const j = messageReponse({ code: 'justification_demandee', action: { code: 'rapprocher_autre' }, contenu: { titre: 'X' }, delai_minutes: 10 });
  assert.match(j.lignes[1], /numéro de la facture, puis votre justification/);
  assert.match(messageReponse({ code: 'decision_refusee', erreur: 'MZ045' }).lignes[0], /ce numéro/);
  assert.match(messageReponse({ code: 'decision_refusee', erreur: 'MZ046' }).lignes[0], /dépasse/);
  assert.equal(messageReponse({ code: 'decision_enregistree', action: { code: 'signaler_sans_facture' } }).lignes[0],
    'Ligne signalée sans facture : un responsable l\'examinera.');
});

const propositionGroupee = {
  id: 77, cas: 'groupe', methode: 'manuel', statut: 'confirme',
  ligne: { id: 5, date_operation: '2026-04-15', libelle: 'VIR EMIS YASMINE FACT 2026/155 2026/137', debit: 6706.163 },
  affectations: [{ facture_id: 1, numero: '2026/155', raison_sociale: 'Yasmine', role: 'reglement', montant: 3380.136 },
    { facture_id: 2, numero: '2026/137', raison_sociale: 'Yasmine', role: 'reglement', montant: 3326.027 }],
};

test('choix d\'annulation : un bouton par rapprochement ; virement groupé dit explicitement, autres factures listées', () => {
  const n = notificationChoixAnnulation({ candidat: { ...candidatRappr('responsable'), recherche_annulation_id: 9 },
    choix_annulation: { numero: '2026/155', propositions: [propositionGroupee] } }, deps);
  assert.deepEqual([n.objet, n.recherche_annulation_id], ['choix_annulation', 9]);
  assert.deepEqual(n.actions.map((a) => [a.code, a.params.proposition_id]), [['demander_annulation', 77]]);
  assert.match(n.actions[0].libelle, /\(2 factures\)$/);
  assert.equal(n.contenu.alertes[0].libelle, 'Virement groupé');
  assert.match(n.contenu.alertes[0].message, /concerne aussi 2026\/137/);
  assert.ok(n.contenu.champs.some(([l]) => l === 'Facture 2026/137'));
  assert.match(n.contenu.note, /un autre responsable devra approuver/);
});

test('demande d\'annulation : approuver ou refuser ; demandeur, justification et toutes les factures du virement groupé', () => {
  const n = notificationDemandeAnnulation({ candidat: candidatRappr('responsable'), demande_annulation: {
    id: 4, demande_par_nom: 'Mohamed', justification: 'Mauvaise facture', proposition: propositionGroupee } }, deps);
  assert.deepEqual([n.objet, n.demande_annulation_id, codes(n)], ['demande_annulation', 4, ['approuver_annulation', 'refuser_annulation']]);
  assert.match(n.contenu.titre, /demandée par Mohamed/);
  assert.equal(champ(n, 'Justification'), 'Mauvaise facture');
  assert.match(n.contenu.alertes[0].message, /2026\/155, 2026\/137/);
  const simple = notificationDemandeAnnulation({ candidat: candidatRappr('responsable'), demande_annulation: {
    id: 5, demande_par_nom: 'Mohamed', justification: 'x', proposition: { ...propositionGroupee, affectations: [propositionGroupee.affectations[0]] } } }, deps);
  assert.deepEqual(simple.contenu.alertes, [], 'une seule facture : pas d\'alerte de virement groupé');
});

test('réponses de l\'annulation : recherche, introuvable, rôle, confirmations', () => {
  assert.match(messageReponse({ code: 'recherche_annulation_enregistree', numero: 'ISS260302', rapprochements: 1 }).lignes[0], /1 rapprochement\(s\) confirmé\(s\) pour ISS260302/);
  assert.match(messageReponse({ code: 'annulation_introuvable', numero: 'X' }).lignes[0], /Aucun rapprochement confirmé/);
  assert.match(messageReponse({ code: 'commande_refusee', motif: 'role' }).lignes[0], /réservée aux responsables/);
  assert.match(messageReponse({ code: 'decision_enregistree', action: { code: 'demander_annulation' } }).lignes[0], /un autre responsable/);
  assert.match(messageReponse({ code: 'decision_refusee', erreur: 'MZ018' }).lignes[0], /quatre yeux/);
});
