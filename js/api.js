var _apiCache = {};
var _apiCacheTTL = 60000;

function _apiHeaders() {
  var token = (currentUser && currentUser.token) || localStorage.getItem('jwt') || '';
  return {
    'apikey': CONFIG.SUPABASE_ANON_KEY,
    'Authorization': 'Bearer ' + (token || CONFIG.SUPABASE_ANON_KEY),
    'Content-Type': 'application/json',
    'Accept': 'application/json'
  };
}

function _apiUrl(path) {
  return CONFIG.SUPABASE_URL + '/rest/v1/' + path;
}

function _cacheKey(method, path, body) {
  return method + ' ' + path + ' ' + (body ? JSON.stringify(body) : '');
}

function invalidateCache(prefix) {
  if (!prefix) { _apiCache = {}; return; }
  Object.keys(_apiCache).forEach(function(k) {
    if (k.indexOf(prefix) >= 0) delete _apiCache[k];
  });
}

async function _apiRequest(method, path, options) {
  options = options || {};
  var url = _apiUrl(path);
  var headers = _apiHeaders();
  if (options.headers) Object.assign(headers, options.headers);

  var key = _cacheKey(method, path);
  if (method === 'GET' && options.useCache !== false) {
    var now = Date.now();
    if (_apiCache[key] && (now - _apiCache[key].time) < _apiCacheTTL) {
      return _apiCache[key].data;
    }
  }

  var fetchOpts = { method: method, headers: headers };
  if (options.body !== undefined) fetchOpts.body = JSON.stringify(options.body);

  var resp = await fetch(url, fetchOpts);
  if (!resp.ok) {
    var errText = await resp.text();
    if (resp.status === 401) {
      try { logout(); } catch(e) {}
    }
    throw new Error('API ' + resp.status + ': ' + errText);
  }

  var data = null;
  if (resp.status !== 204) {
    var ct = resp.headers.get('content-type') || '';
    if (ct.indexOf('application/json') >= 0) {
      var txt = await resp.text();
      data = txt ? JSON.parse(txt) : null;
    }
  }

  if (method === 'GET' && options.useCache !== false) {
    _apiCache[key] = { data: data, time: Date.now() };
  } else {
    invalidateCache(path.split('?')[0]);
  }
  return data;
}

async function dbSelect(table, opts) {
  opts = opts || {};
  var qs = [];
  if (opts.select) qs.push('select=' + encodeURIComponent(opts.select));
  if (opts.filters) {
    Object.keys(opts.filters).forEach(function(col) {
      qs.push(col + '=' + encodeURIComponent(opts.filters[col]));
    });
  }
  if (opts.order) qs.push('order=' + encodeURIComponent(opts.order));
  if (opts.limit) qs.push('limit=' + opts.limit);
  if (opts.offset) qs.push('offset=' + opts.offset);
  var path = table + (qs.length ? '?' + qs.join('&') : '');
  return await _apiRequest('GET', path, { useCache: opts.useCache !== false });
}

async function dbInsert(table, rows, opts) {
  opts = opts || {};
  var headers = { 'Prefer': opts.returning === false ? 'return=minimal' : 'return=representation' };
  if (opts.upsert) headers['Prefer'] = 'resolution=merge-duplicates,return=representation';
  return await _apiRequest('POST', table, { body: rows, headers: headers });
}

async function dbUpdate(table, filters, patch) {
  var qs = [];
  Object.keys(filters).forEach(function(col) {
    qs.push(col + '=' + encodeURIComponent(filters[col]));
  });
  var path = table + '?' + qs.join('&');
  var headers = { 'Prefer': 'return=representation' };
  return await _apiRequest('PATCH', path, { body: patch, headers: headers });
}

async function dbDelete(table, filters) {
  var qs = [];
  Object.keys(filters).forEach(function(col) {
    qs.push(col + '=' + encodeURIComponent(filters[col]));
  });
  var path = table + '?' + qs.join('&');
  return await _apiRequest('DELETE', path);
}

async function dbRpc(fnName, params) {
  return await _apiRequest('POST', 'rpc/' + fnName, { body: params || {}, headers: { 'Prefer': 'return=representation' } });
}

async function fetchExchangeRates() {
  try {
    var rows = await dbSelect('price_rates', { select: '*', order: 'date.desc', limit: 1 });
    if (rows && rows.length > 0) {
      var r = rows[0];
      var p = function(v) { return parseFloat(v) || 0; };
      currentExchangeRates = {
        LAK: 1,
        THB_Sell: p(r.thb_sell),
        USD_Sell: p(r.usd_sell),
        THB_Buy: p(r.thb_buy),
        USD_Buy: p(r.usd_buy),
        THB: p(r.thb_sell),
        USD: p(r.usd_sell)
      };
    }
  } catch(e) {
    console.error('Error fetching exchange rates:', e);
  }
  return currentExchangeRates;
}

async function fetchCurrentPricing() {
  try {
    var rows = await dbSelect('pricing', { select: '*', order: 'date.desc', limit: 1 });
    if (rows && rows.length > 0) {
      currentPricing.sell1Baht = parseFloat(rows[0].sell_1baht) || 0;
      currentPricing.buyback1Baht = parseFloat(rows[0].buyback_1baht) || 0;
    }
  } catch(e) {}
  return currentPricing;
}

async function fetchAppConfig() {
  try {
    var rows = await dbSelect('app_config', { select: '*' });
    var cfg = {};
    if (rows) rows.forEach(function(r) { cfg[r.key] = r.value; });
    if (cfg.premium_per_piece !== undefined) PREMIUM_PER_PIECE = parseFloat(cfg.premium_per_piece) || PREMIUM_PER_PIECE;
    return cfg;
  } catch(e) { return {}; }
}

async function batchFetchAll() {
  try {
    await Promise.all([
      fetchExchangeRates(),
      fetchCurrentPricing(),
      fetchAppConfig()
    ]);
  } catch(e) {}
}
