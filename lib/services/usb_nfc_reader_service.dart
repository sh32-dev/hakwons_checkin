import 'dart:async';

import 'package:flutter/services.dart';

sealed class UsbNfcReaderEvent {
  const UsbNfcReaderEvent();
}

class UsbNfcReaderUid extends UsbNfcReaderEvent {
  final String uid;
  const UsbNfcReaderUid(this.uid);
}

class UsbNfcReaderStatus extends UsbNfcReaderEvent {
  final String message;
  const UsbNfcReaderStatus(this.message);
}

class UsbNfcReaderError extends UsbNfcReaderEvent {
  final String message;
  const UsbNfcReaderError(this.message);
}

class UsbNfcReaderService {
  static const _methodChannel = MethodChannel('hakwons_checkin/acr122u');
  static const _eventChannel = EventChannel('hakwons_checkin/acr122u_events');

  static Stream<UsbNfcReaderEvent> events() {
    return _eventChannel.receiveBroadcastStream().map((raw) {
      final event = Map<String, dynamic>.from(raw as Map);
      final type = event['type'] as String?;
      final message = event['message'] as String? ?? '';
      switch (type) {
        case 'uid':
          return UsbNfcReaderUid(event['uid'] as String? ?? '');
        case 'status':
          return UsbNfcReaderStatus(message);
        case 'error':
        default:
          return UsbNfcReaderError(
            message.isEmpty ? '리더기 오류가 발생했습니다.' : message,
          );
      }
    });
  }

  static Future<void> start() async {
    await _methodChannel.invokeMethod<void>('start');
  }

  static Future<void> stop() async {
    await _methodChannel.invokeMethod<void>('stop');
  }
}
