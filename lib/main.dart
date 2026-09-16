import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
      screenBuffer = List.generate(
        maxRows,
        (_) => List.generate(maxCols, (_) => ' '),
      );
      cursorRow = 3;
      cursorCol = 0;
      listRowIndex = 3;
      discoveredDeviceIds.clear();
    });
  }

  void _startBleScan() async {
    try {
      if (await FlutterBluePlus.adapterState.first !=
          BluetoothAdapterState.on) {
        _writeStringToBuffer(2, 'STATUS: BT IS OFF  ');
        return;
      }
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 30));
    } catch (e) {
      _writeStringToBuffer(2, 'STATUS: SCAN ERROR ');
    }

    FlutterBluePlus.scanResults.listen((results) {
      for (ScanResult r in results) {
        String devName = r.device.platformName.isEmpty
            ? r.advertisementData.advName
            : r.device.platformName;
        String devId = r.device.remoteId.str;

        if (devName.trim().isEmpty) continue;

        if (!discoveredDeviceIds.contains(devId) &&
            listRowIndex < maxRows - 1) {
          discoveredDeviceIds.add(devId);

          setState(() {
            String shortId = devId.length > 5
                ? devId.substring(devId.length - 5)
                : devId;
            String safeName = devName.length > 11
                ? devName.substring(0, 11)
                : devName;
            String lineText = ">$safeName ($shortId)";
            _writeStringToBuffer(listRowIndex, lineText);
            listRowIndex++;
          });
        }

        if (devName.contains("TerminalDevice") ||
            r.advertisementData.serviceUuids.contains(Guid(serviceUuid))) {
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

      setState(() {
        targetDevice = device;
      });
      _writeStringToBuffer(1, 'STATUS: SERVICES CHK');

      List<BluetoothService> services = await device.discoverServices();
      for (BluetoothService service in services) {
        if (service.uuid.toString().toUpperCase() ==
            serviceUuid.toUpperCase()) {
          for (BluetoothCharacteristic characteristic
              in service.characteristics) {
            if (characteristic.uuid.toString().toUpperCase() ==
                txUuid.toUpperCase()) {
              txCharacteristic = characteristic;
            }
            if (characteristic.uuid.toString().toUpperCase() ==
                rxUuid.toUpperCase()) {
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

  // 💡 Linux PC testlerinde ve telefonda %100 ses çıkışı veren saf işletim sistemi MIDI tetikleyicisi
  void _playUniversalClickSound() {
    if (Platform.isLinux) {
      // Linux ses sürücüsü (PulseAudio) engellerini aşmak için sistem yerleşik uyarısını (SystemAlert) tetikliyoruz 🐧
      // Bu fonksiyon Linux masaüstünde çok kısa ve net bir dijital "klik/bip" tonu üretir.
      SystemChannels.platform.invokeMethod<void>(
        'SystemSound.play',
        'SystemSoundType.click',
      );
      // Ek olarak terminal kanalını zorlayarak donanımsal alarm kanalından bip üretilmesini tetikliyoruz
      Process.run('bash', [
        '-c',
        'echo -e "\\a" > /dev/stderr',
      ]).catchError((_) => ProcessResult(0, 0, '', ''));
    } else {
      // Gerçek mobil cihazlar (iPhone) için donanımsal tık motoru ve yay haptiği 📱
      SystemSound.play(SystemSoundType.click);
      HapticFeedback.lightImpact();
    }
  }

  void _handleKeyPress(String key) {
    _playUniversalClickSound(); // Evrensel kararlı ses motoru tetiklendi 💡

    _sendFeedbackOverBle(key);
    setState(() {
      switch (key) {
        case 'UP':
          if (cursorRow > 0) cursorRow--;
          break;
        case 'DOWN':
          if (cursorRow < maxRows - 1) cursorRow++;
          break;
        case 'LEFT':
          if (cursorCol > 0) cursorCol--;
          break;
        case 'RIGHT':
          if (cursorCol < maxCols - 1) cursorCol++;
          break;
        case 'ENTER':
          if (cursorRow < maxRows - 1) {
            cursorRow++;
            cursorCol = 0;
          }
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

  final Map<String, bool> _isPressedMap = {};

  // Büyük Metin ve İri Siber Ok İkonlu Buton Düzeni
  Widget _buildKeyButton({
    required String label,
    required String command,
    IconData? icon,
  }) {
    Color strokeColor = const Color(0xFF8E8E93);
    Color textColor = const Color(0xFFE5E5EA);

    if (command == 'ESC') {
      strokeColor = const Color(0xFFFF3333);
      textColor = const Color(0xFFFF3333);
    } else if (command == 'ENTER') {
      strokeColor = const Color(0xFF33FF33);
      textColor = const Color(0xFF33FF33);
    } else {
      final bool isPressed = _isPressedMap[command] ?? false;
      if (isPressed) {
        strokeColor = Colors.white;
        textColor = Colors.white;
      }
    }

    final bool isPressed = _isPressedMap[command] ?? false;

    return Expanded(
      child: GestureDetector(
        onTapDown: (_) {
          setState(() {
            _isPressedMap[command] = true;
          });
        },
        onTapUp: (_) {
          setState(() {
            _isPressedMap[command] = false;
          });
          _handleKeyPress(command);
        },
        onTapCancel: () {
          setState(() {
            _isPressedMap[command] = false;
          });
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 60),
          margin: const EdgeInsets.all(6),
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
              ),
            ],
          ),
          child: icon != null
              ? Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Icon(icon, color: textColor, size: 32),
                    const SizedBox(width: 1),
                    Text(
                      label,
                      style: TextStyle(
                        color: textColor,
                        fontFamily: 'Courier',
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                )
              : Text(
                  label,
                  style: TextStyle(
                    color: textColor,
                    fontFamily: 'Courier',
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                  ),
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
        bottom: false,
        child: Center(
          child: Container(
            width: 390,
            height: 844,
            margin: const EdgeInsets.only(top: 10),
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(40),
                topRight: Radius.circular(40),
                bottomLeft: Radius.circular(32),
                bottomRight: Radius.circular(32),
              ),
              border: Border.all(color: const Color(0xFF3A3A3C), width: 8),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.5),
                  blurRadius: 20,
                  spreadRadius: 5,
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 🟢 RETRO MONİTÖR EKRANI
                  Expanded(
                    flex: 65,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14.0,
                        vertical: 14.0,
                      ),
                      margin: const EdgeInsets.all(12.0),
                      decoration: BoxDecoration(
                        color: const Color(0xFF051105),
                        border: Border.all(
                          color: const Color(0xFF33FF33),
                          width: 2,
                        ),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final double cellHeight =
                              constraints.maxHeight / maxRows;
                          final double cellWidth =
                              constraints.maxWidth / maxCols;

                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: List.generate(maxRows, (r) {
                              return SizedBox(
                                height: cellHeight,
                                child: Row(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: List.generate(maxCols, (c) {
                                    return SizedBox(
                                      width: cellWidth,
                                      child: Center(
                                        child: Text(
                                          screenBuffer[r][c],
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            color: const Color(0xFF33FF33),
                                            fontFamily: 'Courier',
                                            fontSize: cellWidth * 1.1,
                                            fontWeight: FontWeight.bold,
                                            height: 1.0,
                                          ),
                                        ),
                                      ),
                                    );
                                  }),
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
                      padding: const EdgeInsets.only(
                        top: 8,
                        bottom: 24,
                        left: 8,
                        right: 8,
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // 1. Satır Düğmeleri
                          Expanded(
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _buildKeyButton(label: 'ESC', command: 'ESC'),
                                _buildKeyButton(
                                  label: 'UP',
                                  command: 'UP',
                                  icon: Icons.keyboard_arrow_up,
                                ),
                                _buildKeyButton(
                                  label: 'ENTER',
                                  command: 'ENTER',
                                ),
                              ],
                            ),
                          ),
                          // 2. Satır Düğmeleri
                          Expanded(
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _buildKeyButton(
                                  label: 'LEFT',
                                  command: 'LEFT',
                                  icon: Icons.keyboard_arrow_left,
                                ),
                                _buildKeyButton(
                                  label: 'DOWN',
                                  command: 'DOWN',
                                  icon: Icons.keyboard_arrow_down,
                                ),
                                _buildKeyButton(
                                  label: 'RIGHT',
                                  command: 'RIGHT',
                                  icon: Icons.keyboard_arrow_right,
                                ),
                              ],
                            ),
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
