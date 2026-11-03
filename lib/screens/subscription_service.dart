import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'subscription_expired_screen.dart';

const String _serverUrl = "https://jsinf.onrender.com";

// ============================================================================
// ⚡⚡⚡ SERVICE D'ABONNEMENT (LICENCE)
// ============================================================================
// Principe :
//   - À l'activation ou à la connexion, le serveur renvoie une date
//     d'expiration ("subscription_expires_at"). On la sauvegarde
//     localement (fichier subscription_data.json, indépendant du reste
//     des données de l'école).
//   - À CHAQUE démarrage de l'appli (ou aussi souvent que nécessaire),
//     on peut vérifier LOCALEMENT si cette date est dépassée — SANS
//     avoir besoin d'internet. C'est ce qui permet de bloquer l'accès
//     même quand l'utilisateur travaille hors-ligne pendant des jours,
//     comme demandé.
//   - Dès qu'une connexion internet est disponible (backup, restore,
//     connexion...), l'état est automatiquement resynchronisé avec le
//     serveur, qui reste la source de vérité (utile si l'admin a
//     débloqué l'école entre-temps depuis un autre appareil, ou si
//     l'heure de l'appareil a été trafiquée).
//   - Si l'utilisateur change d'ordinateur et se reconnecte avec
//     code école + mot de passe, il n'y a PAS de cache local sur ce
//     nouvel appareil : c'est alors le SERVEUR qui tranche
//     immédiatement (voir RecoveryScreen._loginWithCodeAndPassword),
//     via /school/check_subscription ou directement la réponse de
//     /verify_password.
// ============================================================================
class SubscriptionService {

  SubscriptionService._internal();

  static final SubscriptionService instance = SubscriptionService._internal();

  String? _schoolCode;

  DateTime? _expiresAt;

  bool _blocked = false;

  String? _dataFilePath;

  String? get schoolCode => _schoolCode;

  DateTime? get expiresAt => _expiresAt;

  bool get isBlocked => _blocked;

  Future<void> _ensurePath() async {

    if (_dataFilePath != null) return;

    final dir = await getApplicationDocumentsDirectory();

    _dataFilePath = '${dir.path}/subscription_data.json';

  }

  /// Charge l'état d'abonnement précédemment sauvegardé sur CET

  /// appareil (s'il existe). À appeler une fois au démarrage de

  /// l'application, avant tout écran.

  Future<void> load() async {

    await _ensurePath();

    final file = File(_dataFilePath!);

    if (!await file.exists()) return;

    try {

      final data = json.decode(await file.readAsString()) as Map<String, dynamic>;

      _schoolCode = data['schoolCode'] as String?;

      final expIso = data['expiresAt'] as String?;

      _expiresAt = (expIso != null && expIso.isNotEmpty)

          ? DateTime.tryParse(expIso)

          : null;

      _blocked = data['blocked'] == true;

    } catch (_) {

      // Fichier corrompu ou absent : on ne bloque jamais par erreur de

      // lecture locale, seul le serveur ou une donnée valide bloque.

    }

  }

  Future<void> _save() async {

    await _ensurePath();

    final file = File(_dataFilePath!);

    await file.writeAsString(json.encode({

      'schoolCode': _schoolCode,

      'expiresAt': _expiresAt?.toIso8601String(),

      'blocked': _blocked,

      'lastSync': DateTime.now().toIso8601String(),

    }));

  }

  /// Applique un statut d'abonnement reçu du serveur (peu importe la

  /// route d'origine : activation, connexion, backup, restore...) et

  /// le persiste localement. C'est la SEULE façon dont `_expiresAt`

  /// doit être modifié, pour que le cache local reste toujours aligné

  /// sur ce que le serveur a réellement calculé.

  Future<void> applyServerSubscription({

    required String schoolCode,

    String? expiresAtIso,

    bool blocked = false,

  }) async {

    _schoolCode = schoolCode;

    _expiresAt = (expiresAtIso != null && expiresAtIso.isNotEmpty)

        ? DateTime.tryParse(expiresAtIso)

        : null;

    _blocked = blocked;

    await _save();

  }

  /// Pratique : applique directement le bloc `subscription` tel que

  /// renvoyé par le serveur dans /verify_password, /backup, /restore,

  /// /school/check_subscription, etc.

  /// Exemple de bloc reçu :

  ///   { "valid": true, "blocked": false, "expires_at": "...", "seconds_remaining": 42 }

  Future<void> applyFromServerMap({

    required String schoolCode,

    required Map<String, dynamic>? subscriptionMap,

  }) async {

    if (subscriptionMap == null) return;

    await applyServerSubscription(

      schoolCode: schoolCode,

      expiresAtIso: subscriptionMap['expires_at'] as String?,

      blocked: subscriptionMap['blocked'] == true,

    );

  }

  /// Vérifie LOCALEMENT (sans réseau) si l'abonnement est expiré, en

  /// se basant sur la dernière date connue reçue du serveur.

  /// - Si aucune info n'est encore connue (première utilisation sur

  ///   cet appareil, jamais synchronisé), on NE bloque PAS : on laisse

  ///   passer, en attendant la prochaine synchronisation serveur.

  bool get isExpiredLocally {

    if (_blocked) return true;

    if (_expiresAt == null) return false;

    return DateTime.now().isAfter(_expiresAt!);

  }

  /// Temps restant avant expiration (ou Duration.zero si déjà expiré,

  /// ou null si inconnu).

  Duration? get remaining {

    if (_expiresAt == null) return null;

    final d = _expiresAt!.difference(DateTime.now());

    return d.isNegative ? Duration.zero : d;

  }

  /// Interroge le serveur pour connaître le VRAI statut de

  /// l'abonnement d'une école (utilisé notamment lors d'une connexion

  /// sur un nouvel appareil). Ne lève jamais d'exception : si le

  /// réseau est indisponible, renvoie {'reachable': false} pour que

  /// l'appelant décide (par exemple, se rabattre sur le cache local).

  Future<Map<String, dynamic>> checkServerStatus(String schoolCode) async {

    try {

      final response = await http

          .get(Uri.parse('$_serverUrl/school/check_subscription?school_code=$schoolCode'))

          .timeout(const Duration(seconds: 12));

      if (response.statusCode == 200) {

        final data = json.decode(response.body) as Map<String, dynamic>;

        await applyServerSubscription(

          schoolCode: schoolCode,

          expiresAtIso: data['expires_at'] as String?,

          blocked: data['blocked'] == true,

        );

        return {'reachable': true, ...data};

      }

      return {'reachable': false};

    } catch (_) {

      return {'reachable': false};

    }

  }

  /// Envoie au serveur la clé de reconnexion saisie par l'utilisateur

  /// (fournie par l'administrateur EduPay via admin_panel.py). Si

  /// valide, une nouvelle période d'abonnement démarre immédiatement,

  /// et le cache local est mis à jour.

  Future<Map<String, dynamic>> redeemReconnectionKey({

    required String schoolCode,

    required String key,

  }) async {

    try {

      final response = await http.post(

        Uri.parse('$_serverUrl/school/redeem_reconnection_key'),

        headers: {'Content-Type': 'application/json'},

        body: json.encode({

          'school_code': schoolCode,

          'key': key.trim().toUpperCase(),

        }),

      ).timeout(const Duration(seconds: 15));

      Map<String, dynamic> data = {};

      try {

        data = json.decode(response.body) as Map<String, dynamic>;

      } catch (_) {}

      if (response.statusCode == 200) {

        await applyServerSubscription(

          schoolCode: schoolCode,

          expiresAtIso: data['expires_at'] as String?,

          blocked: false,

        );

        return {'success': true};

      }

      return {

        'success': false,

        'error': data['error'] ?? 'Clé de reconnexion invalide.',

      };

    } on SocketException catch (e) {

      return {

        'success': false,

        'error': 'Aucune connexion réseau (vérifiez internet) : $e',

      };

    } catch (e) {

      return {'success': false, 'error': 'Erreur inattendue : $e'};

    }

  }

  /// Efface toutes les données locales d'abonnement (à appeler lors

  /// d'une déconnexion complète de l'appli, si applicable).

  Future<void> clear() async {

    _schoolCode = null;

    _expiresAt = null;

    _blocked = false;

    await _ensurePath();

    final file = File(_dataFilePath!);

    if (await file.exists()) await file.delete();

  }

  // ==========================================================================
  // ⚡⚡⚡ GARDE-FOU RÉUTILISABLE
  // ==========================================================================
  // À appeler dans le `initState()` de l'écran d'accueil de l'école

  // (SchoolHomeScreen ou équivalent) et/ou juste après le splash au

  // démarrage de l'appli. Si l'abonnement est expiré localement,

  // redirige IMMÉDIATEMENT vers SubscriptionExpiredScreen (bloquant,

  // aucun bouton retour) — exactement le comportement demandé : même

  // en redémarrant l'appli, l'utilisateur retombe sur ce message tant

  // que la clé de reconnexion n'a pas été saisie.

  //

  // Renvoie `true` si tout est en ordre (l'appelant peut continuer

  // normalement), `false` si une redirection a eu lieu.

  static Future<bool> guardOrRedirect(BuildContext context) async {

    await instance.load();

    if (instance.isExpiredLocally && instance._schoolCode != null) {

      _redirectToExpiredScreen(context, instance._schoolCode!);

      return false;

    }

    // Rafraîchissement silencieux en arrière-plan si une connexion est

    // disponible (n'empêche jamais l'utilisateur de continuer à

    // travailler hors-ligne) : si le serveur nous dit que ce n'est

    // finalement PAS en ordre (ex: bloqué manuellement par l'admin),

    // on redirige dès que la réponse arrive.

    if (instance._schoolCode != null) {

      // ignore: unawaited_futures

      instance.checkServerStatus(instance._schoolCode!).then((result) {

        if (result['reachable'] == true &&

            result['valid'] == false &&

            context.mounted) {

          _redirectToExpiredScreen(context, instance._schoolCode!);

        }

      });

    }

    return true;

  }

  static void _redirectToExpiredScreen(BuildContext context, String schoolCode) {

    Navigator.of(context).pushAndRemoveUntil(

      MaterialPageRoute(

        builder: (_) => SubscriptionExpiredScreen(schoolCode: schoolCode),

      ),

          (route) => false,

    );

  }

}