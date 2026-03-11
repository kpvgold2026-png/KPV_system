var _sheetCache = {};
var _cacheTTL = 30000;

var ALL_RANGES = [
  '_database!A1:M31',
  'Sells!A:M',
  'Tradeins!A:O',
  'Exchanges!A:T',
  'Buybacks!A:L',
  'Withdraws!A:L',
  'CashBank!A:I',
  'Diff!A:J',
  'Close!A:K',
  'PriceRate!A:E',
  '_notifications!A:I'
];

async function batchFetchAll() {
  try {
    var url = CONFIG.SCRIPT_URL + '?action=BATCH_READ&ranges=' + encodeURIComponent(JSON.stringify(ALL_RANGES));
    var response = await fetch(url, { method: 'GET', redirect: 'follow' });
    var result = await response.json();
    if (result.success && result.data) {
      var now = Date.now();
      for (var range in result.data) {
        _sheetCache[range] = { data: result.data[range] || [], time: now };
      }
    }
  } catch(e) {}
}

async function fetchSheetData(range) {
  var now = Date.now();
  if (_sheetCache[range] && (now - _sheetCache[range].time) < _cacheTTL) {
    return _sheetCache[range].data;
  }
  try {
    var url = CONFIG.SCRIPT_URL + '?action=READ_SHEET&range=' + encodeURIComponent(range);
    var response = await fetch(url, { method: 'GET', redirect: 'follow' });
    var result = await response.json();
    if (result.success) {
      var data = result.data || [];
      _sheetCache[range] = { data: data, time: now };
      return data;
    }
  } catch(e) {}
  return _sheetCache[range] ? _sheetCache[range].data : [];
}

function invalidateCache() {
  _sheetCache = {};
}

async function callAppsScript(action, params = {}) {
  invalidateCache();
  const queryParams = new URLSearchParams({
    action,
    ...params,
    user: currentUser?.nickname || currentUser?.role || 'Unknown'
  });
  
  const url = `${CONFIG.SCRIPT_URL}?${queryParams.toString()}`;
  
  const response = await fetch(url, {
    method: 'GET',
    redirect: 'follow'
  });
  
  const result = await response.json();
  return result;
}

const executeGoogleScript = callAppsScript;

async function fetchExchangeRates() {
  try {
    var prData = await fetchSheetData('PriceRate!A:E');
    if (prData.length > 1) {
      var last = prData[prData.length - 1];
      var p = function(v) { return parseFloat(String(v).replace(/,/g, '')) || 0; };
      currentExchangeRates = {
        LAK: 1,
        THB_Sell: p(last[1]),
        USD_Sell: p(last[2]),
        THB_Buy: p(last[3]),
        USD_Buy: p(last[4]),
        THB: p(last[1]),
        USD: p(last[2])
      };
    }
  } catch(e) {
    console.error('Error fetching exchange rates:', e);
  }
  return currentExchangeRates;
}