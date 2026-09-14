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
    // Çökmeyi önlemek için Bluetooth adaptör durumunu kontrollü dinliyoruz
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
        // Hata
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1E1E24),
      body: Center(
        child: Container(
          width: 390, height: 844,
          margin: const EdgeInsets.symmetric(vertical: 20),
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(40),
            border: Border.all(color: const Color(0xFF3A3A3C), width: 8),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(128),
                blurRadius: 20, 
                spreadRadius: 5
              )
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(32),
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 12.0),
                child: Column(
                  children: [
                    Container(
                      width: 110, height: 22,
                      decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(15)),
                    ),
                    const SizedBox(height: 15),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 10.0),
                      decoration: BoxDecoration(
                        color: const Color(0xFF07140B),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.green.shade800, width: 1.5),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: List.generate(maxRows, (rowIndex) {
                          return Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: List.generate(maxCols, (colIndex) {
                              bool isCursor = (rowIndex == cursorRow && colIndex == cursorCol);
                              String char = screenBuffer[rowIndex][colIndex];
                              return Container(
                                width: 15, height: 19,
                                alignment: Alignment.center,
                                color: isCursor ? Colors.greenAccent.shade400 : Colors.transparent,
                                child: Text(
                                  char,
                                  style: TextStyle(
                                    fontFamily: 'Courier', fontSize: 15.5,
                                    fontWeight: isCursor ? FontWeight.w900 : FontWeight.w700,
                                    color: isCursor ? Colors.black : Colors.greenAccent.shade400,
                                  ),
                                ),
                              );
                            }),
                          );
                        }),
                      ),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 16),
                      decoration: BoxDecoration(color: const Color(0xFF1C1C1E), borderRadius: BorderRadius.circular(24)),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              _buildLargeKeyButton('ESC', Colors.red.shade900, () => _handleKeyPress('ESC')),
                              _buildLargeKeyButton('▲\nUP', const Color(0xFF2C2C2E), () => _handleKeyPress('UP')),
                              _buildLargeKeyButton('ENTER', Colors.green.shade700, () => _handleKeyPress('ENTER')),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              _buildLargeKeyButton('◀\nLEFT', const Color(0xFF2C2C2E), () => _handleKeyPress('LEFT')),
                              _buildLargeKeyButton('▼\nDOWN', const Color(0xFF2C2C2E), () => _handleKeyPress('DOWN')),
                              _buildLargeKeyButton('RIGHT\n▶', const Color(0xFF2C2C2E), () => _handleKeyPress('RIGHT')),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLargeKeyButton(String label, Color color, VoidCallback onPressed) {
    return SizedBox(
      width: 102, height: 90,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: color, foregroundColor: Colors.white, padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          elevation: 6,
        ),
        onPressed: onPressed,
        child: Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, height: 1.3), textAlign: TextAlign.center),
      ),
    );
  }
}
