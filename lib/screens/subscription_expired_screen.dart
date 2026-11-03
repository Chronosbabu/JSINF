import 'package:flutter/material.dart';
import 'subscription_service.dart';
import 'school_home_screen.dart';

// ============================================================================
// ⚡⚡⚡ NOUVEAU — ÉCRAN "ABONNEMENT EXPIRÉ"
// ============================================================================
// Écran BLOQUANT (aucun bouton retour, PopScope désactivé) affiché dès que :
//   - SubscriptionService.guardOrRedirect() détecte que l'abonnement est
//     expiré LOCALEMENT au démarrage/redémarrage de l'appli (fonctionne
//     même sans internet, grâce au cache local subscription_data.json) ; ou
//   - RecoveryScreen détecte, juste après /verify_password, que le serveur
//     renvoie subscription.valid == false lors d'une connexion sur un
//     NOUVEL appareil (même code école + mot de passe) — voir la fonction
//     _loginWithCodeAndPassword mise à jour dans recovery_screen.dart.
//
// L'utilisateur ne peut sortir de cet écran qu'en saisissant une clé de
// reconnexion valide (RECO-XXXX-XXXX-XXXX), générée par l'administrateur
// EduPay depuis admin_panel.py (onglet "Abonnements & clés de reconnexion").
// Cette clé est envoyée au serveur via
// SubscriptionService.redeemReconnectionKey, qui redémarre une période
// d'abonnement complète côté serveur (60 secondes en mode test, 30 jours
// en production — voir SUBSCRIPTION_TEST_MODE dans le fichier serveur).
// ============================================================================
class SubscriptionExpiredScreen extends StatefulWidget {
  final String schoolCode;

  const SubscriptionExpiredScreen({super.key, required this.schoolCode});

  @override
  State<SubscriptionExpiredScreen> createState() =>
      _SubscriptionExpiredScreenState();
}

class _SubscriptionExpiredScreenState
    extends State<SubscriptionExpiredScreen> {
  final _keyController = TextEditingController();
  bool _isLoading = false;
  String? _errorMsg;

  @override
  void dispose() {
    _keyController.dispose();
    super.dispose();
  }

  // ⚡ Même logique de nettoyage robuste que dans RecoveryScreen._sanitize
  // (copier-coller WhatsApp/Word avec espaces insécables invisibles).
  String _sanitizeKey(String raw) {
    return raw
        .trim()
        .toUpperCase()
        .replaceAll('\u00A0', '')
        .replaceAll(RegExp(r'\s+'), '');
  }

  Future<void> _submitKey() async {
    final key = _sanitizeKey(_keyController.text);
    if (key.isEmpty) {
      setState(() => _errorMsg = "Veuillez entrer la clé de reconnexion.");
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMsg = null;
    });

    final result = await SubscriptionService.instance.redeemReconnectionKey(
      schoolCode: widget.schoolCode,
      key: key,
    );

    if (!mounted) return;

    if (result['success'] == true) {
      await _showSuccessDialog();
    } else {
      setState(() {
        _isLoading = false;
        _errorMsg = result['error'] ??
            "Clé de reconnexion invalide. Vérifiez auprès de "
                "l'administrateur EduPay.";
      });
    }
  }

  Future<void> _showSuccessDialog() async {
    setState(() => _isLoading = false);
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape:
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle, size: 64, color: Colors.green),
            const SizedBox(height: 16),
            const Text(
              "Abonnement réactivé !",
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            const Text(
              "Votre accès a été rétabli avec succès.",
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
                if (!mounted) return;
                Navigator.of(context).pushAndRemoveUntil(
                  MaterialPageRoute(builder: (_) => const SchoolHomeScreen()),
                      (route) => false,
                );
              },
              child: const Text("Continuer"),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // ⚡ Empêche totalement de quitter cet écran avec le bouton retour
      // (Android) ou le raccourci clavier (Windows/desktop) : tant que la
      // clé n'est pas validée avec succès, il n'y a AUCUNE échappatoire —
      // exactement le comportement demandé.
      canPop: false,
      child: Scaffold(
        backgroundColor: const Color(0xFFF4F6FB),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: Colors.red.withAlpha(20),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.lock_clock,
                          size: 64, color: Colors.red),
                    ),
                    const SizedBox(height: 24),
                    const Text(
                      "Votre abonnement a expiré",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: Colors.red,
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      "Contactez les administrateurs EduPay pour vous "
                          "fournir la clé de reconnexion.",
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 14, color: Colors.black87),
                    ),
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.indigo.withAlpha(15),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        "Code école : ${widget.schoolCode}",
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.indigo,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(height: 32),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.grey.shade200),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withAlpha(10),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            "Clé de reconnexion",
                            style: TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 15),
                          ),
                          const SizedBox(height: 10),
                          TextField(
                            controller: _keyController,
                            textCapitalization: TextCapitalization.characters,
                            enabled: !_isLoading,
                            decoration: InputDecoration(
                              hintText: "Ex: RECO-A3K9-BZ12-Q7M4",
                              prefixIcon: const Icon(Icons.vpn_key,
                                  color: Colors.indigo),
                              border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12)),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: const BorderSide(
                                    color: Colors.indigo, width: 2),
                              ),
                            ),
                            onSubmitted: (_) =>
                            _isLoading ? null : _submitKey(),
                          ),
                          const SizedBox(height: 16),
                          SizedBox(
                            width: double.infinity,
                            height: 50,
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.indigo,
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12)),
                              ),
                              onPressed: _isLoading ? null : _submitKey,
                              child: _isLoading
                                  ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white),
                              )
                                  : const Text("Valider la clé",
                                  style: TextStyle(fontSize: 15)),
                            ),
                          ),
                          if (_errorMsg != null) ...[
                            const SizedBox(height: 14),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Colors.red.shade50,
                                borderRadius: BorderRadius.circular(10),
                                border:
                                Border.all(color: Colors.red.shade200),
                              ),
                              child: Text(
                                _errorMsg!,
                                style: TextStyle(color: Colors.red.shade700),
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      "Cet écran restera affiché tant que la clé de "
                          "reconnexion n'aura pas été validée, même en "
                          "redémarrant l'application ou en changeant "
                          "d'ordinateur.",
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}