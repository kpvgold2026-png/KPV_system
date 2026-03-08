var _cashbankAllRows = [];
var _cashbankFilteredTypes = ['CASH_IN', 'CASH_OUT', 'BANK_DEPOSIT', 'BANK_WITHDRAW', 'OTHER_INCOME', 'OTHER_EXPENSE'];

async function loadCashBank() {
  try {
    showLoading();

    const [cashbankData, dbData] = await Promise.all([
      fetchSheetData('CashBank!A:I'),
      fetchSheetData('_database!A1:G31')
    ]);

    let balances = {
      cash: { LAK: 0, THB: 0, USD: 0 },
      bcel: { LAK: 0, THB: 0, USD: 0 },
      ldb: { LAK: 0, THB: 0, USD: 0 },
      other: { LAK: 0, THB: 0, USD: 0 }
    };

    if (dbData.length >= 17) {
      balances.cash.LAK = parseFloat(dbData[16][0]) || 0;
      balances.cash.THB = parseFloat(dbData[16][1]) || 0;
      balances.cash.USD = parseFloat(dbData[16][2]) || 0;
    }

    if (dbData.length >= 20) {
      balances.bcel.LAK = parseFloat(dbData[19][0]) || 0;
      balances.bcel.THB = parseFloat(dbData[19][1]) || 0;
      balances.bcel.USD = parseFloat(dbData[19][2]) || 0;
    }

    if (dbData.length >= 23) {
      balances.ldb.LAK = parseFloat(dbData[22][0]) || 0;
      balances.ldb.THB = parseFloat(dbData[22][1]) || 0;
      balances.ldb.USD = parseFloat(dbData[22][2]) || 0;
    }

    if (dbData.length >= 17) {
      balances.other.LAK = parseFloat(dbData[16][4]) || 0;
      balances.other.THB = parseFloat(dbData[16][5]) || 0;
      balances.other.USD = parseFloat(dbData[16][6]) || 0;
    }

    document.getElementById('cashLAK').textContent = formatNumber(balances.cash.LAK);
    document.getElementById('cashTHB').textContent = formatNumber(balances.cash.THB);
    document.getElementById('cashUSD').textContent = formatNumber(balances.cash.USD);

    document.getElementById('bcelLAK').textContent = formatNumber(balances.bcel.LAK);
    document.getElementById('bcelTHB').textContent = formatNumber(balances.bcel.THB);
    document.getElementById('bcelUSD').textContent = formatNumber(balances.bcel.USD);

    document.getElementById('ldbLAK').textContent = formatNumber(balances.ldb.LAK);
    document.getElementById('ldbTHB').textContent = formatNumber(balances.ldb.THB);
    document.getElementById('ldbUSD').textContent = formatNumber(balances.ldb.USD);

    document.getElementById('otherBankLAK').textContent = formatNumber(balances.other.LAK);
    document.getElementById('otherBankTHB').textContent = formatNumber(balances.other.THB);
    document.getElementById('otherBankUSD').textContent = formatNumber(balances.other.USD);

    _cashbankAllRows = [];
    if (cashbankData.length > 1) {
      _cashbankAllRows = cashbankData.slice(1).filter(function(row) {
        return _cashbankFilteredTypes.indexOf(row[1]) >= 0;
      });
    }

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
  tbody.innerHTML = rows.slice().reverse().map(function(row) {
    return '<tr>' +
      '<td>' + row[0] + '</td>' +
      '<td>' + row[1] + '</td>' +
      '<td>' + formatNumber(row[2]) + '</td>' +
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
    var d = parseSheetDate(row[7]);
    if (!d) return false;
    if (startDate && d < startDate) return false;
    if (endDate && d > endDate) return false;
    return true;
  });
  renderCashBankTable(filtered);
}

function showTodayCashBank() {
  var today = new Date();
  var yyyy = today.getFullYear();
  var mm = String(today.getMonth() + 1).padStart(2, '0');
  var dd = String(today.getDate()).padStart(2, '0');
  var todayStr = yyyy + '-' + mm + '-' + dd;
  document.getElementById('cbStartDate').value = todayStr;
  document.getElementById('cbEndDate').value = todayStr;
  filterCashBankByDate();
}

function toggleOtherIncomeBank() {
  const method = document.getElementById('otherIncomeMethod').value;
  const bankGroup = document.getElementById('otherIncomeBankGroup');
  bankGroup.style.display = method === 'BANK' ? 'block' : 'none';
}

function toggleOtherExpenseBank() {
  const method = document.getElementById('otherExpenseMethod').value;
  const bankGroup = document.getElementById('otherExpenseBankGroup');
  bankGroup.style.display = method === 'BANK' ? 'block' : 'none';
}

async function submitCash() {
  const type = document.getElementById('cashType').value;
  const amountEl = document.getElementById('cashAmount');
  const amount = amountEl.numericValue || parseFloat(String(amountEl.value).replace(/,/g, '')) || 0;
  const currency = document.getElementById('cashCurrency').value;
  const note = document.getElementById('cashNote').value;

  if (!amount || amount <= 0) {
    alert('Please enter amount');
    return;
  }

  try {
    showLoading();
    const result = await callAppsScript('ADD_CASHBANK', {
      type: type === 'IN' ? 'CASH_IN' : 'CASH_OUT',
      amount,
      currency,
      method: 'CASH',
      bank: '',
      note
    });

    if (result.success) {
      showToast('✅ Transaction added successfully!');
      closeModal('cashModal');
      document.getElementById('cashAmount').value = '';
      document.getElementById('cashNote').value = '';
      loadCashBank();
    } else {
      alert('❌ Error: ' + result.message);
    }
    hideLoading();
  } catch (error) {
    alert('❌ Error: ' + error.message);
    hideLoading();
  }
}

async function submitBank() {
  const type = document.getElementById('bankType').value;
  const bank = document.getElementById('bankName').value;
  const amountEl = document.getElementById('bankAmount');
  const amount = amountEl.numericValue || parseFloat(String(amountEl.value).replace(/,/g, '')) || 0;
  const currency = document.getElementById('bankCurrency').value;
  const note = document.getElementById('bankNote').value;

  if (!amount || amount <= 0) {
    alert('Please enter amount');
    return;
  }

  try {
    showLoading();
    const result = await callAppsScript('ADD_CASHBANK', {
      type: type === 'DEPOSIT' ? 'BANK_DEPOSIT' : 'BANK_WITHDRAW',
      amount,
      currency,
      method: 'BANK',
      bank,
      note
    });

    if (result.success) {
      showToast('✅ Transaction added successfully!');
      closeModal('bankModal');
      document.getElementById('bankAmount').value = '';
      document.getElementById('bankNote').value = '';
      loadCashBank();
    } else {
      alert('❌ Error: ' + result.message);
    }
    hideLoading();
  } catch (error) {
    alert('❌ Error: ' + error.message);
    hideLoading();
  }
}

async function submitOtherIncome() {
  const method = document.getElementById('otherIncomeMethod').value;
  const bank = method === 'BANK' ? document.getElementById('otherIncomeBank').value : '';
  const amountEl = document.getElementById('otherIncomeAmount');
  const amount = amountEl.numericValue || parseFloat(String(amountEl.value).replace(/,/g, '')) || 0;
  const currency = document.getElementById('otherIncomeCurrency').value;
  const note = document.getElementById('otherIncomeNote').value;

  if (!amount || amount <= 0) {
    alert('Please enter amount');
    return;
  }

  try {
    showLoading();
    const result = await callAppsScript('ADD_CASHBANK', {
      type: 'OTHER_INCOME',
      amount,
      currency,
      method,
      bank,
      note
    });

    if (result.success) {
      showToast('✅ Transaction added successfully!');
      closeModal('otherIncomeModal');
      document.getElementById('otherIncomeAmount').value = '';
      document.getElementById('otherIncomeNote').value = '';
      loadCashBank();
    } else {
      alert('❌ Error: ' + result.message);
    }
    hideLoading();
  } catch (error) {
    alert('❌ Error: ' + error.message);
    hideLoading();
  }
}

async function submitOtherExpense() {
  const method = document.getElementById('otherExpenseMethod').value;
  const bank = method === 'BANK' ? document.getElementById('otherExpenseBank').value : '';
  const amountEl = document.getElementById('otherExpenseAmount');
  const amount = amountEl.numericValue || parseFloat(String(amountEl.value).replace(/,/g, '')) || 0;
  const currency = document.getElementById('otherExpenseCurrency').value;
  const note = document.getElementById('otherExpenseNote').value;

  if (!amount || amount <= 0) {
    alert('Please enter amount');
    return;
  }

  try {
    showLoading();
    const result = await callAppsScript('ADD_CASHBANK', {
      type: 'OTHER_EXPENSE',
      amount,
      currency,
      method,
      bank,
      note
    });

    if (result.success) {
      showToast('✅ Transaction added successfully!');
      closeModal('otherExpenseModal');
      document.getElementById('otherExpenseAmount').value = '';
      document.getElementById('otherExpenseNote').value = '';
      loadCashBank();
    } else {
      alert('❌ Error: ' + result.message);
    }
    hideLoading();
  } catch (error) {
    alert('❌ Error: ' + error.message);
    hideLoading();
  }
}
