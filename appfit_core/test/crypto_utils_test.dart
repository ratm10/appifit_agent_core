import 'dart:convert';

import 'package:appfit_core/appfit_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// 32바이트(ASCII) 정상 AES 키.
const String _key32 = 'abcdefghijklmnopqrstuvwxyz012345';

/// _key32 와 다른 32바이트 키.
const String _otherKey32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ543210';

Matcher _throwsWrappedException(String prefix) {
  return throwsA(
    isA<Exception>().having(
      (e) => e.toString(),
      'toString',
      startsWith('Exception: $prefix'),
    ),
  );
}

void main() {
  group('CryptoUtils.encryptAesGcm / decryptAesGcm', () {
    test('정상 키로 encrypt→decrypt 라운드트립이 원문을 복원한다', () {
      const plain = 'hello appfit';
      final encrypted = CryptoUtils.encryptAesGcm(plain, _key32);
      final decrypted = CryptoUtils.decryptAesGcm(encrypted, _key32);
      expect(decrypted, plain);
    });

    test('한국어/특수문자 평문도 라운드트립된다', () {
      const plain = '주문 #42 — 김치찌개 x2 (포장)';
      final encrypted = CryptoUtils.encryptAesGcm(plain, _key32);
      expect(CryptoUtils.decryptAesGcm(encrypted, _key32), plain);
    });

    test('IV 가 랜덤이라 같은 입력도 매번 다른 암호문이 나온다 (결정론 아님)', () {
      const plain = 'same input';
      final a = CryptoUtils.encryptAesGcm(plain, _key32);
      final b = CryptoUtils.encryptAesGcm(plain, _key32);
      expect(a, isNot(b), reason: 'IV 12바이트가 매번 랜덤 생성됨');
      // 둘 다 라운드트립은 성립
      expect(CryptoUtils.decryptAesGcm(a, _key32), plain);
      expect(CryptoUtils.decryptAesGcm(b, _key32), plain);
    });

    test('암호문 구조: Base64(IV 12B + 암호화데이터 + AuthTag 16B)', () {
      const plain = 'hello'; // 5바이트
      final encrypted = CryptoUtils.encryptAesGcm(plain, _key32);
      final combined = base64.decode(encrypted);
      expect(combined.length, 12 + 5 + 16);
    });

    test('잘못된 키로 decrypt 하면 Exception 으로 래핑되어 던져진다', () {
      final encrypted = CryptoUtils.encryptAesGcm('secret data', _key32);
      expect(
        () => CryptoUtils.decryptAesGcm(encrypted, _otherKey32),
        _throwsWrappedException('AES-GCM 복호화 실패'),
      );
    });

    test('AuthTag 가 변조된 암호문은 Exception 으로 래핑되어 던져진다', () {
      final encrypted = CryptoUtils.encryptAesGcm('secret data', _key32);
      final bytes = base64.decode(encrypted);
      bytes[bytes.length - 1] ^= 0xFF; // 마지막 바이트(AuthTag) 변조
      final tampered = base64.encode(bytes);
      expect(
        () => CryptoUtils.decryptAesGcm(tampered, _key32),
        _throwsWrappedException('AES-GCM 복호화 실패'),
      );
    });

    test('암호화 데이터 본문이 변조돼도 Exception 으로 래핑되어 던져진다', () {
      final encrypted = CryptoUtils.encryptAesGcm('secret data', _key32);
      final bytes = base64.decode(encrypted);
      bytes[12] ^= 0xFF; // IV 직후 첫 데이터 바이트 변조
      final tampered = base64.encode(bytes);
      expect(
        () => CryptoUtils.decryptAesGcm(tampered, _key32),
        _throwsWrappedException('AES-GCM 복호화 실패'),
      );
    });

    test('Base64 가 아닌 입력도 Exception 으로 래핑되어 던져진다', () {
      expect(
        () => CryptoUtils.decryptAesGcm('not-base64!!!', _key32),
        _throwsWrappedException('AES-GCM 복호화 실패'),
      );
    });

    test('12바이트 미만(IV 보다 짧은) 입력도 Exception 으로 래핑되어 던져진다', () {
      final tooShort = base64.encode([1, 2, 3, 4, 5]);
      expect(
        () => CryptoUtils.decryptAesGcm(tooShort, _key32),
        _throwsWrappedException('AES-GCM 복호화 실패'),
      );
    });

    test('현재 동작 고정(버그 의심): 32바이트 미만 키는 0바이트 패딩으로 자동 보정된다', () {
      // _prepareKey 가 짧은 키를 0x00 패딩하므로, 'short-key' 와
      // 'short-key' + '\x00'*23 은 같은 키로 동작한다 (키 엔트로피 손실).
      const shortKey = 'short-key'; // 9바이트
      final paddedKey = '$shortKey${'\x00' * 23}'; // 32바이트
      final encrypted = CryptoUtils.encryptAesGcm('padded', shortKey);
      expect(CryptoUtils.decryptAesGcm(encrypted, paddedKey), 'padded');
    });

    test('현재 동작 고정(버그 의심): 32바이트 초과 키는 앞 32바이트로 잘려 동작한다', () {
      const longKey = '${_key32}EXTRA-BYTES'; // 43바이트
      final encrypted = CryptoUtils.encryptAesGcm('truncated', longKey);
      // 뒤가 잘리므로 앞 32바이트 키와 동일하게 복호화된다
      expect(CryptoUtils.decryptAesGcm(encrypted, _key32), 'truncated');
    });
  });

  group('CryptoUtils.isValidAesKey', () {
    test('UTF-8 32바이트 키만 true', () {
      expect(CryptoUtils.isValidAesKey(_key32), true);
      expect(CryptoUtils.isValidAesKey('a' * 31), false);
      expect(CryptoUtils.isValidAesKey('a' * 33), false);
      expect(CryptoUtils.isValidAesKey(''), false);
    });

    test('멀티바이트 문자는 바이트 길이 기준으로 판정한다', () {
      // '한' = UTF-8 3바이트 → 10자 + ASCII 2자 = 32바이트
      final korean32Bytes = '${'한' * 10}ab';
      expect(korean32Bytes.length, 12, reason: '문자 수는 12지만');
      expect(CryptoUtils.isValidAesKey(korean32Bytes), true);
    });
  });

  group('CryptoUtils.generateHmacSha512Signature', () {
    test('같은 secret/payload 는 항상 같은 서명을 만든다', () {
      final a = CryptoUtils.generateHmacSha512Signature('secret', 'payload');
      final b = CryptoUtils.generateHmacSha512Signature('secret', 'payload');
      expect(a, b);
    });

    test('secret 이 다르면 서명이 달라진다', () {
      final a = CryptoUtils.generateHmacSha512Signature('secret-1', 'payload');
      final b = CryptoUtils.generateHmacSha512Signature('secret-2', 'payload');
      expect(a, isNot(b));
    });

    test('payload 가 다르면 서명이 달라진다', () {
      final a = CryptoUtils.generateHmacSha512Signature('secret', 'payload-1');
      final b = CryptoUtils.generateHmacSha512Signature('secret', 'payload-2');
      expect(a, isNot(b));
    });

    test('외부 도구 검증 고정 벡터와 일치한다 (openssl)', () {
      // printf '%s' '{"projectId":"P-001","version":1}' \
      //   | openssl dgst -sha512 -hmac 'test-secret-key' -binary | base64
      final signature = CryptoUtils.generateHmacSha512Signature(
        'test-secret-key',
        '{"projectId":"P-001","version":1}',
      );
      expect(
        signature,
        'MY/hYXYEU7wcfSHXFiGgNv6W5ys0o0qLFhQorje7vfg3pv4Yb/mwe6hJoEPNab+x'
        'touJyaoe39mEdIuJ3nKA2g==',
      );
    });
  });

  group('CryptoUtils.createCompactJson', () {
    test('공백 없는 compact JSON 을 삽입 순서대로 만든다', () {
      final json = CryptoUtils.createCompactJson({
        'projectId': 'P-001',
        'version': 1,
      });
      expect(json, '{"projectId":"P-001","version":1}');
    });
  });
}
