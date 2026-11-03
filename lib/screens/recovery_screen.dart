import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'dart:convert';
import 'dart:io';
import '../app_state.dart';
import '../frais_scolaires.dart';
import 'school_home_screen.dart';
// ⚡⚡⚡ NOUVEAU — nécessaires pour la vérification d'abonnement lors
// d'une connexion sur un nouvel appareil (code école + mot de passe).
// Ajustez ces deux chemins si subscription_service.dart et
// subscription_expired_screen.dart ne sont pas dans le même dossier que
// ce fichier.
import 'subscription_service.dart';
import 'subscription_expired_screen.dart';

const String _serverUrl = "https://jsinf.onrender.com";

class RecoveryScreen extends StatefulWidget {
  const RecoveryScreen({super.key});

  @override
  State<RecoveryScreen> createState() => _RecoveryScreenState();
}

class _RecoveryScreenState extends State<RecoveryScreen> {
  String _mode = 'select';

  final _idController         = TextEditingController();
  final _codeController       = TextEditingController();
  final _passwordController   = TextEditingController();
  final _confirmController    = TextEditingController();

  bool    _isLoading   = false;
  bool    _obscure     = true;
  String? _errorMsg;

  String? _schoolName;
  String? _schoolCode;
  String? _city;
  String? _director;

  @override
  void dispose() {
    _idController.dispose();
    _codeController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  void _reset() {
    setState(() {
      _mode       = 'select';
      _errorMsg   = null;
      _schoolName = null;
      _schoolCode = null;
      _city       = null;
      _director   = null;
      _idController.clear();
      _codeController.clear();
      _passwordController.clear();
      _confirmController.clear();
    });
  }

  // ====================================================================
  // ⚡ Nettoyage robuste de l'ID/code saisi ou collé.
  //
  // Un copier-coller depuis WhatsApp, Word ou un email peut insérer des
  // espaces insécables ou des retours à la ligne invisibles au milieu du
  // texte. .trim() seul ne retire que les espaces en début/fin. Sur
  // Windows en particulier, ce genre de collage "sale" est fréquent et
  // peut faire échouer une vérification d'ID qui semble pourtant
  // identique à l'œil nu.
  // ====================================================================
  String _sanitize(String raw) {
    return raw
        .trim()
        .toUpperCase()
        .replaceAll('\u00A0', '')
        .replaceAll(RegExp(r'\s+'), '');
  }

  // ====================================================================
  // FLUX 1 — Vérification de l'ID de registration (EDU-XXXX)
  // ====================================================================
  Future<void> _verifyRegistrationId() async {
    final id = _sanitize(_idController.text);
    if (id.isEmpty) {
      setState(() => _errorMsg = "Veuillez entrer votre ID de connexion.");
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMsg  = null;
    });

    try {
      final response = await http.post(
        Uri.parse('$_serverUrl/school/verify_registration_id'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'registration_id': id}),
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);

        if (data['valid'] == true) {
          setState(() {
            _schoolName = data['school_name'];
            _schoolCode = data['school_code'];
            _city       = data['city'];
            _director   = data['director'];
            _mode       = 'first_setup';
            _errorMsg   = null;
          });
        } else if (data['already_used'] == true) {
          await _fetchSchoolCodeThenLogin(id, data);
        } else {
          setState(() => _errorMsg = data['error'] ??
              "ID invalide. Vérifiez auprès de l'administrateur EduPay.");
        }
      } else {
        setState(() => _errorMsg =
        "Erreur serveur (statut ${response.statusCode}).\n${response.body}");
      }
    } on SocketException catch (e) {
      setState(() => _errorMsg =
      "Aucune connexion réseau détectée sur cet appareil.\n"
          "Vérifiez votre connexion internet et le pare-feu Windows.\n"
          "Détail technique : $e");
    } catch (e) {
      setState(() =>
      _errorMsg = "Connexion impossible. Détail technique : $e");
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _fetchSchoolCodeThenLogin(
      String regId, Map<String, dynamic> verifyData) async {
    try {
      final response = await http.post(
        Uri.parse('$_serverUrl/school/get_info_by_reg_id'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'registration_id': regId}),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['found'] == true) {
          setState(() {
            _schoolCode = _sanitize(data['school_code'] as String);
            _schoolName = data['school_name'];
            _codeController.text = _schoolCode ?? '';
            _mode       = 'login';
            _errorMsg   = null;
          });
          return;
        }
      }
    } catch (_) {
      // On tente le fallback ci-dessous en cas d'échec réseau.
    }

    if (verifyData['school_code'] != null) {
      setState(() {
        _schoolCode = _sanitize(verifyData['school_code'] as String);
        _schoolName = verifyData['school_name'] ?? "Votre école";
        _codeController.text = _schoolCode ?? '';
        _mode     = 'login';
        _errorMsg = null;
      });
    } else {
      setState(() => _errorMsg =
      "Impossible de récupérer les infos de l'école.\n"
          "Vérifiez votre connexion internet sur cet appareil.");
    }
  }

  // ====================================================================
  // FLUX 1b — Activation (première connexion)
  // ====================================================================
  Future<void> _activateSchool() async {
    final password = _passwordController.text.trim();
    final confirm  = _confirmController.text.trim();

    if (password.length < 6) {
      setState(() =>
      _errorMsg = "Le mot de passe doit contenir au moins 6 caractères.");
      return;
    }
    if (password != confirm) {
      setState(() => _errorMsg = "Les deux mots de passe ne correspondent pas.");
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMsg  = null;
    });

    try {
      final response = await http.post(
        Uri.parse('$_serverUrl/school/activate'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'registration_id': _sanitize(_idController.text),
          'password':        password,
          'school_name':     _schoolName,
        }),
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (mounted) {
          final appState = Provider.of<AppState>(context, listen: false);
          final realCode = _sanitize(data['school_code'] as String);
          await appState.setSchoolCode(realCode);
          await appState.updateSchoolName(data['school_name']);
          await appState.setBackupPassword(password);

          // ⚡⚡⚡ NOUVEAU — dès l'activation, le serveur démarre la
          // période d'abonnement (voir /school/activate côté serveur,
          // qui renvoie subscription_expires_at + subscription_seconds).
          // On initialise immédiatement le cache local de
          // SubscriptionService pour que le compte à rebours démarre
          // dès maintenant, même si l'appareil repasse hors-ligne juste
          // après (comme demandé : le comptage doit fonctionner sans
          // avoir besoin d'internet à chaque fois).
          await SubscriptionService.instance.applyServerSubscription(
            schoolCode: realCode,
            expiresAtIso: data['subscription_expires_at'] as String?,
            blocked: false,
          );

          await _showWelcomeDialog(data['school_name']);
        }
      } else {
        String err = 'Erreur serveur';
        try {
          err = jsonDecode(response.body)['error'] ?? err;
        } catch (_) {}
        setState(() => _errorMsg = "$err (statut ${response.statusCode})");
      }
    } on SocketException catch (e) {
      setState(() => _errorMsg =
      "Aucune connexion réseau détectée sur cet appareil.\n"
          "Vérifiez votre connexion internet et le pare-feu Windows.\n"
          "Détail technique : $e");
    } catch (e) {
      setState(() =>
      _errorMsg = "Connexion impossible. Détail technique : $e");
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ====================================================================
  // FLUX 2 — Connexion avec code école + mot de passe
  // ====================================================================
  Future<void> _loginWithCodeAndPassword() async {
    final code     = _sanitize(_codeController.text);
    final password = _passwordController.text.trim();

    if (code.isEmpty) {
      setState(() => _errorMsg = "Veuillez entrer le code de votre école.");
      return;
    }
    if (password.isEmpty) {
      setState(() => _errorMsg = "Veuillez entrer votre mot de passe.");
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMsg  = null;
    });

    try {
      final verifyResponse = await http.post(
        Uri.parse('$_serverUrl/verify_password'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'school_code': code,
          'password':    password,
        }),
      ).timeout(const Duration(seconds: 15));

      if (verifyResponse.statusCode == 200) {
        final vData = jsonDecode(verifyResponse.body);
        if (vData['valid'] == true) {
          // ==============================================================
          // ⚡⚡⚡ NOUVEAU — POINT CLÉ DEMANDÉ :
          // C'est ICI, juste après un mot de passe correct, que l'appli
          // doit vérifier si l'école est "en ordre" auprès du serveur —
          // exactement le scénario décrit : "même si l'utilisateur change
          // d'ordinateur [...] une fois il entre ces informations
          // directement le serveur va vérifier s'il n'est pas en ordre,
          // si il n'est pas, directement on lui emmène encore dans cette
          // fenêtre là [SubscriptionExpiredScreen]".
          //
          // Le serveur (/verify_password) renvoie déjà ce bloc :
          //   "subscription": { "valid": bool, "blocked": bool,
          //                      "expires_at": "...",
          //                      "seconds_remaining": int|null }
          //
          // On met d'abord à jour le cache local (utile pour cet
          // appareil, même s'il repasse hors-ligne ensuite), PUIS on
          // décide de bloquer ou non l'accès selon "valid".
          // ==============================================================
          final subMap = vData['subscription'] as Map<String, dynamic>?;

          await SubscriptionService.instance.applyFromServerMap(
            schoolCode: code,
            subscriptionMap: subMap,
          );

          final bool subscriptionValid = subMap == null || subMap['valid'] == true;

          if (!subscriptionValid) {
            if (mounted) {
              setState(() => _isLoading = false);
              Navigator.of(context).pushAndRemoveUntil(
                MaterialPageRoute(
                  builder: (_) => SubscriptionExpiredScreen(schoolCode: code),
                ),
                    (route) => false,
              );
            }
            return;
          }

          await _restoreAllData(code, password);
        } else {
          setState(() => _errorMsg = "Mot de passe incorrect.");
        }
      } else if (verifyResponse.statusCode == 404) {
        setState(() => _errorMsg =
        "Code école introuvable sur le serveur.\n"
            "Vérifiez le code (ex: MAPENDO) et assurez-vous d'avoir "
            "effectué au moins une sauvegarde depuis un appareil "
            "connecté à internet.");
      } else {
        setState(() => _errorMsg =
        "Erreur serveur (statut ${verifyResponse.statusCode}).\n"
            "${verifyResponse.body}");
      }
    } on SocketException catch (e) {
      setState(() => _errorMsg =
      "Aucune connexion réseau détectée sur cet appareil.\n"
          "Vérifiez votre connexion internet et le pare-feu Windows.\n"
          "Détail technique : $e");
    } catch (e) {
      setState(() =>
      _errorMsg = "Connexion impossible. Détail technique : $e");
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _restoreAllData(String code, String password) async {
    try {
      final restoreResponse = await http.get(
        Uri.parse('$_serverUrl/restore?school_code=$code'),
      ).timeout(const Duration(seconds: 20));

      if (restoreResponse.statusCode == 200) {
        final data       = jsonDecode(restoreResponse.body);
        final schoolName = data['config']?['schoolName'] ?? code;

        if (mounted) {
          final appState = Provider.of<AppState>(context, listen: false);
          await appState.setSchoolCode(code);
          await appState.updateSchoolName(schoolName);
          await appState.setBackupPassword(password);

          final fraisScolaires = FraisScolaires();
          fraisScolaires.schoolCode = code;
          await fraisScolaires.loadData();
          await fraisScolaires.mergeRestoredData(data);
          await fraisScolaires.saveData();

          // ⚡⚡⚡ NOUVEAU — /restore renvoie aussi le bloc "subscription"
          // (voir server.py : data['subscription'] = ... juste avant le
          // retour). On rafraîchit le cache local une seconde fois ici
          // par cohérence, même si la vérification décisive a déjà eu
          // lieu juste après /verify_password ci-dessus.
          final subMap = data['subscription'] as Map<String, dynamic>?;
          if (subMap != null) {
            await SubscriptionService.instance.applyFromServerMap(
              schoolCode: code,
              subscriptionMap: subMap,
            );
          }

          await _showReconnectedDialog(schoolName);
        }
      } else if (restoreResponse.statusCode == 404) {
        setState(() => _errorMsg =
        "Aucune sauvegarde trouvée sur le serveur pour ce code.");
      } else {
        setState(() => _errorMsg =
        "Impossible de récupérer les données du serveur "
            "(statut ${restoreResponse.statusCode}).");
      }
    } on SocketException catch (e) {
      setState(() => _errorMsg =
      "Aucune connexion réseau détectée sur cet appareil.\n"
          "Détail technique : $e");
    } catch (e) {
      setState(() => _errorMsg =
      "Erreur lors de la récupération des données : $e");
    }
  }

  // ====================================================================
  // DIALOGUES
  // ====================================================================
  Future<void> _showWelcomeDialog(String schoolName) async {
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.school, size: 64, color: Colors.indigo),
            const SizedBox(height: 16),
            const Text(
              "Bienvenue sur EduPay !",
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              schoolName,
              style: const TextStyle(
                fontSize: 16,
                color: Colors.indigo,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            const Text(
              "Votre compte a été activé avec succès.\n"
                  "Pensez à sauvegarder régulièrement vos\n"
                  "données dans les Paramètres.",
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey, fontSize: 13),
            ),
          ],
        ),
        actions: [
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.indigo,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: () {
                Navigator.pop(ctx);
                _goToHome();
              },
              child: const Text("Commencer"),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showReconnectedDialog(String schoolName) async {
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_done,
                size: 64, color: Colors.green),
            const SizedBox(height: 16),
            const Text(
              "Reconnexion réussie !",
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              schoolName,
              style: const TextStyle(
                fontSize: 16,
                color: Colors.green,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            const Text(
              "Toutes vos données ont été récupérées\n"
                  "depuis le serveur central EduPay.",
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey, fontSize: 13),
            ),
          ],
        ),
        actions: [
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: () {
                Navigator.pop(ctx);
                _goToHome();
              },
              child: const Text("Continuer"),
            ),
          ),
        ],
      ),
    );
  }

  void _goToHome() {
    if (!mounted) return;
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const SchoolHomeScreen()),
          (route) => false,
    );
  }

  // ====================================================================
  // BUILD
  // ====================================================================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const SizedBox(height: 40),
              const Icon(Icons.school_rounded,
                  size: 80, color: Colors.indigo),
              const SizedBox(height: 16),
              const Text(
                "EduPay School RDC",
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                  color: Colors.indigo,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _subtitle(),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.grey, fontSize: 14),
              ),
              const SizedBox(height: 40),

              if (_mode == 'select')   _buildSelectMode(),
              if (_mode == 'new_id')   _buildNewIdStep(),
              if (_mode == 'first_setup') _buildFirstSetupStep(),
              if (_mode == 'login')    _buildLoginStep(),

              if (_errorMsg != null) ...[
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.red.shade200),
                  ),
                  child: Text(
                    _errorMsg!,
                    style: TextStyle(color: Colors.red.shade700),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }

  String _subtitle() {
    switch (_mode) {
      case 'select':
        return "Bienvenue — Comment voulez-vous continuer ?";
      case 'new_id':
        return "Entrez l'ID fourni par l'administrateur EduPay";
      case 'first_setup':
        return "Première connexion — Définissez votre mot de passe";
      case 'login':
        return "Reconnectez-vous à votre compte existant";
      default:
        return '';
    }
  }

  Widget _buildSelectMode() {
    return Column(
      children: [
        _optionCard(
          icon: Icons.vpn_key,
          color: Colors.indigo,
          title: "Première connexion",
          subtitle: "J'ai reçu un ID de l'administrateur EduPay\n(format : EDU-XXXX-XXXX-XXXX)",
          onTap: () => setState(() {
            _mode     = 'new_id';
            _errorMsg = null;
          }),
        ),
        const SizedBox(height: 16),
        _optionCard(
          icon: Icons.login,
          color: Colors.green,
          title: "Se connecter",
          subtitle: "J'ai déjà un compte — j'entre mon code école\net mon mot de passe pour récupérer mes données",
          onTap: () => setState(() {
            _mode     = 'login';
            _errorMsg = null;
          }),
        ),
      ],
    );
  }

  Widget _optionCard({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: color.withAlpha(15),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withAlpha(60)),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: color.withAlpha(30),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: color, size: 28),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: color,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: const TextStyle(
                        fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
            ),
            Icon(Icons.arrow_forward_ios, size: 16, color: color),
          ],
        ),
      ),
    );
  }

  Widget _buildNewIdStep() {
    return Column(
      children: [
        TextField(
          controller: _idController,
          textCapitalization: TextCapitalization.characters,
          decoration: InputDecoration(
            labelText: "ID de connexion",
            hintText: "Ex: EDU-A3K9-BZ12-Q7M4",
            prefixIcon: const Icon(Icons.vpn_key, color: Colors.indigo),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12)),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide:
              const BorderSide(color: Colors.indigo, width: 2),
            ),
          ),
          onSubmitted: (_) => _verifyRegistrationId(),
        ),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          height: 52,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.indigo,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: _isLoading ? null : _verifyRegistrationId,
            child: _isLoading
                ? const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.white),
            )
                : const Text("Continuer",
                style: TextStyle(fontSize: 16)),
          ),
        ),
        const SizedBox(height: 12),
        TextButton(
          onPressed: _reset,
          child: const Text("← Retour"),
        ),
      ],
    );
  }

  Widget _buildFirstSetupStep() {
    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.indigo.withAlpha(15),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.indigo.withAlpha(40)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "École identifiée :",
                style: TextStyle(
                    color: Colors.indigo,
                    fontWeight: FontWeight.bold,
                    fontSize: 13),
              ),
              const SizedBox(height: 8),
              Text(
                _schoolName ?? '',
                style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 18),
              ),
              if (_city != null) Text(_city!),
              if (_director != null)
                Text("Directeur : $_director"),
            ],
          ),
        ),
        const SizedBox(height: 20),
        const Align(
          alignment: Alignment.centerLeft,
          child: Text(
            "Définissez votre mot de passe :",
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _passwordController,
          obscureText: _obscure,
          decoration: InputDecoration(
            labelText: "Mot de passe (min 6 caractères)",
            prefixIcon: const Icon(Icons.lock),
            suffixIcon: IconButton(
              icon: Icon(
                  _obscure ? Icons.visibility : Icons.visibility_off),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12)),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide:
              const BorderSide(color: Colors.indigo, width: 2),
            ),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _confirmController,
          obscureText: _obscure,
          decoration: InputDecoration(
            labelText: "Confirmer le mot de passe",
            prefixIcon: const Icon(Icons.lock_outline),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12)),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide:
              const BorderSide(color: Colors.indigo, width: 2),
            ),
          ),
          onSubmitted: (_) => _activateSchool(),
        ),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          height: 52,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.indigo,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: _isLoading ? null : _activateSchool,
            child: _isLoading
                ? const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.white),
            )
                : const Text("Activer mon compte",
                style: TextStyle(fontSize: 16)),
          ),
        ),
        const SizedBox(height: 12),
        TextButton(
          onPressed: () => setState(() {
            _mode     = 'new_id';
            _errorMsg = null;
          }),
          child: const Text("← Retour"),
        ),
      ],
    );
  }

  Widget _buildLoginStep() {
    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.blue.shade50,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.blue.shade200),
          ),
          child: const Text(
            "ℹ️ Le code école est visible dans Paramètres → "
                "\"Code de l'école\" (ex: MAPENDO, AMANI...).\n"
                "Il vous a été envoyé lors de votre première connexion.",
            style: TextStyle(fontSize: 12, color: Colors.blueGrey),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _codeController,
          textCapitalization: TextCapitalization.characters,
          decoration: InputDecoration(
            labelText: "Code de l'école",
            hintText: "Ex: MAPENDO",
            prefixIcon: const Icon(Icons.school, color: Colors.green),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12)),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide:
              const BorderSide(color: Colors.green, width: 2),
            ),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _passwordController,
          obscureText: _obscure,
          decoration: InputDecoration(
            labelText: "Mot de passe",
            prefixIcon: const Icon(Icons.lock),
            suffixIcon: IconButton(
              icon: Icon(
                  _obscure ? Icons.visibility : Icons.visibility_off),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12)),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide:
              const BorderSide(color: Colors.green, width: 2),
            ),
          ),
          onSubmitted: (_) => _loginWithCodeAndPassword(),
        ),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          height: 52,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: _isLoading ? null : _loginWithCodeAndPassword,
            child: _isLoading
                ? const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.white),
            )
                : const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.cloud_download, size: 20),
                SizedBox(width: 8),
                Text(
                  "Se connecter et récupérer mes données",
                  style: TextStyle(fontSize: 15),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        TextButton(
          onPressed: _reset,
          child: const Text("← Retour"),
        ),
      ],
    );
  }
}