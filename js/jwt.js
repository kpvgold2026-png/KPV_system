var _jwtCachedKey = null;

async function _jwtGetKey() {
  if (_jwtCachedKey) return _jwtCachedKey;
  var enc = new TextEncoder();
  _jwtCachedKey = await crypto.subtle.importKey(
    'raw',
    enc.encode(CONFIG.JWT_SECRET),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign', 'verify']
  );
  return _jwtCachedKey;
}

function _b64urlEncode(bytes) {
  var bin = '';
  if (bytes instanceof ArrayBuffer) bytes = new Uint8Array(bytes);
  for (var i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function _b64urlEncodeStr(str) {
  return _b64urlEncode(new TextEncoder().encode(str));
}

function _b64urlDecodeStr(str) {
  str = str.replace(/-/g, '+').replace(/_/g, '/');
  while (str.length % 4) str += '=';
  return atob(str);
}

async function jwtSign(payload) {
  var header = { alg: 'HS256', typ: 'JWT' };
  var now = Math.floor(Date.now() / 1000);
  var fullPayload = Object.assign({}, payload, { iat: now });

  var headerB64 = _b64urlEncodeStr(JSON.stringify(header));
  var payloadB64 = _b64urlEncodeStr(JSON.stringify(fullPayload));
  var data = headerB64 + '.' + payloadB64;

  var key = await _jwtGetKey();
  var sigBuf = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(data));
  var sigB64 = _b64urlEncode(sigBuf);
  return data + '.' + sigB64;
}

async function jwtVerify(token) {
  if (!token) return null;
  var parts = token.split('.');
  if (parts.length !== 3) return null;
  try {
    var data = parts[0] + '.' + parts[1];
    var sigBin = _b64urlDecodeStr(parts[2]);
    var sigBytes = new Uint8Array(sigBin.length);
    for (var i = 0; i < sigBin.length; i++) sigBytes[i] = sigBin.charCodeAt(i);

    var key = await _jwtGetKey();
    var ok = await crypto.subtle.verify('HMAC', key, sigBytes, new TextEncoder().encode(data));
    if (!ok) return null;

    var payload = JSON.parse(_b64urlDecodeStr(parts[1]));
    if (payload.exp && payload.exp < Math.floor(Date.now() / 1000)) return null;
    return payload;
  } catch(e) {
    return null;
  }
}

function jwtDecode(token) {
  if (!token) return null;
  var parts = token.split('.');
  if (parts.length !== 3) return null;
  try {
    return JSON.parse(_b64urlDecodeStr(parts[1]));
  } catch(e) {
    return null;
  }
}

async function passwordHash(password, salt) {
  var enc = new TextEncoder();
  var data = enc.encode(salt + ':' + password);
  var hashBuf = await crypto.subtle.digest('SHA-256', data);
  return _b64urlEncode(hashBuf);
}
