// ble_audio_service.dart
// PulseHear v27 - BLE + YAMNet Audio Service
// يربط BLE مع YAMNet
// عند استقبال BG من ESP32 → يسجّل صوت → يصنّف YAMNet → إشعار

import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:record/record.dart';
import 'bluetooth_service.dart';
import 'yamnet_classifier.dart';

class BleAudioService extends ChangeNotifier {
  final BluetoothService bleService;
  final YamnetClassifier _yamnet = YamnetClassifier();
  final AudioRecorder _recorder = AudioRecorder();
  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  bool isListening = false;
  String lastYamnetLabel = '';

  BleAudioService({required this.bleService}) {
    _init();
  }

  Future<void> _init() async {
    await _yamnet.init();
    await _initNotifications();
    // ربط callback BLE
    bleService.onSignalReceived = _handleBleSignal;
    print('[BleAudioService] Initialized');
  }

  Future<void> _initNotifications() async {
    const AndroidInitializationSettings androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const InitializationSettings settings =
        InitializationSettings(android: androidSettings);
    await _notifications.initialize(settings);
  }

  // معالجة إشارات BLE
  Future<void> _handleBleSignal(String signal) async {
    print('[BleAudioService] Signal: $signal');
    switch (signal.toUpperCase()) {
      case 'FIRE':
        await _sendNotification(
          title: '🔥 تحذير حريق!',
          body: 'تم اكتشاف صوت جرس الحريق',
          id: 1,
        );
        break;
      case 'BABY':
        await _sendNotification(
          title: '👶 بكاء طفل!',
          body: 'تم اكتشاف بكاء طفل',
          id: 2,
        );
        break;
      case 'ATHAN':
        await _sendNotification(
          title: '🕌 أذان!',
          body: 'حان وقت الصلاة',
          id: 3,
        );
        break;
      case 'BG':
      case 'BACKGROUND':
        // يشغّل YAMNet على الهاتف
        await _analyzeWithYamnet();
        break;
      default:
        // keyword مخصص
        await _sendNotification(
          title: '🔔 صوت مخصص!',
          body: 'تم اكتشاف: $signal',
          id: 4,
        );
    }
  }

  Future<void> _analyzeWithYamnet() async {
    if (isListening) return;
    if (!await _recorder.hasPermission()) {
      print('[BleAudioService] No mic permission');
      return;
    }

    isListening = true;
    notifyListeners();

    try {
      // تسجيل 0.975 ثانية (15600 عينة @ 16kHz)
      final stream = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
        ),
      );

      final List<int> audioBytes = [];
      StreamSubscription? sub;

      sub = stream.listen((chunk) {
        audioBytes.addAll(chunk);
        if (audioBytes.length >= 31200) {
          // 15600 samples * 2 bytes
          sub?.cancel();
          _recorder.stop();
          _classifyAudio(Uint8List.fromList(audioBytes.take(31200).toList()));
        }
      });

      // timeout 2 ثانية
      Future.delayed(const Duration(seconds: 2), () {
        if (isListening) {
          sub?.cancel();
          _recorder.stop();
          if (audioBytes.isNotEmpty) {
            _classifyAudio(Uint8List.fromList(audioBytes));
          }
        }
      });
    } catch (e) {
      print('[BleAudioService] Record error: $e');
      isListening = false;
      notifyListeners();
    }
  }

  void _classifyAudio(Uint8List audioBytes) {
    try {
      final result = _yamnet.classify(audioBytes);
      final label = result['label'] as String;
      final confidence = result['confidence'] as double;

      print('[YAMNet] $label ($confidence)');
      lastYamnetLabel = label;
      bleService.lastDetectedLabel = label;
      bleService.notifyListeners();
      notifyListeners();

      // إشعار بناءً على نتيجة YAMNet
      if (confidence > 0.4 && label.isNotEmpty) {
        _sendYamnetNotification(label, confidence);
      }
    } catch (e) {
      print('[BleAudioService] Classify error: $e');
    } finally {
      isListening = false;
      notifyListeners();
    }
  }

  Future<void> _sendYamnetNotification(String label, double confidence) async {
    final Map<String, Map<String, String>> labels = {
      'SPEECH': {'title': '🗣️ صوت بشري', 'body': 'يتحدث أحد بالقرب'},
      'SIREN': {'title': '🚨 صفارة!', 'body': 'سمعت سيارة طوارئ أو إسعاف'},
      'ALARM': {'title': '⏰ جرس تنبيه!', 'body': 'تم اكتشاف جرس تنبيه'},
      'DOG': {'title': '🐕 نباح كلب!', 'body': 'هناك كلب بالقرب'},
      'DOORBELL': {'title': '🔔 جرس الباب!', 'body': 'شخص يدق الباب'},
      'MUSIC': {'title': '🎵 موسيقى', 'body': 'تم كشف موسيقى بالقرب'},
    };

    final info = labels[label.toUpperCase()];
    if (info != null) {
      await _sendNotification(
        title: info['title']!,
        body: '${info['body']!} (${(confidence * 100).toStringAsFixed(0)}%)',
        id: 10,
      );
    }
  }

  Future<void> _sendNotification({
    required String title,
    required String body,
    required int id,
  }) async {
    const AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
      'pulsehear_channel',
      'PulseHear Alerts',
      channelDescription: 'Sound detection alerts',
      importance: Importance.max,
      priority: Priority.high,
      enableVibration: true,
    );
    const NotificationDetails details =
        NotificationDetails(android: androidDetails);
    await _notifications.show(id, title, body, details);
  }

  @override
  void dispose() {
    _recorder.dispose();
    _yamnet.dispose();
    super.dispose();
  }
}
