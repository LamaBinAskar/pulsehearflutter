import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/bluetooth_service.dart';
import '../services/ble_audio_service.dart';

class HomeScreen extends StatefulWidget {
  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late BluetoothService _bleService;
  late BleAudioService _audioService;
  String _status = 'جاهز للاستماع...';
  String _lastDetection = '';
  final TextEditingController _keywordController = TextEditingController();

  @override
  void initState() {
    super.initState();
    // إنشاء الخدمات
    _bleService = BluetoothService();
    _audioService = BleAudioService(bleService: _bleService);

    // تحديث الواجهة عند تغيير
    _audioService.addListener(_updateUI);
    _bleService.addListener(_updateUI);
  }

  void _updateUI() {
    setState(() {
      _status = _audioService.isListening ? 'يستمع...' : (_bleService.isConnected ? 'متصل' : 'غير متصل');
      _lastDetection = _audioService.lastYamnetLabel.isNotEmpty 
        ? 'آخر صوت: ${_audioService.lastYamnetLabel}'
        : _bleService.lastDetectedLabel.isNotEmpty
          ? 'آخر إشارة: ${_bleService.lastDetectedLabel}'
          : 'انتظر إشارة من السوار';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('PulseHear'),
        backgroundColor: Color(0xFF71A39E),
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: Icon(_bleService.isConnected ? Icons.bluetooth_connected : Icons.bluetooth),
            onPressed: () {
              if (_bleService.isConnected) {
                _bleService.disconnect();
              } else {
                _bleService.startScan();
              }
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(height: 20),
            Icon(
              Icons.hearing_outlined,
              size: 120,
              color: Color(0xFF005352),
            ),
            SizedBox(height: 30),
            Text(
              _status,
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 20),
            Container(
              padding: EdgeInsets.all(15),
              decoration: BoxDecoration(
                color: Colors.grey[200],
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                _lastDetection,
                style: TextStyle(fontSize: 18),
                textAlign: TextAlign.center,
              ),
            ),
            SizedBox(height: 30),
            
            // قسم الكلمات المفتاحية
            Card(
              color: Color(0xFFF5F5F5),
              child: Padding(
                padding: EdgeInsets.all(15),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'الكلمات المفتاحية',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                    ),
                    SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _audioService.keywords
                          .map((keyword) => Chip(
                                label: Text(keyword),
                                deleteIcon: Icon(Icons.close, size: 18),
                                onDeleted: () => _audioService.removeKeyword(keyword),
                              ))
                          .toList(),
                    ),
                    SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _keywordController,
                            decoration: InputDecoration(
                              hintText: 'أضف كلمة جديدة',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        SizedBox(width: 10),
                        ElevatedButton(
                          onPressed: () {
                            if (_keywordController.text.isNotEmpty) {
                              _audioService.addKeyword(_keywordController.text);
                              _keywordController.clear();
                            }
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Color(0xFF005352),
                            foregroundColor: Colors.white,
                          ),
                          child: Icon(Icons.add),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            
            SizedBox(height: 20),
            
            // زر اختبار
            ElevatedButton(
              onPressed: () async {
                // محاكاة إشارة BG من ESP32
                await _audioService._handleBleSignal('BG');
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Color(0xFF005352),
                foregroundColor: Colors.white,
                padding: EdgeInsets.symmetric(horizontal: 40, vertical: 15),
              ),
              child: Text('اختبار YAMNet'),
            ),
            
            SizedBox(height: 10),
            
            if (_audioService.lastRecognizedText.isNotEmpty)
              Card(
                color: Colors.amber[50],
                child: Padding(
                  padding: EdgeInsets.all(10),
                  child: Column(
                    children: [
                      Text('النص المعترف به:',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                      SizedBox(height: 5),
                      Text(_audioService.lastRecognizedText),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _audioService.removeListener(_updateUI);
    _bleService.removeListener(_updateUI);
    _audioService.dispose();
    _bleService.dispose();
    _keywordController.dispose();
    super.dispose();
  }
}
