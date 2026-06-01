import 'dart:convert';
import 'dart:typed_data';

import '../models/profile.dart';

/// Parses and generates TrustTunnel `tt://` deep links.
///
/// Format: `tt://?<base64url-encoded TLV binary payload>`
///
/// TLV encoding uses QUIC/TLS variable-length integers (RFC 9000 §16).
class DeepLinkService {
  // ---------------------------------------------------------------------------
  // QUIC variable-length integer helpers
  // ---------------------------------------------------------------------------

  /// Reads a QUIC varint from [data] at [offset].
  /// Sets [bytesConsumed][0] to the number of bytes read.
  static int _readVarInt(Uint8List data, int offset, List<int> bytesConsumed) {
    final first = data[offset];
    final prefix = (first >> 6) & 0x03;
    switch (prefix) {
      case 0:
        bytesConsumed[0] = 1;
        return first & 0x3F;
      case 1:
        bytesConsumed[0] = 2;
        return ((first & 0x3F) << 8) | data[offset + 1];
      case 2:
        bytesConsumed[0] = 4;
        return ((first & 0x3F) << 24) |
            (data[offset + 1] << 16) |
            (data[offset + 2] << 8) |
            data[offset + 3];
      case 3:
        bytesConsumed[0] = 8;
        // Dart native ints are 64-bit; safe for 62-bit values.
        return ((first & 0x3F) << 56) |
            (data[offset + 1] << 48) |
            (data[offset + 2] << 40) |
            (data[offset + 3] << 32) |
            (data[offset + 4] << 24) |
            (data[offset + 5] << 16) |
            (data[offset + 6] << 8) |
            data[offset + 7];
      default:
        bytesConsumed[0] = 1;
        return first & 0x3F;
    }
  }

  /// Encodes [value] as a QUIC variable-length integer (big-endian).
  static Uint8List _writeVarInt(int value) {
    assert(value >= 0);
    if (value < 0x40) {
      return Uint8List.fromList([value]);
    } else if (value < 0x4000) {
      return Uint8List.fromList([0x40 | (value >> 8), value & 0xFF]);
    } else if (value < 0x40000000) {
      return Uint8List.fromList([
        0x80 | (value >> 24),
        (value >> 16) & 0xFF,
        (value >> 8) & 0xFF,
        value & 0xFF,
      ]);
    } else {
      return Uint8List.fromList([
        0xC0 | ((value >> 56) & 0x3F),
        (value >> 48) & 0xFF,
        (value >> 40) & 0xFF,
        (value >> 32) & 0xFF,
        (value >> 24) & 0xFF,
        (value >> 16) & 0xFF,
        (value >> 8) & 0xFF,
        value & 0xFF,
      ]);
    }
  }

  // ---------------------------------------------------------------------------
  // TLV write helpers
  // ---------------------------------------------------------------------------

  /// Writes a complete TLV triple: [tag varint][length varint][value bytes].
  static List<int> _writeTlv(int tag, Uint8List value) {
    return [..._writeVarInt(tag), ..._writeVarInt(value.length), ...value];
  }

  static List<int> _writeStringTlv(int tag, String value) =>
      _writeTlv(tag, Uint8List.fromList(utf8.encode(value)));

  static List<int> _writeBoolTlv(int tag, bool value) =>
      _writeTlv(tag, Uint8List.fromList([value ? 0x01 : 0x00]));

  static List<int> _writeVarIntTlv(int tag, int value) =>
      _writeTlv(tag, _writeVarInt(value));

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Parses a `tt://` deep link into a [TrustTunnelProfile].
  /// Returns `null` if the link is invalid or missing required fields.
  static TrustTunnelProfile? parseDeepLink(String uri, String newId) {
    try {
      if (!uri.startsWith('tt://')) return null;

      final parsed = Uri.parse(uri);
      var b64 = parsed.query;
      if (b64.isEmpty) return null;

      // Restore standard base64 padding (length must be a multiple of 4).
      final rem = b64.length % 4;
      if (rem != 0) b64 = b64.padRight(b64.length + (4 - rem), '=');

      final data = Uint8List.fromList(base64Url.decode(b64));

      // Parsed field accumulators
      String hostname = '';
      String name = '';
      String username = '';
      String password = '';
      final List<String> addresses = [];
      bool hasIpv6 = true;
      bool skipVerification = false;
      String certificate = '';
      String upstreamProtocol = 'http2';
      bool antiDpi = false;
      String clientRandom = '';
      final List<String> dnsUpstreams = [];

      int offset = 0;
      while (offset < data.length) {
        // Read tag
        final tagBuf = [0];
        final tag = _readVarInt(data, offset, tagBuf);
        offset += tagBuf[0];
        if (offset >= data.length) break;

        // Read length
        final lenBuf = [0];
        final length = _readVarInt(data, offset, lenBuf);
        offset += lenBuf[0];
        if (offset + length > data.length) break;

        final value = data.sublist(offset, offset + length);
        offset += length;

        switch (tag) {
          case 0x00: // version — ignored
            break;

          case 0x01: // hostname
            hostname = utf8.decode(value);

          case 0x02: // addresses (may repeat)
            addresses.add(utf8.decode(value));

          case 0x03: // custom_sni — not mapped to profile field
            break;

          case 0x04: // has_ipv6
            hasIpv6 = value.isNotEmpty && value[0] == 0x01;

          case 0x05: // username
            username = utf8.decode(value);

          case 0x06: // password
            password = utf8.decode(value);

          case 0x07: // skip_verification
            skipVerification = value.isNotEmpty && value[0] == 0x01;

          case 0x08: // certificate (concatenated DER bytes)
            // Store as DATA:<base64> so callers can detect the format.
            // Also force skip_verification so the custom cert is honoured.
            if (value.isNotEmpty) {
              certificate = 'DATA:${base64.encode(value)}';
              skipVerification = true;
            }

          case 0x09: // upstream_protocol (varint: 1=http2, 2=http3)
            if (value.isNotEmpty) {
              final protoRead = [0];
              final proto = _readVarInt(value, 0, protoRead);
              upstreamProtocol = proto == 0x02 ? 'http3' : 'http2';
            }

          case 0x0A: // anti_dpi
            antiDpi = value.isNotEmpty && value[0] == 0x01;

          case 0x0B: // client_random_prefix
            clientRandom = utf8.decode(value);

          case 0x0C: // name
            name = utf8.decode(value);

          case 0x0D: // dns_upstreams — sequence of varint-length-prefixed strings
            int i = 0;
            while (i < value.length) {
              final sLenBuf = [0];
              final sLen = _readVarInt(value, i, sLenBuf);
              i += sLenBuf[0];
              if (i + sLen > value.length) break;
              dnsUpstreams.add(utf8.decode(value.sublist(i, i + sLen)));
              i += sLen;
            }
        }
      }

      if (hostname.isEmpty) return null;

      return TrustTunnelProfile(
        id: newId,
        name: name.isEmpty ? hostname : name,
        hostname: hostname,
        addresses: addresses,
        username: username,
        password: password,
        hasIpv6: hasIpv6,
        skipVerification: skipVerification,
        certificate: certificate,
        upstreamProtocol: upstreamProtocol,
        antiDpi: antiDpi,
        clientRandom: clientRandom,
        dnsUpstreams: dnsUpstreams,
        // Client/listener settings not encoded in deep link; use safe defaults.
        vpnMode: 'general',
        killswitchEnabled: false,
        postQuantumEnabled: true,
        killswitchAllowPorts: const [],
        exclusions: const [],
        listenerType: ListenerType.tun,
        socks5Address: '127.0.0.1:1080',
        socks5Username: '',
        socks5Password: '',
      );
    } catch (_) {
      return null;
    }
  }

  /// Generates a `tt://` deep link from [profile].
  /// Only endpoint fields are encoded; client/listener settings are omitted.
  static String generateDeepLink(TrustTunnelProfile profile) {
    final payload = <int>[];

    // version = 0
    payload.addAll(_writeVarIntTlv(0x00, 0));

    // name
    if (profile.name.isNotEmpty) {
      payload.addAll(_writeStringTlv(0x0C, profile.name));
    }

    // hostname (required)
    payload.addAll(_writeStringTlv(0x01, profile.hostname));

    // addresses (one TLV per address)
    for (final addr in profile.addresses) {
      payload.addAll(_writeStringTlv(0x02, addr));
    }

    // has_ipv6 — only encode when non-default (default = true)
    if (!profile.hasIpv6) {
      payload.addAll(_writeBoolTlv(0x04, false));
    }

    // credentials
    if (profile.username.isNotEmpty) {
      payload.addAll(_writeStringTlv(0x05, profile.username));
    }
    if (profile.password.isNotEmpty) {
      payload.addAll(_writeStringTlv(0x06, profile.password));
    }

    // skip_verification
    if (profile.skipVerification) {
      payload.addAll(_writeBoolTlv(0x07, true));
    }

    // certificate
    // If stored as DATA:<base64-DER>, re-encode as raw DER bytes.
    // PEM certificates from trusted CAs are omitted (receiver uses system store).
    if (profile.certificate.startsWith('DATA:')) {
      final derBytes = base64.decode(profile.certificate.substring(5));
      payload.addAll(_writeTlv(0x08, Uint8List.fromList(derBytes)));
    }

    // upstream_protocol (always include for clarity)
    payload.addAll(
      _writeVarIntTlv(0x09, profile.upstreamProtocol == 'http3' ? 0x02 : 0x01),
    );

    // anti_dpi
    if (profile.antiDpi) {
      payload.addAll(_writeBoolTlv(0x0A, true));
    }

    // client_random_prefix
    if (profile.clientRandom.isNotEmpty) {
      payload.addAll(_writeStringTlv(0x0B, profile.clientRandom));
    }

    // dns_upstreams — value = sequence of [varint-len][utf8-bytes]
    if (profile.dnsUpstreams.isNotEmpty) {
      final dnsValue = <int>[];
      for (final dns in profile.dnsUpstreams) {
        final dnsBytes = utf8.encode(dns);
        dnsValue.addAll(_writeVarInt(dnsBytes.length));
        dnsValue.addAll(dnsBytes);
      }
      payload.addAll(_writeTlv(0x0D, Uint8List.fromList(dnsValue)));
    }

    // Encode without padding for cleaner URLs.
    final encoded = base64Url
        .encode(Uint8List.fromList(payload))
        .replaceAll('=', '');

    return 'tt://?$encoded';
  }
}
