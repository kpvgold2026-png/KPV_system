var _cashbankAllRows = [];
var _cashbankFilteredTypes = ['CASH_IN', 'CASH_OUT', 'BANK_IN', 'BANK_OUT', 'BANK_DEPOSIT', 'BANK_WITHDRAW', 'OTHER_INCOME', 'OTHER_EXPENSE', 'OPEN_SHIFT'];

async function loadCashBank() {
  try {
    showLoading();

    var balResult = await dbRpc('get_cashbank_balances', {});

    var balances = {
      cash: { LAK: 0, THB: 0, USD: 0 },
      bcel: { LAK: 0, THB: 0, USD: 0 },
      ldb: { LAK: 0, THB: 0, USD: 0 },
      other: { LAK: 0, THB: 0, USD: 0 }
    };

    if (balResult && balResult.cash) {
      balances.cash.LAK = parseFloat(balResult.cash.LAK) || 0;
      balances.cash.THB = parseFloat(balResult.cash.THB) || 0;
      balances.cash.USD = parseFloat(balResult.cash.USD) || 0;
    }
    if (balResult && balResult.banks) {
      var banksKey = { 'BCEL': 'bcel', 'LDB': 'ldb', 'OTHER': 'other' };
      Object.keys(balResult.banks).forEach(function(bankName) {
        var key = banksKey[bankName] || 'other';
        var b = balResult.banks[bankName] || {};
        balances[key].LAK = parseFloat(b.LAK) || 0;
        balances[key].THB = parseFloat(b.THB) || 0;
        balances[key].USD = parseFloat(b.USD) || 0;
      });
    }

    document.getElementById('cashLAK').textContent = formatNumber(balances.cash.LAK);
    document.getElementById('cashTHB').textContent = formatCurrency(balances.cash.THB, 'THB');
    document.getElementById('cashUSD').textContent = formatCurrency(balances.cash.USD, 'USD');
    document.getElementById('bcelLAK').textContent = formatNumber(balances.bcel.LAK);
    document.getElementById('bcelTHB').textContent = formatCurrency(balances.bcel.THB, 'THB');
    document.getElementById('bcelUSD').textContent = formatCurrency(balances.bcel.USD, 'USD');
    document.getElementById('ldbLAK').textContent = formatNumber(balances.ldb.LAK);
    document.getElementById('ldbTHB').textContent = formatCurrency(balances.ldb.THB, 'THB');
    document.getElementById('ldbUSD').textContent = formatCurrency(balances.ldb.USD, 'USD');
    document.getElementById('otherBankLAK').textContent = formatNumber(balances.other.LAK);
    document.getElementById('otherBankTHB').textContent = formatCurrency(balances.other.THB, 'THB');
    document.getElementById('otherBankUSD').textContent = formatCurrency(balances.other.USD, 'USD');

    var rows = await dbSelect('cashbank', {
      select: 'id,type,amount,currency,method,bank_id,note,date,ref_tx_id,bank:banks!bank_id(name)',
      filters: { type: 'in.(' + _cashbankFilteredTypes.join(',') + ')' },
      order: 'date.desc',
      limit: 500,
      useCache: false
    });

    _cashbankAllRows = (rows || []).map(function(r) {
      return [
        r.id,
        r.type,
        r.amount,
        r.currency,
        r.method,
        r.bank ? r.bank.name : '',
        r.note || '',
        r.date,
        r.ref_tx_id || ''
      ];
    });

    var cbStart = document.getElementById('cbStartDate');
    var cbEnd = document.getElementById('cbEndDate');
    if (!cbStart.value && !cbEnd.value) {
      var today = new Date();
      var todayStr = today.getFullYear() + '-' + String(today.getMonth() + 1).padStart(2, '0') + '-' + String(today.getDate()).padStart(2, '0');
      cbStart.value = todayStr;
      cbEnd.value = todayStr;
    }
    filterCashBankByDate();
    hideLoading();
  } catch (error) {
    console.error('Error loading cashbank:', error);
    hideLoading();
  }
}

function renderCashBankTable(rows) {
  var tbody = document.getElementById('cashbankTable');
  if (!rows || rows.length === 0) {
    tbody.innerHTML = '<tr><td colspan="8" style="text-align: center; padding: 40px;">No records</td></tr>';
    return;
  }
  tbody.innerHTML = rows.map(function(row) {
    return '<tr>' +
      '<td>' + row[0] + '</td>' +
      '<td>' + row[1] + '</td>' +
      '<td>' + formatCurrency(row[2], row[3]) + '</td>' +
      '<td>' + (row[3] || '-') + '</td>' +
      '<td>' + row[4] + '</td>' +
      '<td>' + (row[5] || '-') + '</td>' +
      '<td>' + (row[6] || '-') + '</td>' +
      '<td>' + formatDateTime(row[7]) + '</td>' +
      '</tr>';
  }).join('');
}

function filterCashBankByDate() {
  var startStr = document.getElementById('cbStartDate').value;
  var endStr = document.getElementById('cbEndDate').value;
  if (!startStr && !endStr) {
    renderCashBankTable(_cashbankAllRows);
    return;
  }
  var startDate = startStr ? new Date(startStr + 'T00:00:00') : null;
  var endDate = endStr ? new Date(endStr + 'T23:59:59') : null;
  var filtered = _cashbankAllRows.filter(function(row) {
    var d = new Date(row[7]);
    if (isNaN(d.getTime())) return false;
    if (startDate && d < startDate) return false;
    if (endDate && d > endDate) return false;
    return true;
  });
  renderCashBankTable(filtered);
}

function showTodayCashBank() {
  var today = new Date();
  var todayStr = today.getFullYear() + '-' + String(today.getMonth() + 1).padStart(2, '0') + '-' + String(today.getDate()).padStart(2, '0');
  document.getElementById('cbStartDate').value = todayStr;
  document.getElementById('cbEndDate').value = todayStr;
  filterCashBankByDate();
}

function toggleOtherIncomeBank() {
  var method = document.getElementById('otherIncomeMethod').value;
  document.getElementById('otherIncomeBankGroup').style.display = method === 'BANK' ? 'block' : 'none';
}

function toggleOtherExpenseBank() {
  var method = document.getElementById('otherExpenseMethod').value;
  document.getElementById('otherExpenseBankGroup').style.display = method === 'BANK' ? 'block' : 'none';
}

async function _submitCashBankEntry(type, amount, currency, method, bank, note) {
  if (!amount || amount <= 0) {
    alert('Please enter amount');
    return false;
  }
  showLoading();
  try {
    var result = await dbRpc('add_cashbank_entry', {
      p_type: type,
      p_amount: amount,
      p_currency: currency,
      p_method: method,
      p_bank_name: bank || null,
      p_note: note
    });
    hideLoading();
    if (result && result.success) {
      showToast('✅ Transaction added successfully!');
      return true;
    } else {
      alert('❌ Error: ' + (result && result.message ? result.message : 'Unknown'));
      return false;
    }
  } catch (error) {
    hideLoading();
    alert('❌ Error: ' + error.message);
    return false;
  }
}

async function submitCash() {
  var type = document.getElementById('cashType').value;
  var amountEl = document.getElementById('cashAmount');
  var amount = amountEl.numericValue || parseFloat(String(amountEl.value).replace(/,/g, '')) || 0;
  var currency = document.getElementById('cashCurrency').value;
  var note = document.getElementById('cashNote').value;
  var dbType = type === 'IN' ? 'CASH_IN' : 'CASH_OUT';
  var ok = await _submitCashBankEntry(dbType, amount, currency, 'CASH', '', note);
  if (ok) {
    closeModal('cashModal');
    document.getElementById('cashAmount').value = '';
    document.getElementById('cashNote').value = '';
    loadCashBank();
  }
}

async function submitBank() {
  var type = document.getElementById('bankType').value;
  var bank = document.getElementById('bankName').value;
  var amountEl = document.getElementById('bankAmount');
  var amount = amountEl.numericValue || parseFloat(String(amountEl.value).replace(/,/g, '')) || 0;
  var currency = document.getElementById('bankCurrency').value;
  var note = document.getElementById('bankNote').value;
  var dbType = type === 'DEPOSIT' ? 'BANK_DEPOSIT' : 'BANK_WITHDRAW';
  var ok = await _submitCashBankEntry(dbType, amount, currency, 'BANK', bank, note);
  if (ok) {
    closeModal('bankModal');
    document.getElementById('bankAmount').value = '';
    document.getElementById('bankNote').value = '';
    loadCashBank();
  }
}

async function submitOtherIncome() {
  var method = document.getElementById('otherIncomeMethod').value;
  var bank = method === 'BANK' ? document.getElementById('otherIncomeBank').value : '';
  var amountEl = document.getElementById('otherIncomeAmount');
  var amount = amountEl.numericValue || parseFloat(String(amountEl.value).replace(/,/g, '')) || 0;
  var currency = document.getElementById('otherIncomeCurrency').value;
  var note = document.getElementById('otherIncomeNote').value;
  var ok = await _submitCashBankEntry('OTHER_INCOME', amount, currency, method, bank, note);
  if (ok) {
    closeModal('otherIncomeModal');
    document.getElementById('otherIncomeAmount').value = '';
    document.getElementById('otherIncomeNote').value = '';
    loadCashBank();
  }
}

async function submitOtherExpense() {
  var method = document.getElementById('otherExpenseMethod').value;
  var bank = method === 'BANK' ? document.getElementById('otherExpenseBank').value : '';
  var amountEl = document.getElementById('otherExpenseAmount');
  var amount = amountEl.numericValue || parseFloat(String(amountEl.value).replace(/,/g, '')) || 0;
  var currency = document.getElementById('otherExpenseCurrency').value;
  var note = document.getElementById('otherExpenseNote').value;
  var ok = await _submitCashBankEntry('OTHER_EXPENSE', amount, currency, method, bank, note);
  if (ok) {
    closeModal('otherExpenseModal');
    document.getElementById('otherExpenseAmount').value = '';
    document.getElementById('otherExpenseNote').value = '';
    loadCashBank();
  }
}
