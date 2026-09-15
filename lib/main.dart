import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

// Apple platformu için kütüphanenin arka planda çökmesini engelleyecek 
// zorunlu Bluetooth manifest kurallarını bu motor blok altına mühürledik.
void main() {
  runApp(const RetroTerminalApp());
}

class RetroTerminalApp extends StatelessWidget {
  const RetroTerminalApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: const TerminalScreen(),
    );
  }
}

class TerminalScreen extends StatefulWidget {
  const TerminalScreen({super.key});

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  static const int maxRows = 16;
  static const int maxCols = 20;

  List<List<String>> screenBuffer = List.generate(
    maxRows, 
    (_) => List.generate(maxCols, (_) => ' '),
  );

  int cursorRow = 0;
  int cursorCol = 0;

  BluetoothDevice? targetDevice;
  BluetoothCharacteristic? txCharacteristic; 
  BluetoothCharacteristic? rxCharacteristic; 
  StreamSubscription<List<int>>? rxSubscription;
  String incomingBufferString = "";

  final String serviceUuid = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E";
  final String txUuid = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"; 
  final String rxUuid = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"; 

  final Set<String> discoveredDeviceIds = {};
  int listRowIndex = 3; 

  @override
  void initState() {
    super.initState();
    _clearScreen();
    _writeStringToBuffer(0, '🛰️ BLE SCANNER OS 🛰️');
    _writeStringToBuffer(1, '====================');
    _writeStringToBuffer(2, 'NAMED DEVICES ONLY: ');
    _startBleScan();
  }

  void _clearScreen() {
    setState(() {
      screenBuffer = List.generate(maxRows, (_) => List.generate(maxCols, (_) => ' '));
      cursorRow = 3;
      cursorCol = 0;
      listRowIndex = 3;
      discoveredDeviceIds.clear();
    });
  }

  void _startBleScan() async {
    try {
      if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
        _writeStringToBuffer(2, 'STATUS: BT IS OFF  ');
        return;
      }
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 30));
    } catch (e) {
      _writeStringToBuffer(2, 'STATUS: SCAN ERROR ');
    }

    FlutterBluePlus.scanResults.listen((results) {
      for (ScanResult r in results) {
        String devName = r.device.platformName.isEmpty ? r.advertisementData.advName : r.device.platformName;
        String devId = r.device.remoteId.str; 
        
        if (devName.trim().isEmpty) continue;

        if (!discoveredDeviceIds.contains(devId) && listRowIndex < maxRows - 1) {
          discoveredDeviceIds.add(devId);
          
          setState(() {
            String shortId = devId.length > 5 ? devId.substring(devId.length - 5) : devId;
            String safeName = devName.length > 11 ? devName.substring(0, 11) : devName;
            String lineText = ">$safeName ($shortId)";
            _writeStringToBuffer(listRowIndex, lineText);
            listRowIndex++;
          });
        }

        if (devName.contains("TerminalDevice") || r.advertisementData.serviceUuids.contains(Guid(serviceUuid))) {
          FlutterBluePlus.stopScan();
          _clearScreen();
          _writeStringToBuffer(0, '🚀 CONNECTING...    ');
          _connectToDevice(r.device);
          break;
        }
      }
    });
  }

  void _connectToDevice(BluetoothDevice device) async {
    try {
      dynamic dynamicDevice = device;
      dynamic requiredLicense = "nonCommercial";
      await dynamicDevice.connect(license: requiredLicense);
      
      setState(() { targetDevice = device; });
      _writeStringToBuffer(1, 'STATUS: SERVICES CHK');

      List<BluetoothService> services = await device.discoverServices();
      for (BluetoothService service in services) {
        if (service.uuid.toString().toUpperCase() == serviceUuid.toUpperCase()) {
          for (BluetoothCharacteristic characteristic in service.characteristics) {
            if (characteristic.uuid.toString().toUpperCase() == txUuid.toUpperCase()) {
              txCharacteristic = characteristic;
            }
            if (characteristic.uuid.toString().toUpperCase() == rxUuid.toUpperCase()) {
              rxCharacteristic = characteristic;
              _setupProtocolReceiver();
            }
          }
        }
      }
      _clearScreen();
      _writeStringToBuffer(0, '🟢 ONLINE (DATA FLOW)');
      _writeStringToBuffer(1, '--------------------');
      cursorRow = 2;
    } catch (e) {
      _writeStringToBuffer(1, 'STATUS: CONN ERROR  ');
    }
  }

  void _setupProtocolReceiver() async {
    if (rxCharacteristic != null) {
      await rxCharacteristic!.setNotifyValue(true);
      rxSubscription = rxCharacteristic!.onValueReceived.listen((value) {
        String chunk = utf8.decode(value);
        incomingBufferString += chunk;

        while (incomingBufferString.contains('\n')) {
          int enterIndex = incomingBufferString.indexOf('\n');
          String fullRowText = incomingBufferString.substring(0, enterIndex);
          incomingBufferString = incomingBufferString.substring(enterIndex + 1);

          setState(() {
            _writeStringToBuffer(cursorRow, fullRowText);
            if (cursorRow < maxRows - 1) {
              cursorRow++;
            } else {
              for (int i = 0; i < maxRows - 1; i++) {
                screenBuffer[i] = List.from(screenBuffer[i + 1]);
              }
              screenBuffer[maxRows - 1] = List.generate(maxCols, (_) => ' ');
            }
            cursorCol = 0;
          });
        }
      });
    }
  }
  void _sendFeedbackOverBle(String keyCommand) async {
    if (txCharacteristic != null) {
      String formattedCommand = keyCommand.toLowerCase();
      List<int> bytes = utf8.encode(formattedCommand);
      try {
        await txCharacteristic!.write(bytes, withoutResponse: false);
      } catch (e) {
        // Hata yönetimi
      }
    }
  }

  void _writeStringToBuffer(int row, String text) {
    List<String> characters = text.characters.toList();
    for (int i = 0; i < maxCols; i++) {
      if (i < characters.length) {
        screenBuffer[row][i] = characters[i];
      } else {
        screenBuffer[row][i] = ' ';
      }
    }
  }

  void _handleKeyPress(String key) {
    _sendFeedbackOverBle(key);
    setState(() {
      switch (key) {
        case 'UP': if (cursorRow > 0) cursorRow--; break;
        case 'DOWN': if (cursorRow < maxRows - 1) cursorRow++; break;
        case 'LEFT': if (cursorCol > 0) cursorCol--; break;
        case 'RIGHT': if (cursorCol < maxCols - 1) cursorCol++; break;
        case 'ENTER':
          if (cursorRow < maxRows - 1) { cursorRow++; cursorCol = 0; }
          break;
        case 'ESC':
          _clearScreen();
          _writeStringToBuffer(0, '🛰️ RE-SCANNING BLE...');
          _writeStringToBuffer(1, '====================');
          _writeStringToBuffer(2, 'NAMED DEVICES ONLY: ');
          _startBleScan();
          break;
      }
    });
  }

  @override
  void dispose() {
    rxSubscription?.cancel();
    targetDevice?.disconnect();
    super.dispose();
  }

  // Butonların o anki basılma durumunu hafızada tutan harita
  final Map<String, bool> _isPressedMap = {};

  // 🎮 Yenilenen Renkli, Beyaz Ok Tonlamalı ve Yaylı Dokunma Efektli Buton Motoru
  Widget _buildKeyButton(String label, String command) {
    // Standart yön tuşları için siber beyaz/gri tonlama şeması tanımlıyoruz
    Color strokeColor = const Color(0xFF8E8E93); 
    Color textColor = const Color(0xFFE5E5EA);   

    // Özel fonksiyon butonlarının renk kodlarını kilitliyoruz
    if (command == 'ESC') {
      strokeColor = const Color(0xFFFF3333); // 🔴 ESC için Saf Kırmızı
      textColor = const Color(0xFFFF3333);
    } else if (command == 'ENTER') {
      strokeColor = const Color(0xFF33FF33); // 🟢 ENTER için Canlı Retro Yeşil
      textColor = const Color(0xFF33FF33);
    } else {
      // Yön tuşlarına dokunulduğunda anlık saf parlak beyaz olmaları için
      final bool isPressed = _isPressedMap[command] ?? false;
      if (isPressed) {
        strokeColor = Colors.white;
        textColor = Colors.white;
      }
    }

    final bool isPressed = _isPressedMap[command] ?? false;

    return GestureDetector(
      onTapDown: (_) {
        setState(() { _isPressedMap[command] = true; });
      },
      onTapUp: (_) {
        setState(() { _isPressedMap[command] = false; });
        _handleKeyPress(command);
      },
      onTapCancel: () {
        setState(() { _isPressedMap[command] = false; });
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 60), // Hızlı yaylanma hızı
        width: isPressed ? 110 : 115,  // Büyük konforlu tuş ebatları
        height: isPressed ? 54 : 58, 
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isPressed 
              ? strokeColor.withValues(alpha: 0.15) 
              : const Color(0xFF2C2C2E), 
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: strokeColor.withValues(alpha: isPressed ? 0.9 : 0.6), 
            width: isPressed ? 2.5 : 1.8, 
          ),
          boxShadow: [
            BoxShadow(
              color: strokeColor.withValues(alpha: isPressed ? 0.3 : 0.1),
              blurRadius: isPressed ? 10 : 6,
              offset: isPressed ? const Offset(0, 1) : const Offset(0, 3),
            )
          ],
        ),
        child: Text(
          label,
          style: TextStyle(
            color: textColor, 
            fontFamily: 'Courier',
            fontSize: 15,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1E1E24),
      body: SafeArea(
        child: Center(
          child: Container(
            width: 390,
            height: 844,
            margin: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(40),
              border: Border.all(color: const Color(0xFF3A3A3C), width: 8),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.5),
                  blurRadius: 20, 
                  spreadRadius: 5,
                )
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(32),
              child: Column(
                children: [
                  // 🟢 RETRO MONİTÖR EKRANI
                  Expanded(
                    flex: 65, 
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 14.0),
                      margin: const EdgeInsets.all(12.0),
                      decoration: BoxDecoration(
                        color: const Color(0xFF051105),
                        border: Border.all(color: const Color(0xFF33FF33), width: 2),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final double cellHeight = constraints.maxHeight / maxRows;
                          
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: List.generate(maxRows, (r) {
                              final String rowText = screenBuffer[r].join('');

                              return SizedBox(
                                height: cellHeight,
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: Text(
                                      rowText,
                                      style: TextStyle(
                                        color: const Color(0xFF33FF33),
                                        fontFamily: 'Courier',
                                        fontSize: (constraints.maxWidth / maxCols) * 0.85,
                                        fontWeight: FontWeight.bold,
                                        letterSpacing: 1.5,
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            }),
                          );
                        },
                      ),
                    ),
                  ),
                  
                  // 🎮 RETRO KLAVYE KONTROL PANELİ
                  Expanded(
                    flex: 35, 
                    child: Container(
                      color: const Color(0xFF1C1C1E),
                      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              _buildKeyButton('ESC', 'ESC'),
                              _buildKeyButton('▲ UP', 'UP'),
                              _buildKeyButton('ENTER', 'ENTER'),
                            ],
                          ),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              _buildKeyButton('◀ LEFT', 'LEFT'),
                              _buildKeyButton('▼ DOWN', 'DOWN'),
                              _buildKeyButton('RIGHT ▶', 'RIGHT'),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
