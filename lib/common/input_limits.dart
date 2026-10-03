import 'package:flutter/services.dart';

abstract final class TextInputLimits {
  static const name = 64;
  static const groupName = 64;
  static const proxyName = 255;
  static const url = 2048;
  static const uri = url;
  static const iconUrl = url;
  static const dnsServer = url;
  static const hostValue = url;
  static const userName = 128;
  static const password = 512;
  static const userAgent = 512;
  static const fileName = 255;
  static const port = 5;
  static const number = 10;
  static const decimal = 7;
  static const interval = number;
  static const search = 256;
  static const rule = 1024;
  static const filter = 1024;
  static const status = 128;
  static const dnsListen = 255;
  static const domain = 512;
  static const geoSite = 128;
  static const geoIpCode = 16;
  static const cidr = 64;

  static List<TextInputFormatter> limit(int maxLength) {
    return [LengthLimitingTextInputFormatter(maxLength)];
  }

  static List<TextInputFormatter> digitsOnly(int maxLength) {
    return [
      FilteringTextInputFormatter.digitsOnly,
      LengthLimitingTextInputFormatter(maxLength),
    ];
  }

  static List<TextInputFormatter> decimalOnly(int maxLength) {
    return [
      // A whole-string filter, so a second separator can never reach the parser
      // and a half-typed "0.25." cannot silently clear a saved value. A comma is
      // accepted because several keyboards, ru and de among them, use it.
      TextInputFormatter.withFunction((oldValue, newValue) {
        final text = newValue.text;
        return text.isEmpty || RegExp(r'^\d*[.,]?\d*$').hasMatch(text)
            ? newValue
            : oldValue;
      }),
      LengthLimitingTextInputFormatter(maxLength),
    ];
  }
}
