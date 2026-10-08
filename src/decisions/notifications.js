// Contenu et actions d'une notification, et messages de réponse, sans rien
// connaître du canal (D-062) : un canal (Telegram, plus tard l'e-mail) ne fait
// que présenter ces structures. Aucun import (recopié dans un nœud Code,
// D-041) : formaterMontant et enMillimes sont reçus en paramètre.
//
// Contenu : { objet, titre, champs: [[libellé, valeur]], alertes: [{ gravite,
// libelle, message }], note }. Actions : [{ code, libelle, params }] ; l'ordre
// compte (un bouton porte l'indice). La base vérifie tout au moment d'agir.

const LIBELLES_STATUT = Object.freeze({
  a_valider: 'À valider (montant au-dessus du seuil)',
  anomalie: 'En anomalie',
  bloquee: 'Bloquée',
});
const ORDRE_GRAVITE = ['bloquant', 'avertissement', 'validation'];
const LIBELLES_GRAVITE = Object.freeze({ bloquant: 'Bloquant', avertissement: 'Avertissement', validation: 'Validation requise' });
// Libellés courts des méthodes de vérification, pour les boutons.
const METHODES_COURTES = Object.freeze({
  rib_rappel_contact_connu: 'rappel au contact connu',
  rib_attestation_bancaire: 'attestation bancaire',
  rib_courrier_signe_verifie: 'courrier signé vérifié',
  creation_identifiant_fiscal_verifie: 'matricule vérifié (source officielle)',
  creation_attestation_bancaire: 'attestation bancaire',
  creation_contact_independant: 'contact indépendant',
});
const FORME_COURTE_MATRICULE = /^\d{7}[A-Z]$/;
const RIB_FORMAT = /^\d{20}$/;

const enAnomalie = (r) => (r.resultat === 'anomalie' || r.resultat === 'erreur') && ORDRE_GRAVITE.includes(r.gravite);

function montant(valeur, devise, deps) {
  if (valeur === null || valeur === undefined) return '—';
  return `${deps.formaterMontant(deps.enMillimes(valeur))} ${devise ?? ''}`.trim();
}

/**
 * Notification d'une facture qui attend une personne.
 * @param {{candidat: object, facture: object, fournisseur: object|null, resultats: object[], regles: {regle: string, derogeable: boolean}[]}} e
 *   fournisseur : { raison_sociale, matricule_fiscal, rib_actif } si la facture est rattachée.
 * @param {{formaterMontant: Function, enMillimes: Function}} deps
 */
function notificationFacture({ candidat, facture, fournisseur, resultats, regles }, deps) {
  const alertes = resultats.filter(enAnomalie)
    .sort((a, b) => ORDRE_GRAVITE.indexOf(a.gravite) - ORDRE_GRAVITE.indexOf(b.gravite) || a.regle.localeCompare(b.regle));
  const derogeable = new Map(regles.map((r) => [r.regle, r.derogeable]));
  const bloquantsNonDerogeables = alertes.filter((a) => a.gravite === 'bloquant' && derogeable.get(a.regle) === false);
  const responsable = candidat.role === 'responsable';

  const actions = [];
  // Une facture validée doit être rattachée à un fournisseur et numérotée
  // (contrainte de la base, D-021) : sans cela, pas de bouton « Valider ».
  const rattachee = Boolean(fournisseur) && Boolean(facture.numero);
  if (rattachee && (facture.statut !== 'bloquee' || !bloquantsNonDerogeables.length)) {
    actions.push({ code: 'valider', libelle: facture.statut === 'bloquee' ? 'Valider malgré l\'anomalie' : 'Valider' });
  }
  actions.push({ code: 'rejeter', libelle: 'Rejeter' });
  if (responsable) {
    // Fournisseur probable (C1) : proposé, rattaché seulement par décision.
    const probables = alertes.find((a) => a.regle === 'fournisseur_inconnu')?.detail?.fournisseurs_probables ?? [];
    for (const p of probables) {
      actions.push({ code: 'confirmer_fournisseur', libelle: `C'est ${p.raison_sociale} (${p.matricule_fiscal})`, params: { fournisseur_id: p.id } });
    }
    const changement = alertes.find((a) => a.regle === 'changement_rib');
    const ribDemande = changement?.detail?.rib_facture ?? changement?.detail?.propositions?.[0] ?? null;
    if (changement && fournisseur && RIB_FORMAT.test(ribDemande ?? '')) {
      actions.push({ code: 'demander_changement_rib', libelle: `Demander le changement de RIB (${ribDemande})`, params: { rib: ribDemande } });
    }
    const inconnu = alertes.find((a) => a.regle === 'fournisseur_inconnu');
    const court = inconnu?.detail?.forme_courte ?? null;
    if (inconnu && !probables.length && FORME_COURTE_MATRICULE.test(court ?? '') && facture.raison_sociale_lue) {
      const params = { raison_sociale: facture.raison_sociale_lue, matricule_fiscal: court };
      if (RIB_FORMAT.test(facture.rib_facture ?? '')) params.rib = facture.rib_facture;
      actions.push({ code: 'demander_creation_fournisseur', libelle: 'Demander la création du fournisseur', params });
    }
    actions.push({ code: 'renvoyer_aux_controles', libelle: 'Renvoyer aux contrôles' });
  }

  const nomFournisseur = fournisseur?.raison_sociale ?? facture.raison_sociale_lue ?? 'fournisseur non identifié';
  const contenu = {
    objet: 'facture',
    titre: `${facture.type_document === 'avoir' ? 'Avoir' : 'Facture'} ${facture.numero ?? 'sans numéro'} — ${nomFournisseur}`,
    statut: facture.statut,
    champs: [
      ['Statut', LIBELLES_STATUT[facture.statut] ?? facture.statut],
      ['Fournisseur', fournisseur ? `${fournisseur.raison_sociale} (${fournisseur.matricule_fiscal})` : `non identifié (lu : ${facture.matricule_fiscal_lu ?? '—'})`],
      ['Date', facture.date_facture ?? '—'],
      ['Échéance', facture.date_echeance ?? '—'],
      ['Montant TTC', montant(facture.montant_ttc, facture.devise, deps)],
      // D-058 : le paiement se fait toujours sur le RIB du référentiel.
      ['RIB de paiement', fournisseur?.rib_actif
        ? `${fournisseur.rib_actif} (RIB du référentiel ; jamais celui lu sur la facture)`
        : 'aucun : fournisseur non identifié ou sans RIB au référentiel'],
    ],
    alertes: alertes.map((a) => ({ gravite: a.gravite, libelle: LIBELLES_GRAVITE[a.gravite], regle: a.regle, message: a.message })),
    note: bloquantsNonDerogeables.length
      ? `Règle(s) non dérogeable(s) : ${bloquantsNonDerogeables.map((a) => a.regle).join(', ')}. La facture ne peut être que rejetée, ou corrigée puis renvoyée aux contrôles.`
      : 'Chaque décision demande une justification.',
  };
  return {
    canal: candidat.canal, utilisateur_id: candidat.utilisateur_id, objet: 'facture', facture_id: facture.id,
    statut_facture: facture.statut, passage_controle: candidat.passage_controle, actions, contenu,
  };
}

/**
 * Notification d'une demande sur le référentiel (quatre yeux : envoyée aux
 * autres responsables seulement, par la base).
 * @param {{candidat: object, demande: object, fournisseur: object|null, facture: object|null, methodes: object[]}} e
 */
function notificationDemande({ candidat, demande, fournisseur, facture, methodes }) {
  const d = demande.donnees ?? {};
  const changement = demande.type_demande === 'changement_rib';
  const champs = changement
    ? [['Fournisseur', fournisseur ? `${fournisseur.raison_sociale} (${fournisseur.matricule_fiscal})` : '—'],
      ['RIB actuel (référentiel)', demande.rib_actuel ?? 'aucun'], ['Nouveau RIB demandé', d.rib ?? '—']]
    : [['Raison sociale', d.raison_sociale ?? '—'], ['Matricule fiscal', d.matricule_fiscal ?? '—'], ['RIB', d.rib ?? 'aucun']];
  champs.push(['Facture', facture?.numero ?? '—'], ['Demandé par', demande.demande_par_nom ?? '—'], ['Justification', demande.justification]);
  const actions = methodes.filter((m) => m.type_demande === demande.type_demande).map((m) => ({
    code: 'approuver', libelle: `Approuver : ${METHODES_COURTES[m.code] ?? m.libelle}`, params: { methode_verification: m.code },
  }));
  actions.push({ code: 'refuser', libelle: 'Refuser' });
  return {
    canal: candidat.canal, utilisateur_id: candidat.utilisateur_id, objet: 'demande', demande_id: demande.id,
    facture_id: demande.facture_id ?? null, actions,
    contenu: {
      objet: 'demande',
      titre: `Demande n° ${demande.id} : ${changement ? 'changement de RIB' : 'création d\'un fournisseur'}`,
      champs,
      alertes: [],
      note: 'Vérifiez par un moyen indépendant de la facture avant d\'approuver (quatre yeux, D-056). Choisissez la méthode de vérification utilisée.',
    },
  };
}

// Messages renvoyés selon le résultat de recevoir_evenement().
const MOTIFS_REFUS = Object.freeze({
  MZ010: 'la facture a changé de statut entre-temps : décision impossible.',
  MZ011: 'la facture a changé de statut entre-temps : décision impossible.',
  MZ012: 'votre compte est inactif.',
  MZ013: 'justification trop courte.',
  MZ014: 'votre rôle ne permet pas cette décision.',
  MZ015: 'règle non dérogeable : la facture ne peut être que rejetée, ou corrigée puis renvoyée aux contrôles.',
  MZ016: 'correction non admise.',
  MZ018: 'quatre yeux : vous ne pouvez pas décider de votre propre demande.',
  MZ019: 'données de la demande invalides.',
  MZ020: 'le RIB actif date d\'aujourd\'hui : changement à refaire demain.',
});
const CONFIRMATIONS = Object.freeze({
  valider: 'Facture validée.',
  rejeter: 'Facture rejetée.',
  renvoyer_aux_controles: 'Facture renvoyée aux contrôles.',
  confirmer_fournisseur: 'Fournisseur confirmé ; facture renvoyée aux contrôles.',
  demander_changement_rib: 'Demande de changement de RIB enregistrée : un autre responsable doit l\'approuver.',
  demander_creation_fournisseur: 'Demande de création du fournisseur enregistrée : un autre responsable doit l\'approuver.',
  approuver: 'Demande approuvée : référentiel mis à jour, facture(s) renvoyée(s) aux contrôles.',
  refuser: 'Demande refusée.',
});

/**
 * Message de réponse à un événement. Renvoie null s'il ne faut rien répondre.
 * @returns {{lignes: string[], attendJustification: boolean, alerteCourte: string}|null}
 */
function messageReponse(r) {
  const avec = (lignes, alerteCourte, attendJustification = false) => ({ lignes, alerteCourte, attendJustification });
  switch (r.code) {
    case 'deja_traite': return null;
    case 'inscription_reussie': return avec([`Inscription réussie : ${r.nom}.`, 'Vous recevrez ici les factures à valider.'], 'Inscription réussie');
    case 'inscription_refusee': return avec(['Code d\'inscription invalide, déjà utilisé ou expiré.'], 'Code refusé');
    case 'adresse_deja_inscrite': return avec(['Ce compte est déjà inscrit.'], 'Déjà inscrit');
    case 'expediteur_inconnu': return avec(['Accès réservé. Pour vous inscrire : /start suivi de votre code.'], 'Accès réservé');
    case 'justification_demandee':
      return avec([`Action : ${r.action?.libelle ?? r.action?.code} — ${r.contenu?.titre ?? ''}`.trim(),
        `Répondez à ce message par votre justification, dans les ${r.delai_minutes} minutes.`], 'Justification demandée', true);
    case 'justification_trop_tard': return avec(['Délai dépassé : rien n\'a été appliqué. Touchez de nouveau le bouton.'], 'Délai dépassé');
    case 'aucune_action_en_attente': return avec(['Aucune décision en attente. Touchez d\'abord un bouton d\'une notification.'], 'Aucune décision en attente');
    case 'decision_enregistree': return avec([CONFIRMATIONS[r.action?.code] ?? 'Décision enregistrée.'], 'Décision enregistrée');
    case 'decision_refusee':
      return avec([`Refusé : ${MOTIFS_REFUS[r.erreur] ?? `la base a refusé la décision (${r.motif}).`}`, 'Rien n\'a été appliqué.'], 'Refusé');
    case 'pas_destinataire': return avec(['Cette notification ne vous est pas destinée.'], 'Notification d\'une autre personne');
    case 'notification_perimee': return avec(['Cette notification n\'est plus valable : la facture a changé d\'état.'], 'Notification périmée');
    case 'notification_expiree': return avec(['Cette notification a expiré.'], 'Notification expirée');
    case 'bouton_inconnu': case 'action_inconnue': return avec(['Bouton non reconnu.'], 'Bouton non reconnu');
    default: return avec(['Je ne comprends que les boutons des notifications et les justifications.'], 'Non compris');
  }
}

export {
  LIBELLES_STATUT, METHODES_COURTES, notificationFacture, notificationDemande, messageReponse,
};
