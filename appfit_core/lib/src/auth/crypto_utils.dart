import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as encrypt;
import 'dart:math';

/// Waldlust Platform V2 암호화 유틸리티
///
/// AES-256-GCM 암호화/복호화 및 HMAC-SHA512 서명을 제공합니다.
class CryptoUtils {
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

  /// 32바이트 AES 키 준비
  static Uint8List _prepareKey(String keyString) {
    final keyBytes = utf8.encode(keyString);
    if (keyBytes.length >= 32) {
      return Uint8List.fromList(keyBytes.sublist(0, 32));
    } else {
      // 32바이트보다 짧으면 패딩
      final paddedKey = Uint8List(32);
      paddedKey.setRange(0, keyBytes.length, keyBytes);
      return paddedKey;
    }
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
