import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:process_run/shell.dart';
import 'package:xml/xml.dart' as xml;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(UpdateApp());
}

class UpdateApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.deepPurple,
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            padding: EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          ),
        ),
      ),
      home: UpdateScreen(),
    );
  }
}

class UpdateScreen extends StatefulWidget {
  @override
  _UpdateScreenState createState() => _UpdateScreenState();
}

class _UpdateScreenState extends State<UpdateScreen> {
  String downloadDir = "";
  String processingPackage = "";
  bool _isUpdating = false;
  List<Map<String, String>> apps = [];

  @override
  void initState() {
    super.initState();
    _requestPermissions();
    _setDownloadDirectory();
    _fetchAppUpdates();
    _checkRootAccess();
  }

  Future<void> _setDownloadDirectory() async {
    Directory? directory = await getExternalStorageDirectory(); // For Android
    if (directory != null) {
      setState(() {
        downloadDir = directory.path;
      });
      print("Download directory set to: $downloadDir");
    } else {
      print("⚠️ Unable to get external storage directory");
    }
  }

  Future<void> _checkRootAccess() async {
    try {
      var shell = Shell();
      var result = await shell.run('which su');
      if (result.isNotEmpty) {
        _showSnackbar("Device is rooted!", bgColor: Colors.red);
      }
    } catch (e) {
      print("Root check failed: $e");
    }
  }

  Future<void> _requestPermissions() async {
    if (Platform.isAndroid) {
      if (await Permission.storage.request().isGranted) {
        print("✅ Storage permission granted.");
      } else if (await Permission.manageExternalStorage.request().isGranted) {
        print("✅ Manage External Storage permission granted.");
      } else {
        print("⚠️ Storage permission denied!");
      }
    }
  }

  Future<void> _fetchAppUpdates() async {
    try {
      final response = await http.get(Uri.parse('https://play.svayusol.com/apps/appsupdate.xml'));
      if (response.statusCode == 200) {
        final document = xml.XmlDocument.parse(response.body);
        final appNodes = document.findAllElements('app');

        apps = appNodes.map((node) => {
              "name": node.findElements('name').first.text,
              "package": node.findElements('packageName').first.text,
              "version": node.findElements('newversion').first.text,
              "url": node.findElements('downloadPath').first.text,
              "icon": node.findElements('iconPath').first.text.trim(),
              "description": node.findElements('description').first.text,
            }).toList();

        setState(() {});
      }
    } catch (e) {
      print("Error fetching XML: $e");
    }
  }

  Future<void> _checkForUpdates(String packageName, String url, String newVersion) async {
    setState(() {
      processingPackage = packageName;
      _isUpdating = true;
    });

    try {
      _showSnackbar("Checking current version of $packageName...");
      String currentVersion = await _getCurrentAppVersion(packageName);

      if (_compareVersions(newVersion, currentVersion)) {
        _showSnackbar("⏳ Downloading update for $packageName...");
        await _downloadAndExtract(url, packageName);
      } else {
        _showSnackbar("✅ $packageName is already up to date.");
      }
    } catch (e) {
      _showSnackbar("⚠️ Error: $e", bgColor: Colors.red);
    } finally {
      setState(() {
        processingPackage = "";
        _isUpdating = false;
      });
    }
  }

  Future<String> _getCurrentAppVersion(String packageName) async {
    try {
      var shell = Shell();
      var result = await shell.run('su -c "dumpsys package $packageName | grep versionName"');
      if (result.isNotEmpty) {
        return result.first.outText.split('=').last.trim();
      }
    } catch (e) {
      print("Error getting current version: $e");
    }
    return "0.0.0";
  }

  bool _compareVersions(String newVersion, String currentVersion) {
    List<String> newParts = newVersion.split('.');
    List<String> currentParts = currentVersion.split('.');

    for (int i = 0; i < newParts.length; i++) {
      int newPart = int.tryParse(newParts[i]) ?? 0;
      int currentPart = int.tryParse(currentParts[i]) ?? 0;

      if (newPart > currentPart) return true;
      if (newPart < currentPart) return false;
    }
    return false;
  }
Future<void> _downloadAndExtract(String url, String packageName) async {
  try {
    String packageDirPath = "$downloadDir/$packageName";
    Directory packageDir = Directory(packageDirPath);
    if (!packageDir.existsSync()) packageDir.createSync(recursive: true);

    String zipPath = "$packageDirPath/$packageName.zip";
    var response = await http.get(Uri.parse(url));
    if (response.statusCode == 200) {
      File zipFile = File(zipPath);
      await zipFile.writeAsBytes(response.bodyBytes);
      await _extractZip(zipPath, packageDirPath);

      // Move extracted files to /data/app/
      await _moveFilesToDataApp(packageDirPath);
    }
  } catch (e) {
    print("Download error: $e");
  }
}

  Future<void> _extractZip(String zipPath, String packageDirPath) async {
    try {
      File zipFile = File(zipPath);
      List<int> bytes = await zipFile.readAsBytes();
      Archive archive = ZipDecoder().decodeBytes(bytes);

      for (ArchiveFile file in archive) {
        if (!file.isFile) continue;

        String extractedFilePath = "$packageDirPath/${file.name.split("/").last}";
        File extractedFile = File(extractedFilePath);
        await extractedFile.writeAsBytes(file.content as List<int>);
      }

      await zipFile.delete();
      _showSnackbar("✅ Files extracted successfully!", bgColor: Colors.green);
    } catch (e) {
      print("⚠️ Extraction error: $e");
    }
  }
  Future<void> _moveFilesToDataApp(String packageDirPath) async {
    try {
      var shell = Shell();
      String packageName = packageDirPath.split('/').last;

      print("🔍 Checking target installation directory...");
      var result = await shell.run('su -c "ls /data/app/ | grep $packageName"');
      if (result.isEmpty) {
        print("❌ Error: Could not find app folder in /data/app/");
        _showSnackbar("❌ Error: Could not find app folder in /data/app/", bgColor: Colors.red);
        return;
      }

      String targetDir = "/data/app/${result.first.outText.trim()}";
      print("📂 Moving files to: $targetDir");

      for (var file in Directory(packageDirPath).listSync(recursive: true)) {
        String relativePath = file.path.replaceFirst("$packageDirPath/", "");
        String targetPath = "$targetDir/$relativePath";

        if (file is File) {
          print("📌 Moving ${file.path} to $targetPath");
          await shell.run('su -c "mv ${file.path} $targetPath && chmod 644 $targetPath"');
        } else if (file is Directory) {
          print("📁 Creating directory $targetPath");
          await shell.run('su -c "mkdir -p $targetPath && chmod 755 $targetPath"');
        }
      }

      print("✅ App files updated successfully!");
      _showSnackbar("✅ App files updated successfully!", bgColor: Colors.green);
    } catch (e) {
      print("⚠️ Move error: $e");
      _showSnackbar("⚠️ Move error: $e", bgColor: Colors.red);
    }
  }


  void _showSnackbar(String message, {Color bgColor = Colors.deepPurple}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, textAlign: TextAlign.center, style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        duration: Duration(seconds: 3),
        backgroundColor: bgColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("Apps Update"), centerTitle: true),
      body: apps.isEmpty
          ? Center(child: CircularProgressIndicator())
          : ListView.builder(
              padding: EdgeInsets.all(10),
              itemCount: apps.length,
              itemBuilder: (context, index) {
                var app = apps[index];
                bool isUpdating = app["package"] == processingPackage;

                return Card(
                  child: ListTile(
                    leading: app["icon"]!.isNotEmpty ? Image.network(app["icon"]!) : Icon(Icons.android),
                    title: Text(app["name"]!),
                    subtitle: Text("Version: ${app["version"]}"),
                    trailing: isUpdating
                        ? CircularProgressIndicator()
                        : ElevatedButton(
                            onPressed: _isUpdating ? null : () => _checkForUpdates(app["package"]!, app["url"]!, app["version"]!),
                            child: Text("Update"),
                          ),
                  ),
                );
              },
            ),
    );
  }
}
