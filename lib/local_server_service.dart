import 'dart:convert';
import 'dart:io';
import 'frais_scolaires.dart';
import 'network_resolver.dart';

/// ⚡ Serveur HTTP local, hébergé par l'app de l'admin, + petit service
/// de découverte UDP pour les clients qui cherchent ce serveur sur le
/// réseau (voir network_resolver.dart du projet CLIENT).
///
/// Reproduit, en local, le sous-ensemble des routes du serveur central
/// (render.com) nécessaires pour que les sous-utilisateurs (clés
/// PAY/DISC/INSC/AFR) puissent travailler EN PARALLÈLE sans internet,
/// connectés au même réseau WiFi que ce PC (point d'accès mobile
/// Windows OU Partage Internet macOS OU simple routeur/box).
///
/// Principe clé : ce serveur ne duplique AUCUNE donnée. Il lit et écrit
/// directement sur l'instance `FraisScolaires` déjà chargée en mémoire
/// dans l'app de l'admin — la même que celle affichée à l'écran. Donc
/// dès qu'un sous-utilisateur envoie un paiement, il apparaît
/// immédiatement dans les "paiements en attente" du Dashboard Admin,
/// exactement comme avec le serveur central, sans étape de
/// synchronisation intermédiaire.
///
/// ⚡ MODIFIÉ (compatibilité Windows + macOS) : l'ancienne version
/// supposait une IP fixe (`192.168.137.1`, garantie uniquement par
/// Windows ICS). Cette IP n'est pas prévisible sur macOS (Partage
/// Internet). Cette version détecte dynamiquement sa propre IP locale
/// (`_getLocalIPv4Address`) et démarre en plus un petit "répondeur" UDP
/// (port `discoveryPort`) qui répond à tout client qui diffuse un
/// broadcast "SCHOOLAPP_DISCOVER" sur le réseau, avec cette IP réelle.
/// Fonctionne identiquement sur les deux OS, sans IP codée en dur.
///
/// ⚡ CORRIGÉ — DURÉE DE TRAVAIL DES CLÉS D'ACCÈS LOCALES (et non
/// durée d'expiration de la clé elle-même) :
///
/// `/generate_key` accepte toujours deux champs optionnels envoyés par
/// l'admin, `duration_value` (nombre) et `duration_unit` ('days' ou
/// 'minutes'), transmis tels quels à `FraisScolaires.generateLocalKey`.
/// Ces valeurs sont de simples métadonnées de la clé — elles NE la
/// rendent PAS inutilisable pour se connecter après un certain temps :
/// la clé reste valable indéfiniment pour l'entrée, jusqu'à révocation
/// manuelle.
///
/// `/verify_key` renvoie désormais `duration_value`/`duration_unit` à
/// CHAQUE connexion réussie (et plus de date d'expiration calculée) :
/// c'est à l'application cliente de démarrer, à partir de CE moment
/// précis, une fenêtre de travail de cette durée exacte, et de se
/// déconnecter elle-même automatiquement une fois ce temps écoulé —
/// même en cours d'utilisation, pas seulement au prochain lancement.
///
/// ⚠️ LIMITE HONNÊTE : les convocations et communiqués (module
/// Discipline) ne peuvent pas réellement atteindre les parents en mode
/// local — il n'existe aucun canal de notification (SMS/push) qui
/// fonctionne sans internet. Ce serveur les enregistre quand même
/// (`FraisScolaires.localCommunicationsLog`) pour ne rien perdre, mais
/// répond avec `notified_count: 0` et une note explicite à ce sujet,
/// plutôt que de faire croire à une livraison qui n'a pas eu lieu.
///
/// Démarré/arrêté explicitement par l'admin depuis le Dashboard (bouton
/// "Serveur local"), PAS automatiquement au lancement de l'app — comme
/// convenu, l'activation du partage réseau lui-même reste manuelle,
/// enseignée aux utilisateurs.
class LocalServerService {
  static const int httpPort = NetworkResolver.localPort;
  static const int discoveryPort = NetworkResolver.discoveryPort;
  static const String _discoveryMessage = 'SCHOOLAPP_DISCOVER';

  static HttpServer? _server;
  static RawDatagramSocket? _discoverySocket;
  static FraisScolaires? _frais;

  /// Vrai si le serveur local est actuellement démarré.
  static bool get isRunning => _server != null;

  /// Démarre le serveur HTTP local + le répondeur de découverte UDP, sur
  /// toutes les interfaces réseau de la machine (`InternetAddress.anyIPv4`,
  /// PAS `loopbackIPv4`) — indispensable pour que les autres appareils du
  /// réseau (pas seulement ce PC) puissent joindre le serveur.
  static Future<bool> start(FraisScolaires fraisScolaires) async {
    if (_server != null) return true; // déjà démarré, rien à faire
    _frais = fraisScolaires;
    try {
      _server = await HttpServer.bind(
        InternetAddress.anyIPv4,
        httpPort,
        shared: true,
      );
      _server!.listen(
        _handleRequest,
        onError: (_) {}, // une requête individuelle mal formée ne doit
        // jamais faire planter le serveur entier
      );

      await _startDiscoveryResponder();

      // ⚡ Branche le hook consulté par NetworkResolver.resolve() côté
      // admin : "local" = "mon propre serveur local tourne" (l'admin
      // s'appelle lui-même via 127.0.0.1, pas besoin de broadcast pour
      // se découvrir lui-même).
      NetworkResolver.isLocalServerRunning = () => isRunning;

      return true;
    } catch (_) {
      // Port déjà utilisé, pas de droit réseau, etc. — on ne bloque
      // jamais l'admin : il peut réessayer, ou fonctionner sans le
      // serveur local (mode internet classique).
      await _server?.close(force: true);
      _server = null;
      _discoverySocket?.close();
      _discoverySocket = null;
      _frais = null;
      return false;
    }
  }

  /// Démarre le petit répondeur UDP : écoute les demandes de découverte
  /// des clients et leur répond avec l'IP réelle de ce PC.
  static Future<void> _startDiscoveryResponder() async {
    _discoverySocket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      discoveryPort,
    );
    _discoverySocket!.broadcastEnabled = true;
    _discoverySocket!.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = _discoverySocket!.receive();
      if (datagram == null) return;
      try {
        final message = utf8.decode(datagram.data);
        if (message != _discoveryMessage) return;
      } catch (_) {
        return; // paquet non conforme, ignoré
      }

      _getLocalIPv4Address().then((ip) {
        if (ip == null || _discoverySocket == null) return;
        final response = jsonEncode({
          'service': 'schoolapp',
          'host': ip,
          'port': httpPort,
        });
        _discoverySocket!.send(
          utf8.encode(response),
          datagram.address,
          datagram.port,
        );
      });
    });
  }

  /// Détecte dynamiquement l'IP locale réelle de ce PC sur le réseau
  /// (point d'accès Windows, Partage Internet macOS, ou simple WiFi/LAN
  /// classique) — JAMAIS codée en dur, pour fonctionner sur les deux OS.
  static Future<String?> _getLocalIPv4Address() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      // On privilégie une adresse de réseau privé typique (WiFi/hotspot).
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (_isLikelyLanAddress(addr.address)) {
            return addr.address;
          }
        }
      }
      // Repli : la première IPv4 non-loopback trouvée, quelle qu'elle soit.
      if (interfaces.isNotEmpty && interfaces.first.addresses.isNotEmpty) {
        return interfaces.first.addresses.first.address;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  static bool _isLikelyLanAddress(String ip) {
    return ip.startsWith('192.168.') ||
        ip.startsWith('10.') ||
        _isIn172PrivateRange(ip);
  }

  static bool _isIn172PrivateRange(String ip) {
    if (!ip.startsWith('172.')) return false;
    final parts = ip.split('.');
    if (parts.length < 2) return false;
    final second = int.tryParse(parts[1]);
    return second != null && second >= 16 && second <= 31;
  }

  /// ⚡ IP locale actuelle du serveur, pour affichage dans le Dashboard
  /// (ex: bouton "Copier l'adresse pour les agents") — c'est cette
  /// méthode que `admin_dashboard_screen.dart` appelle.
  static Future<String?> getCurrentLocalIp() => _getLocalIPv4Address();

  /// Arrête le serveur local (HTTP + découverte) proprement.
  static Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _discoverySocket?.close();
    _discoverySocket = null;
    _frais = null;
    NetworkResolver.isLocalServerRunning = () => false;
  }

  static Future<void> _handleRequest(HttpRequest request) async {
    final response = request.response;
    response.headers.contentType = ContentType.json;
    // CORS permissif : utile si un jour un client web local (navigateur
    // sur le même réseau) doit aussi s'y connecter.
    response.headers.add('Access-Control-Allow-Origin', '*');
    response.headers.add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    response.headers.add('Access-Control-Allow-Headers', 'Content-Type');

    if (request.method == 'OPTIONS') {
      response.statusCode = 200;
      await response.close();
      return;
    }

    final frais = _frais;
    if (frais == null) {
      response.statusCode = 503;
      response.write(jsonEncode({'error': 'Serveur local non initialisé'}));
      await response.close();
      return;
    }

    try {
      final path = request.uri.path;
      Map<String, dynamic> body = {};
      if (request.method == 'POST') {
        final content = await utf8.decoder.bind(request).join();
        if (content.trim().isNotEmpty) {
          body = jsonDecode(content) as Map<String, dynamic>;
        }
      }

      switch (path) {
        case '/ping':
          _write(response, 200, {'ok': true});
          break;

        case '/restore':
          _write(response, 200, frais.exportSnapshotForClients());
          break;

        case '/generate_key':
          await _handleGenerateKey(body, response, frais);
          break;

        case '/verify_key':
          await _handleVerifyKey(body, response, frais);
          break;

        case '/record_payment':
          await _handleRecordPayment(body, response, frais);
          break;

        case '/get_pending_payments':
          _write(response, 200, {'pending_payments': frais.localPendingPayments});
          break;

        case '/validate_payments':
          await _handleValidatePayments(body, response, frais);
          break;

        case '/school/submit_registration':
          await _handleSubmitRegistration(body, response, frais);
          break;

        case '/school/get_pending_registrations':
          _write(response, 200,
              {'pending_registrations': frais.localPendingRegistrations});
          break;

        case '/school/validate_registrations':
          await _handleValidateRegistrations(body, response, frais);
          break;

        case '/school/get_autres_frais':
          _write(response, 200, {
            'autres_frais': frais.getAutresFrais().map((f) => f.toJson()).toList(),
          });
          break;

        case '/school/submit_autre_frais_payment':
          await _handleSubmitAutreFraisPayment(body, response, frais);
          break;

        case '/school/get_pending_autres_frais':
          _write(response, 200, {
            'pending_autres_frais': frais.localPendingAutresFraisPayments,
          });
          break;

        case '/school/validate_autres_frais_payments':
          await _handleValidateAutresFraisPayments(body, response, frais);
          break;

        case '/school/record_absences':
          await _handleRecordAbsences(body, response, frais);
          break;

        case '/school/get_attendance':
          _handleGetAttendance(request, response, frais);
          break;

        case '/school/send_convocation':
          await _handleSendConvocation(body, response, frais);
          break;

        case '/school/send_announcement':
          await _handleSendAnnouncement(body, response, frais);
          break;

        default:
          _write(response, 404, {'error': 'Route inconnue : $path'});
      }
    } catch (e) {
      _write(response, 500, {'error': 'Erreur serveur local : $e'});
    }

    await response.close();
  }

  static void _write(HttpResponse response, int status, Map<String, dynamic> data) {
    response.statusCode = status;
    response.write(jsonEncode(data));
  }

  // ==================== CLÉS D'ACCÈS ====================

  /// ⚡ CORRIGÉ — accepte `duration_value` (nombre) et `duration_unit`
  /// ('days' | 'minutes') envoyés par l'admin depuis le Dashboard, et
  /// les transmet tels quels à `generateLocalKey`. Ces champs
  /// définissent la durée de TRAVAIL après connexion, pas une date
  /// d'expiration de la clé — la réponse ne contient donc plus
  /// `expires_at`.
  static Future<void> _handleGenerateKey(
      Map<String, dynamic> body, HttpResponse response, FraisScolaires frais) async {
    final sections =
    (body['sections'] as List? ?? []).map((e) => e.toString()).toList();
    final type = (body['type'] ?? 'PAY').toString();
    final classe = body['classe']?.toString();
    final durationValue = (body['duration_value'] as num?)?.toInt() ?? 30;
    final durationUnit = (body['duration_unit'] ?? 'days').toString();

    final entry = await frais.generateLocalKey(
      sections: sections,
      type: type,
      classe: classe,
      durationValue: durationValue,
      durationUnit: durationUnit,
    );
    _write(response, 200, {
      'key': entry['key'],
      'sections': entry['sections'],
      'type': entry['type'],
      'classe': entry['classe'],
      // ⚡ Durée de TRAVAIL après connexion (pas d'expiration de la
      // clé), renvoyée pour affichage immédiat côté Dashboard.
      'duration_value': entry['durationValue'],
      'duration_unit': entry['durationUnit'],
    });
  }

  /// ⚡ CORRIGÉ — ne vérifie plus/ne retire plus de clé "expirée" : la
  /// clé reste valable pour se CONNECTER indéfiniment. La réponse
  /// renvoie désormais `duration_value`/`duration_unit` à CHAQUE
  /// connexion réussie (au lieu d'une `expires_at` calculée à la
  /// génération) : c'est à partir de CE moment-là que l'app cliente
  /// doit compter la durée de travail autorisée.
  static Future<void> _handleVerifyKey(
      Map<String, dynamic> body, HttpResponse response, FraisScolaires frais) async {
    final key = (body['key'] ?? '').toString().trim();
    final entry = await frais.verifyLocalKey(key);
    if (entry == null) {
      _write(response, 200, {'valid': false});
      return;
    }
    _write(response, 200, {
      'valid': true,
      'school_code': frais.schoolCode ?? '',
      'school_name': frais.config.schoolName,
      'sections': entry['sections'],
      'type': entry['type'],
      'classe': entry['classe'],
      'current_year': frais.currentYear,
      // ⚡ CORRIGÉ — durée de TRAVAIL, à partir de MAINTENANT (cette
      // connexion précise), choisie par l'admin à la génération.
      'duration_value': entry['durationValue'],
      'duration_unit': entry['durationUnit'],
    });
  }

  // ==================== PAIEMENTS (frais mensuel principal) ====================

  static Future<void> _handleRecordPayment(
      Map<String, dynamic> body, HttpResponse response, FraisScolaires frais) async {
    final eleveId = (body['eleve_id'] ?? '').toString();
    final mois = (body['mois'] ?? '').toString();
    final amount = (body['amount'] as num?)?.toDouble() ?? 0.0;
    await frais.addLocalPendingPayment(eleveId: eleveId, mois: mois, amount: amount);
    _write(response, 200, {'success': true});
  }

  static Future<void> _handleValidatePayments(
      Map<String, dynamic> body, HttpResponse response, FraisScolaires frais) async {
    final ids = (body['payment_ids'] as List? ?? []).map((e) => e.toString()).toList();
    final count = await frais.validateLocalPendingPayments(ids);
    _write(response, 200, {'success': true, 'validated_count': count});
  }

  // ==================== INSCRIPTIONS ====================

  static Future<void> _handleSubmitRegistration(
      Map<String, dynamic> body, HttpResponse response, FraisScolaires frais) async {
    await frais.addLocalPendingRegistration(body);
    _write(response, 200, {'success': true});
  }

  static Future<void> _handleValidateRegistrations(
      Map<String, dynamic> body, HttpResponse response, FraisScolaires frais) async {
    final ids =
    (body['registration_ids'] as List? ?? []).map((e) => e.toString()).toList();
    final count = await frais.validateLocalPendingRegistrations(ids);
    _write(response, 200, {'success': true, 'created_count': count});
  }

  // ==================== AUTRES FRAIS ====================

  static Future<void> _handleSubmitAutreFraisPayment(
      Map<String, dynamic> body, HttpResponse response, FraisScolaires frais) async {
    final eleveId = (body['eleve_id'] ?? '').toString();
    final autreFraisId = (body['autre_frais_id'] ?? '').toString();
    final montant = (body['montant'] as num?)?.toDouble() ?? 0.0;
    final enregistrePar = (body['enregistre_par'] ?? 'Agent').toString();
    await frais.addLocalPendingAutreFraisPayment(
      eleveId: eleveId,
      autreFraisId: autreFraisId,
      montant: montant,
      enregistrePar: enregistrePar,
    );
    _write(response, 200, {'success': true});
  }

  static Future<void> _handleValidateAutresFraisPayments(
      Map<String, dynamic> body, HttpResponse response, FraisScolaires frais) async {
    final ids = (body['payment_ids'] as List? ?? []).map((e) => e.toString()).toList();
    final count = await frais.validateLocalPendingAutresFraisPayments(ids);
    _write(response, 200, {'success': true, 'validated_count': count});
  }

  // ==================== DISCIPLINE ====================

  static Future<void> _handleRecordAbsences(
      Map<String, dynamic> body, HttpResponse response, FraisScolaires frais) async {
    final classe = (body['classe'] ?? '').toString();
    final section = (body['section'] ?? '').toString();
    final date = (body['date'] ?? '').toString();
    final absentIds =
    (body['absent_ids'] as List? ?? []).map((e) => e.toString()).toList();
    final recordedBy = (body['recorded_by'] ?? 'Direction').toString();

    await frais.recordLocalAbsences(
      classe: classe,
      section: section,
      date: date,
      absentIds: absentIds,
      recordedBy: recordedBy,
    );

    // ⚠️ Honnête : pas de canal de notification réel hors ligne.
    _write(response, 200, {
      'notified_count': 0,
      'note': 'Enregistré localement. Les parents seront notifiés une '
          'fois cet appareil reconnecté à internet.',
    });
  }

  static void _handleGetAttendance(
      HttpRequest request, HttpResponse response, FraisScolaires frais) {
    final classe = request.uri.queryParameters['classe'] ?? '';
    final date = request.uri.queryParameters['date'] ?? '';
    _write(response, 200, {'absents': frais.getLocalAttendance(classe, date)});
  }

  static Future<void> _handleSendConvocation(
      Map<String, dynamic> body, HttpResponse response, FraisScolaires frais) async {
    await frais.logLocalCommunication({
      'type': 'convocation',
      'student_id': body['student_id'],
      'title': body['title'],
      'message': body['message'],
    });
    _write(response, 200, {
      'success': true,
      'note': 'Enregistré localement. Le parent sera notifié une fois '
          'cet appareil reconnecté à internet.',
    });
  }

  static Future<void> _handleSendAnnouncement(
      Map<String, dynamic> body, HttpResponse response, FraisScolaires frais) async {
    await frais.logLocalCommunication({
      'type': 'announcement',
      'title': body['title'],
      'message': body['message'],
      'target': body['target'],
      'classe': body['classe'],
      'section': body['section'],
      'sections': body['sections'],
      'student_ids': body['student_ids'],
    });
    // ⚠️ Honnête : notified_count reste 0 en local (voir doc de classe).
    _write(response, 200, {
      'notified_count': 0,
      'note': 'Communiqué enregistré localement. Les parents seront '
          'notifiés une fois cet appareil reconnecté à internet.',
    });
  }
}