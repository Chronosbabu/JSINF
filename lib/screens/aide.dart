import 'package:flutter/material.dart';

/// ====================================================================
/// ÉCRAN D'AIDE
/// ====================================================================
///
/// Ce fichier contient UNIQUEMENT du texte explicatif. Il décrit, bouton
/// par bouton et champ par champ, le rôle de chaque élément présent dans
/// l'écran "Paramètres" (settings_screen.dart). Il est pensé pour un
/// utilisateur qui se sent perdu ou qui ne sait pas à quoi sert telle ou
/// telle option.
///
/// Pour ajouter une nouvelle explication plus tard (si un nouveau bouton
/// est ajouté dans les Paramètres), il suffit d'ajouter un nouvel objet
/// _HelpSection (ou _HelpItem) dans la liste plus bas : aucune autre
/// modification n'est nécessaire.
class AideScreen extends StatelessWidget {
  const AideScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Aide - Comment utiliser les Paramètres"),
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8, vertical: 12),
            child: Text(
              "Cette page explique à quoi sert chaque bouton, champ ou menu "
                  "déroulant que vous trouverez dans l'écran \"Paramètres\". "
                  "Touchez une section ci-dessous pour l'ouvrir et lire son "
                  "explication. Si vous êtes perdu, lisez les sections dans "
                  "l'ordre : elles suivent exactement l'ordre d'affichage de "
                  "l'écran Paramètres.",
              style: TextStyle(fontSize: 14, color: Colors.grey),
            ),
          ),

          // ================== NOM DE L'ÉTABLISSEMENT ==================
          _HelpSection(
            icon: Icons.school,
            title: "Nom de l'établissement",
            children: [
              _HelpItem(
                title: "Champ de texte \"Nom de l'établissement\"",
                explanation:
                "Permet d'écrire ou de modifier le nom officiel de votre "
                    "école. Ce nom apparaîtra partout dans l'application : "
                    "sur l'écran d'accueil, dans les rapports PDF générés, "
                    "et dans les sauvegardes envoyées au serveur.",
              ),
              _HelpItem(
                title: "Bouton \"Enregistrer\"",
                explanation:
                "Sauvegarde le nouveau nom que vous avez tapé. Vous devrez "
                    "entrer votre mot de passe de sauvegarde pour confirmer "
                    "ce changement (sécurité). Si le champ est vide, "
                    "l'enregistrement est refusé.",
              ),
            ],
          ),

          // ================== GESTION DES SECTIONS ==================
          _HelpSection(
            icon: Icons.category,
            title: "Gestion des Sections",
            children: [
              _HelpItem(
                title: "Bouton \"Ajouter une nouvelle Section\"",
                explanation:
                "Crée une nouvelle section dans votre école (en plus de "
                    "Maternelle, Primaire, Secondaire qui existent par "
                    "défaut). Utile pour des sections spéciales comme "
                    "\"Électricité\", \"Électronique\", \"Coupe et Couture\", "
                    "etc. Un frais mensuel par défaut de 35000 FC est "
                    "attribué automatiquement à la nouvelle section ; vous "
                    "pourrez le modifier plus bas.",
              ),
              _HelpItem(
                title: "Les étiquettes (chips) avec une croix ✕",
                explanation:
                "Chaque étiquette représente une section existante. Le "
                    "petit ✕ permet de SUPPRIMER cette section. Attention : "
                    "supprimer une section efface aussi tous les frais, "
                    "toutes les exceptions et toutes les classes qui lui "
                    "étaient rattachés. Vous devez garder au moins une "
                    "section ; l'application refusera de supprimer la "
                    "dernière section restante.",
              ),
            ],
          ),

          // ================== FRAIS MENSUEL PAR SECTION/CLASSE ==================
          _HelpSection(
            icon: Icons.payments,
            title: "Frais Mensuel par Section ou par Classe",
            children: [
              _HelpItem(
                title: "Menu déroulant \"Section\"",
                explanation:
                "Choisissez la section pour laquelle vous voulez définir "
                    "ou modifier un frais mensuel (ex: Primaire, "
                    "Secondaire, ou une section personnalisée comme "
                    "Électricité).",
              ),
              _HelpItem(
                title: "Champ + bouton \"Ajouter une classe à ...\"",
                explanation:
                "Pour les sections Maternelle, Primaire et Secondaire, les "
                    "numéros de classe (1ère, 2ème, 6ème...) sont créés "
                    "automatiquement. Mais pour une section personnalisée "
                    "(Électricité, Électronique...), AUCUNE classe n'existe "
                    "par défaut. Ce champ permet d'en ajouter manuellement "
                    "(par exemple \"1ère\", \"2ème\", ou même \"Niveau 1\"). "
                    "Une fois ajoutée, la classe apparaît dans le menu "
                    "déroulant juste en dessous, et aussi dans les "
                    "Exceptions et dans la liste des élèves.",
              ),
              _HelpItem(
                title: "Menu déroulant \"Toutes les classes\" / classe précise",
                explanation:
                "Si vous laissez \"Toutes les classes\" sélectionné, le "
                    "frais que vous allez définir s'appliquera à TOUTE la "
                    "section, peu importe la classe de l'élève. Si vous "
                    "choisissez une classe précise (ex: \"1ère\"), le frais "
                    "ne s'appliquera qu'aux élèves de cette classe précise "
                    "dans cette section — utile quand différentes classes "
                    "d'une même section paient des montants différents.",
              ),
              _HelpItem(
                title: "Champ \"Frais mensuel pour ...\"",
                explanation:
                "Tapez ici le montant en Francs Congolais (FC) que les "
                    "élèves concernés doivent payer chaque mois.",
              ),
              _HelpItem(
                title: "Bouton \"Enregistrer pour Toute la Section\" / "
                    "\"Enregistrer pour [classe] Uniquement\"",
                explanation:
                "Sauvegarde le montant tapé. Le texte du bouton change "
                    "automatiquement selon votre choix au-dessus : soit "
                    "vous enregistrez pour toute la section, soit "
                    "uniquement pour la classe sélectionnée. Une "
                    "vérification du mot de passe de sauvegarde est "
                    "demandée.",
              ),
              _HelpItem(
                title: "Bouton rouge \"Retirer l'exception pour ...\"",
                explanation:
                "N'apparaît que si un frais spécifique existe déjà pour la "
                    "classe sélectionnée. Permet de supprimer ce frais "
                    "particulier : la classe retombera alors automatiquement "
                    "sur le frais général de toute la section.",
              ),
              _HelpItem(
                title: "Liste \"Frais spécifiques déjà définis pour cette section\"",
                explanation:
                "Affiche un récapitulatif de toutes les classes de la "
                    "section actuellement sélectionnée qui ont un montant "
                    "différent de celui de la section entière. Cela vous "
                    "permet de vérifier rapidement ce qui a déjà été "
                    "configuré.",
              ),
            ],
          ),

          // ================== EXCEPTIONS ==================
          _HelpSection(
            icon: Icons.event_note,
            title: "Exceptions par Mois, par Section ou par Classe",
            children: [
              _HelpItem(
                title: "À quoi sert une \"Exception\" ?",
                explanation:
                "Une exception permet de fixer un montant DIFFÉRENT pour "
                    "UN SEUL mois précis, sans changer le frais mensuel "
                    "habituel des autres mois. Par exemple : si en "
                    "Septembre les élèves doivent payer un montant plus "
                    "élevé (frais d'inscription inclus), vous créez une "
                    "exception pour le mois de Septembre uniquement.",
              ),
              _HelpItem(
                title: "Menu déroulant \"Section\"",
                explanation:
                "Choisissez la section concernée par l'exception.",
              ),
              _HelpItem(
                title: "Menu déroulant \"Toutes les classes\" / classe précise",
                explanation:
                "Comme pour les frais mensuels : \"Toutes les classes\" "
                    "applique l'exception à toute la section pour ce "
                    "mois-là, alors qu'une classe précise limite "
                    "l'exception à cette seule classe.",
              ),
              _HelpItem(
                title: "Menu déroulant \"Choisir un mois\"",
                explanation:
                "Sélectionnez le mois auquel l'exception doit s'appliquer "
                    "(Septembre, Octobre, etc.).",
              ),
              _HelpItem(
                title: "Bouton \"Ajouter / Modifier Exception\"",
                explanation:
                "Ouvre une fenêtre où vous tapez le montant de "
                    "l'exception. Si vous laissez le champ vide et "
                    "validez, l'exception existante (si elle existe) sera "
                    "supprimée et le mois retombera sur le frais normal.",
              ),
            ],
          ),

          // ================== ADMINISTRATIONS ==================
          _HelpSection(
            icon: Icons.account_balance,
            title: "Administrations & Répartition (%)",
            children: [
              _HelpItem(
                title: "Liste des administrations",
                explanation:
                "Chaque ligne représente une administration ou un service "
                    "(ex: Direction, Préfecture, Entretien...) qui reçoit "
                    "un pourcentage des frais collectés. Le pourcentage "
                    "affiché indique la part qui lui revient.",
              ),
              _HelpItem(
                title: "Icône crayon (modifier)",
                explanation:
                "Permet de changer le nom ou le pourcentage d'une "
                    "administration déjà créée.",
              ),
              _HelpItem(
                title: "Bouton \"Ajouter Administration\"",
                explanation:
                "Crée une nouvelle administration avec un nom et un "
                    "pourcentage. Ce pourcentage sera utilisé pour calculer "
                    "automatiquement la répartition de l'argent collecté "
                    "dans les rapports PDF.",
              ),
            ],
          ),

          // ================== ANNÉE SCOLAIRE ==================
          _HelpSection(
            icon: Icons.calendar_today,
            title: "Année Scolaire",
            children: [
              _HelpItem(
                title: "Menu déroulant des années",
                explanation:
                "Permet de choisir l'année scolaire active (ex: "
                    "2025-2026). Toutes les données affichées (élèves, "
                    "paiements) correspondent à l'année sélectionnée ici.",
              ),
              _HelpItem(
                title: "Option \"Créer nouvelle année\"",
                explanation:
                "Ouvre une fenêtre pour créer une toute nouvelle année "
                    "scolaire (ex: 2026-2027). Une nouvelle année démarre "
                    "avec une liste d'élèves vide. Les années précédentes "
                    "restent accessibles et ne sont jamais supprimées.",
              ),
            ],
          ),

          // ================== SYNCHRONISATION SERVEUR ==================
          _HelpSection(
            icon: Icons.cloud,
            title: "Synchronisation Serveur",
            children: [
              _HelpItem(
                title: "Bouton \"Définir Code École\"",
                explanation:
                "Le code école est un identifiant unique qui permet de "
                    "retrouver les données de VOTRE école sur le serveur "
                    "central. Il est indispensable pour sauvegarder ou "
                    "récupérer des données, et aussi pour créer de "
                    "nouveaux élèves (qui ont besoin d'un identifiant "
                    "unique généré par le serveur). Ne le partagez "
                    "qu'avec des personnes de confiance.",
              ),
              _HelpItem(
                title: "Bouton \"Définir Mot de Passe Sauvegarde\"",
                explanation:
                "Ce mot de passe protège toutes les actions sensibles de "
                    "l'application : changer le nom de l'école, modifier "
                    "les frais, supprimer une section, sauvegarder ou "
                    "récupérer des données, etc. Il doit contenir au moins "
                    "6 caractères. Sans ce mot de passe, vous ne pourrez "
                    "rien modifier dans les Paramètres.",
              ),
              _HelpItem(
                title: "Bouton \"Sauvegarder sur le Serveur\"",
                explanation:
                "Envoie une copie complète de toutes vos données "
                    "(configuration, élèves, paiements) vers le serveur "
                    "en ligne, protégée par votre code école et votre mot "
                    "de passe. Cela permet de ne jamais perdre vos données "
                    "même si le téléphone est cassé ou perdu.",
              ),
              _HelpItem(
                title: "Bouton \"Récupérer depuis le Serveur\"",
                explanation:
                "Va chercher les données précédemment sauvegardées sur le "
                    "serveur et les fusionne avec celles déjà présentes "
                    "sur l'appareil. Les élèves existants sont mis à jour, "
                    "et les nouveaux élèves (créés depuis un autre "
                    "appareil par exemple) sont ajoutés. Nécessite le bon "
                    "code école et le bon mot de passe.",
              ),
            ],
          ),

          // ================== AFFICHAGE & COMPTE ==================
          _HelpSection(
            icon: Icons.settings_suggest,
            title: "Affichage et Compte",
            children: [
              _HelpItem(
                title: "Interrupteur \"Mode Sombre\"",
                explanation:
                "Active ou désactive le thème sombre de l'application, "
                    "pour un affichage plus confortable la nuit ou pour "
                    "économiser la batterie sur certains écrans.",
              ),
              _HelpItem(
                title: "Bouton rouge \"Déconnexion\"",
                explanation:
                "Vous déconnecte de l'application et vous ramène à "
                    "l'écran de récupération/connexion. Vos données "
                    "restent sauvegardées sur l'appareil (et sur le "
                    "serveur si vous avez fait une sauvegarde) ; la "
                    "déconnexion ne supprime rien.",
              ),
            ],
          ),

          const SizedBox(height: 20),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              "Astuce générale : presque toutes les actions importantes "
                  "demandent votre mot de passe de sauvegarde avant de "
                  "s'exécuter. C'est normal, c'est une protection contre "
                  "les modifications accidentelles ou non autorisées.",
              style: TextStyle(fontSize: 13, color: Colors.grey, fontStyle: FontStyle.italic),
            ),
          ),
          const SizedBox(height: 30),
        ],
      ),
    );
  }
}

/// Une section pliable regroupant plusieurs explications (_HelpItem) liées
/// à un même bloc de l'écran Paramètres (ex: "Frais Mensuel...").
class _HelpSection extends StatelessWidget {
  final IconData icon;
  final String title;
  final List<_HelpItem> children;

  const _HelpSection({
    required this.icon,
    required this.title,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: ExpansionTile(
        leading: Icon(icon, color: Theme.of(context).colorScheme.primary),
        title: Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
        ),
        children: children
            .map((item) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  item.explanation,
                  style: const TextStyle(fontSize: 13.5, height: 1.4),
                ),
              ],
            ),
          ),
        ))
            .toList(),
      ),
    );
  }
}

/// Une explication individuelle : le nom du bouton/champ, et son rôle.
class _HelpItem {
  final String title;
  final String explanation;

  const _HelpItem({required this.title, required this.explanation});
}