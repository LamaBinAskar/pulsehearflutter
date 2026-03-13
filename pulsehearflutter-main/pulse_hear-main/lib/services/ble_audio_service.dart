// ble_audio_service.dart
// PulseHear v28 - BLE + YAMNet + AraSpot Audio Service
// يربط BLE مع YAMNet ثم AraSpot للكلمات المفتاحية
// عند استقبال BG من ESP32 → يسجّل صوت → يصنّف YAMNet → إذا بشري → AraSpot

import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:record/record.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'bluetooth_service.dart';
import 'yamnet_classifier.dart';

class BleAudioService extends ChangeNotifier {
  final BluetoothService bleService;
  final YamnetClassifier _yamnet = YamnetClassifier();
  final AudioRecorder _recorder = AudioRecorder();
  final stt.SpeechToText _speechToText = stt.SpeechToText();
  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  bool isListening = false;
  String lastYamnetLabel = '';
  String lastRecognizedText = '';
  bool _speechInitialized = false;
  
  // قائمة الكلمات المفتاحية للبحث عنها
  List<String> keywords = [
    'ساعدني',
    'نجدة', 
    'حريق',
    'ماء',
    'خطر',
    'help',
    'fire',
  ];

  BleAudioService({required this.bleService}) {
    _init();
  }

  Future<void> _init() async {
    await _yamnet.init();
    await _initNotifications();
    await _initSpeechToText();
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

  Future<void> _initSpeechToText() async {
    try {
      _speechInitialized = await _speechToText.initialize(
        onStatus: (status) => print('[SpeechToText] Status: $status'),
        onError: (error) => print('[SpeechToText] Error: $error'),
      );
      if (_speechInitialized) {
        print('[SpeechToText] Initialized successfully');
      }
    } catch (e) {
      print('[SpeechToText] Init error: $e');
    }
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

  // تحليل الصوت باستخدام YAMNet
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

  // تصنيف الصوت - يحدد: صوت بشري أو طبيعي
  void _classifyAudio(Uint8List audioBytes) async {
    try {
      final result = _yamnet.classify(audioBytes);
      final label = result['label'] as String;
      final confidence = result['confidence'] as double;

      print('[YAMNet] $label ($confidence)');
      lastYamnetLabel = label;
      bleService.lastDetectedLabel = label;
      bleService.notifyListeners();
      notifyListeners();

      // إذا كان الصوت بشري → روح لـ AraSpot
      if (confidence > 0.4 && _isHumanSound(label)) {
        print('[YAMNet] Detected human sound: $label - triggering speech recognition');
        await _recognizeSpeechForKeywords();
      } else if (confidence > 0.4 && label.isNotEmpty) {
        // صوت طبيعي أو بيئي
        _sendYamnetNotification(label, confidence);
      }
    } catch (e) {
      print('[BleAudioService] Classify error: $e');
    } finally {
      isListening = false;
      notifyListeners();
    }
  }

  // تحقق: هل هو صوت بشري؟
  bool _isHumanSound(String label) {
    final humanLabels = [
      'SPEECH',
      'CONVERSATION', 
      'NARRATION',
      'SPEECH_SYNTHESIZER',
      'CHILD_SPEECH',
      'MALE_SPEECH',
      'FEMALE_SPEECH',
      'VOCAL',
      'VOICE',
      'SHOUT',
      'SCREAM',
      'CRY',
      'YELL',
    ];
    return humanLabels.any((h) => label.toUpperCase().contains(h));
  }

  // AraSpot: تحويل الصوت إلى نص وبحث عن كلمات مفتاحية
  Future<void> _recognizeSpeechForKeywords() async {
    if (!_speechInitialized) {
      print('[SpeechToText] Not initialized');
      return;
    }

    try {
      // استخدام التعرف على الكلام (يدعم العربية)
      await _speechToText.listen(
        onResult: (result) {
          lastRecognizedText = result.recognizedWords;
          print('[SpeechToText] Recognized: $lastRecognizedText');
          
          // البحث عن كلمات مفتاحية
          _checkForKeywords(lastRecognizedText);
        },
        localeId: 'ar_SA', // العربية السعودية
        listenFor: const Duration(seconds: 3),
        pauseFor: const Duration(seconds: 2),
      );

      // إيقاف بعد 5 ثواني
      Future.delayed(const Duration(seconds: 5), () {
        if (_speechToText.isListening) {
          _speechToText.stop();
        }
      });
    } catch (e) {
      print('[SpeechToText] Recognition error: $e');
    }
  }

  // تحقق من وجود كلمات مفتاحية في النص المعترف به
  void _checkForKeywords(String text) {
    final lowerText = text.toLowerCase();
    
    for (String keyword in keywords) {
      if (lowerText.contains(keyword.toLowerCase())) {
        print('[Keywords] Match found: $keyword');
        _sendKeywordNotification(keyword, text);
        break; // أول تطابق فقط
      }
    }
  }

  // إشعار عند اكتشاف كلمة مفتاحية
  Future<void> _sendKeywordNotification(String keyword, String fullText) async {
    await _sendNotification(
      title: '🚨 كلمة مفتاحية: $keyword',
      body: 'تم اكتشاف: "$fullText"',
      id: 20,
    );
  }

  // إشعار بناءً على نتيجة YAMNet (أصوات طبيعية/بيئية)
  Future<void> _sendYamnetNotification(String label, double confidence) async {
    final Map<String, Map<String, String>> labels = {
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

  // إرسال إشعار عام
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

  // إضافة كلمة مفتاحية جديدة
  void addKeyword(String keyword) {
    if (!keywords.contains(keyword)) {
      keywords.add(keyword);
      bleService.sendKeyword(keyword); // أرسل للـ ESP32 أيضاً
      notifyListeners();
    }
  }

  // حذف كلمة مفتاحية
  void removeKeyword(String keyword) {
    keywords.remove(keyword);
    notifyListeners();
  }

  @override
  void dispose() {
    _recorder.dispose();
    _yamnet.dispose();
    _speechToText.cancel();
    super.dispose();
  }
}
