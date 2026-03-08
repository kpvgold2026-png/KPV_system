var _sheetCache = {};
var _cacheTTL = 30000;
var _batchPending = null;
var _batchRanges = [];
var _batchTimer = null;

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
  var ranges = ALL_RANGES.map(function(r) { return 'ranges=' + encodeURIComponent(r); }).join('&');
  var url = 'https://sheets.googleapis.com/v4/spreadsheets/' + CONFIG.SHEET_ID + '/values:batchGet?' + ranges + '&key=' + CONFIG.API_KEY;
  try {
    var response = await fetch(url);
    if (response.status === 429) return;
    var data = await response.json();
    if (!data.valueRanges) return;
    var now = Date.now();
    data.valueRanges.forEach(function(vr) {
      var range = vr.range || '';
      var matchedRange = ALL_RANGES.find(function(r) {
        var sheetName = r.split('!')[0];
        return range.indexOf(sheetName) >= 0;
      });
      if (matchedRange) {
        _sheetCache[matchedRange] = { data: vr.values || [], time: now };
      }
    });
  } catch(e) {}
}

async function fetchSheetData(range) {
  var now = Date.now();
  if (_sheetCache[range] && (now - _sheetCache[range].time) < _cacheTTL) {
    return _sheetCache[range].data;
  }
  var url = 'https://sheets.googleapis.com/v4/spreadsheets/' + CONFIG.SHEET_ID + '/values/' + encodeURIComponent(range) + '?key=' + CONFIG.API_KEY;
  var response = await fetch(url);
  if (response.status === 429) {
    return _sheetCache[range] ? _sheetCache[range].data : [];
  }
  var data = await response.json();
  var result = data.values || [];
  _sheetCache[range] = { data: result, time: now };
  return result;
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