import 'dart:io';

/// ⚡ MODIFIÉ — l'admin s'appelle lui-même en HTTP pour ses propres
/// routes (/generate_key, /validate_payments, etc.) : "local" signifie
/// ici simplement "mon propre serveur local tourne", donc on cible la
/// boucle locale (127.0.0.1) au lieu d'une IP fixe Windows. Le choix
/// entre local et internet se fait en vérifiant si le serveur local de
/// CETTE app est démarré, sans test réseau — c'est instantané et fiable
/// puisque l'admin sait directement s'il a démarré son propre serveur.
class NetworkResolver {
  static const int localPort = 8089;
  static const int discoveryPort = 8090;

  static const String localBaseUrl = 'http://127.0.0.1:$localPort';
  static const String internetBaseUrl = 'https://jsinf.onrender.com';

  static String? _cachedBase;
  static DateTime? _cachedAt;
  static const Duration _cacheTtl = Duration(seconds: 15);

  /// Fonction injectée par l'app au démarrage pour savoir si LE SERVEUR
  /// LOCAL DE CETTE APP tourne (voir LocalServerService.isRunning) —
  /// évite un import circulaire entre network_resolver.dart et
  /// local_server_service.dart.
  static bool Function() isLocalServerRunning = () => false;

  static Future<String> resolve({bool forceRefresh = false}) async {
    if (!forceRefresh &&
        _cachedBase != null &&
        _cachedAt != null &&
        DateTime.now().difference(_cachedAt!) < _cacheTtl) {
      return _cachedBase!;
    }
    final base =
    isLocalServerRunning() ? localBaseUrl : internetBaseUrl;
    _cachedBase = base;
    _cachedAt = DateTime.now();
    return base;
  }

  static bool get lastResolvedWasLocal => _cachedBase == localBaseUrl;

  static void invalidateCache() {
    _cachedBase = null;
    _cachedAt = null;
  }

  /// Détecte dynamiquement l'IP locale réelle de ce PC sur le réseau
  /// (partage Windows ou macOS) — utilisée uniquement pour AFFICHER
  /// l'adresse aux agents, jamais pour les appels HTTP internes de
  /// l'admin (qui utilisent 127.0.0.1). Fonctionne identiquement sur
  /// Windows et macOS.
  static Future<String?> getLocalIPv4() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (_isLikelyLanAddress(addr.address)) {
            return addr.address;
          }
        }
      }
      if (interfaces.isNotEmpty && interfaces.first.addresses.isNotEmpty) {
        return interfaces.first.addresses.first.address;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  static bool _isLikelyLanAddress(String ip) {
    return ip.startsWith('192.168.') || ip.startsWith('10.') || _isIn172(ip);
  }

  static bool _isIn172(String ip) {
    if (!ip.startsWith('172.')) return false;
    final parts = ip.split('.');
    if (parts.length < 2) return false;
    final second = int.tryParse(parts[1]);
    return second != null && second >= 16 && second <= 31;
  }
}