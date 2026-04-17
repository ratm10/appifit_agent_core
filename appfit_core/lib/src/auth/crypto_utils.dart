import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:flutter/foundation.dart';

/// Waldlust Platform V2 암호화 유틸리티
///
/// AES-256-GCM 암호화/복호화 및 HMAC-SHA512 서명을 제공합니다.
class CryptoUtils {
  /// AES-256 키가 요구하는 바이트 길이 (32 bytes = 256 bits)
  static const int aesKeyBytes = 32;

  /// AES-256-GCM 암호화
  ///
  /// [plainText]: 암호화할 평문
  /// [aesKeyString]: 32바이트 AES 키 (Waldlust 제공)
  ///
  /// Returns: Base64( IV + EncryptedData + AuthTag )
  static String encryptAesGcm(String plainText, String aesKeyString) {
    try {
      // 1. AES 키 준비 (32바이트)
      final keyBytes = _prepareKey(aesKeyString);
      final key = encrypt.Key(keyBytes);

      // 2. IV 생성 (12바이트)
      final iv = _generateIV();

      // 3. AES-256-GCM 암호화
      final encrypter = encrypt.Encrypter(
        encrypt.AES(key, mode: encrypt.AESMode.gcm),
      );

      final encrypted = encrypter.encrypt(plainText, iv: iv);

      // 4. IV + EncryptedData + AuthTag 결합
      final combined = Uint8List.fromList([...iv.bytes, ...encrypted.bytes]);

      // 5. Base64 인코딩
      return base64.encode(combined);
    } catch (e) {
      throw Exception('AES-GCM 암호화 실패: $e');
    }
  }

  /// AES-256-GCM 복호화
  ///
  /// [encryptedText]: Base64 인코딩된 암호문
  /// [aesKeyString]: 32바이트 AES 키 (Waldlust 제공)
  ///
  /// Returns: 평문
  static String decryptAesGcm(String encryptedText, String aesKeyString) {
    try {
      // 1. Base64 디코딩
      final combined = base64.decode(encryptedText);

      // 2. IV와 암호화된 데이터 분리
      final iv = encrypt.IV(Uint8List.fromList(combined.sublist(0, 12)));
      final encryptedBytes = Uint8List.fromList(combined.sublist(12));

      // 3. AES 키 준비
      final keyBytes = _prepareKey(aesKeyString);
      final key = encrypt.Key(keyBytes);

      // 4. 복호화
      final encrypter = encrypt.Encrypter(
        encrypt.AES(key, mode: encrypt.AESMode.gcm),
      );

      final decrypted = encrypter.decrypt(
        encrypt.Encrypted(encryptedBytes),
        iv: iv,
      );

      return decrypted;
    } catch (e) {
      throw Exception('AES-GCM 복호화 실패: $e');
    }
  }

  /// HMAC-SHA512 서명 생성
  ///
  /// [secret]: Project API Key (평문)
  /// [payload]: JSON 페이로드 (공백 없는 compact 형식)
  ///
  /// Returns: Base64 인코딩된 서명
  static String generateHmacSha512Signature(String secret, String payload) {
    try {
      // 1. UTF-8 인코딩
      final secretBytes = utf8.encode(secret);
      final payloadBytes = utf8.encode(payload);

      // 2. HMAC-SHA512 계산
      final hmac = Hmac(sha512, secretBytes);
      final digest = hmac.convert(payloadBytes);

      // 3. Base64 인코딩
      return base64.encode(digest.bytes);
    } catch (e) {
      throw Exception('HMAC-SHA512 서명 생성 실패: $e');
    }
  }

  /// JSON 페이로드 생성 (공백 없는 compact 형식)
  ///
  /// [data]: JSON 데이터
  ///
  /// Returns: 공백 없는 JSON 문자열
  static String createCompactJson(Map<String, dynamic> data) {
    return jsonEncode(data);
  }

  /// 주어진 문자열을 UTF-8로 인코딩했을 때 AES-256 키 길이(32바이트)와
  /// 일치하는지 확인합니다.
  ///
  /// 소비자 앱이 서버로부터 수신한 aesKey를 통신 전 검증할 때 사용하세요.
  /// `_prepareKey()` 는 검증에 실패해도 패딩/자르기로 동작을 이어가지만,
  /// 잘못된 길이의 키는 **암호화 강도 저하**를 의미하므로 사전에 감지하는
  /// 것이 바람직합니다.
  static bool isValidAesKey(String keyString) {
    return utf8.encode(keyString).length == aesKeyBytes;
  }

  /// 32바이트 AES 키 준비
  ///
  /// 현재는 운영에서 수신되는 키 길이가 확인되지 않아 기존 동작(패딩/자르기)을
  /// 유지하되, 불일치 시 디버그 빌드에서만 경고 로그를 출력합니다. 이후
  /// 실측 로그를 바탕으로 엄격 검증으로 전환할 수 있습니다.
  static Uint8List _prepareKey(String keyString) {
    final keyBytes = utf8.encode(keyString);
    if (keyBytes.length == aesKeyBytes) {
      return Uint8List.fromList(keyBytes);
    }

    if (kDebugMode) {
      debugPrint(
        '[CryptoUtils] ⚠️ AES 키 길이 불일치: '
        '${keyBytes.length} bytes (expected: $aesKeyBytes). '
        '자동 보정(패딩/자르기)으로 동작하지만 암호화 강도가 저하될 수 있습니다.',
      );
    }

    if (keyBytes.length > aesKeyBytes) {
      return Uint8List.fromList(keyBytes.sublist(0, aesKeyBytes));
    }

    // 32바이트보다 짧으면 0바이트 패딩 (주의: 키 엔트로피 손실)
    final paddedKey = Uint8List(aesKeyBytes);
    paddedKey.setRange(0, keyBytes.length, keyBytes);
    return paddedKey;
  }

  /// 12바이트 IV (Initialization Vector) 생성
  static encrypt.IV _generateIV() {
    final random = Random.secure();
    final ivBytes = Uint8List(12);
    for (int i = 0; i < 12; i++) {
      ivBytes[i] = random.nextInt(256);
    }
    return encrypt.IV(ivBytes);
  }
}
