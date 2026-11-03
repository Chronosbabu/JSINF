import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppState extends ChangeNotifier {
  bool isDarkMode = false;
  String schoolName = "EduPay School RDC";
  String? schoolCode;
  String? backupPassword;

  bool initialized = false;

  AppState() {
    _loadPreferences();
  }

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    isDarkMode = prefs.getBool('isDarkMode') ?? false;
    schoolName = prefs.getString('schoolName') ?? "EduPay School RDC";
    schoolCode = prefs.getString('schoolCode');
    backupPassword = prefs.getString('backupPassword');
    initialized = true;
    notifyListeners();
  }

  Future<void> toggleTheme() async {
    isDarkMode = !isDarkMode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('isDarkMode', isDarkMode);
    notifyListeners();
  }

  Future<void> updateSchoolName(String newName) async {
    schoolName = newName.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('schoolName', schoolName);
    notifyListeners();
  }

  Future<void> setSchoolCode(String code) async {
    final normalized =
    code.trim().toUpperCase().replaceAll(RegExp(r'\s+'), '');
    schoolCode = normalized;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('schoolCode', schoolCode!);
    notifyListeners();
  }

  Future<void> setBackupPassword(String password) async {
    backupPassword = password.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('backupPassword', backupPassword!);
    notifyListeners();
  }

  // ⚡ AJOUTÉ — cette méthode était appelée depuis settings_screen.dart
  // (_deconnexion) mais n'était jamais définie, provoquant l'erreur de
  // compilation "The method 'logout' isn't defined for the type
  // 'AppState'". Elle efface la session complète (code école, mot de
  // passe, nom d'école) à la fois en mémoire et dans SharedPreferences,
  // pour repartir sur RecoveryScreen totalement vierge.
  Future<void> logout() async {
    schoolCode = null;
    backupPassword = null;
    schoolName = "EduPay School RDC";
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('schoolCode');
    await prefs.remove('backupPassword');
    await prefs.remove('schoolName');
    notifyListeners();
  }
}